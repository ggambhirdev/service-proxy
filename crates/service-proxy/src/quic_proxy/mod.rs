//! Raw QUIC framing, TLS, HTTP/3 server (phases 3a/3b).

mod framing;
mod tls;

pub use framing::{read_frame, write_frame};
pub use tls::generate_self_signed_server_config;

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;

use bytes::{Buf, Bytes};
use h3::quic::BidiStream;
use h3::server::RequestStream;
use http::{Request, Response};
use quinn::{Endpoint, ServerConfig};
use tracing::{info, warn};

use crate::proxy_http::ProxyService;
use crate::upstream::{ForwarderKind, Request as UpstreamRequest, Selector, SelectorKind};

pub async fn serve_quic(
    addr: SocketAddr,
    server_config: ServerConfig,
    selector: Arc<SelectorKind>,
    forwarder: ForwarderKind,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let endpoint = Endpoint::server(server_config, addr)?;
    info!("quic listening on {addr}");

    while let Some(incoming) = endpoint.accept().await {
        let selector = selector.clone();
        let forwarder = forwarder.clone();
        tokio::spawn(async move {
            match incoming.await {
                Ok(conn) => handle_quic_conn(conn, selector, forwarder).await,
                Err(e) => warn!("quic accept: {e}"),
            }
        });
    }
    Ok(())
}

async fn handle_quic_conn(
    conn: quinn::Connection,
    selector: Arc<SelectorKind>,
    forwarder: ForwarderKind,
) {
    loop {
        match conn.accept_bi().await {
            Ok((send, recv)) => {
                let selector = selector.clone();
                let forwarder = forwarder.clone();
                tokio::spawn(async move {
                    if let Err(e) = handle_quic_stream(send, recv, selector, forwarder).await {
                        warn!("quic stream: {e}");
                    }
                });
            }
            Err(_) => break,
        }
    }
}

async fn handle_quic_stream(
    mut send: quinn::SendStream,
    mut recv: quinn::RecvStream,
    selector: Arc<SelectorKind>,
    forwarder: ForwarderKind,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let payload = read_frame(&mut recv).await?;
    let (addr, tok) = selector.next();
    let mut headers = HashMap::new();
    headers.insert(
        "Content-Type".into(),
        vec!["application/octet-stream".into()],
    );
    let result = forwarder
        .forward(
            &addr,
            &UpstreamRequest {
                method: "POST".into(),
                path: "/echo".into(),
                host: addr.clone(),
                headers,
                body: Bytes::from(payload),
            },
        )
        .await;
    selector.release(tok);

    match result {
        Ok(resp) => {
            write_frame(&mut send, &resp.body).await?;
            send.finish()?;
        }
        Err(e) => {
            warn!("forward to {addr}: {e}");
        }
    }
    Ok(())
}

pub async fn serve_http3(
    addr: SocketAddr,
    server_config: ServerConfig,
    service: ProxyService,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let endpoint = Endpoint::server(server_config, addr)?;
    info!("http3 listening on {addr}");

    while let Some(incoming) = endpoint.accept().await {
        let service = service.clone();
        tokio::spawn(async move {
            match incoming.await {
                Ok(conn) => {
                    if let Err(e) = handle_http3_conn(conn, service).await {
                        warn!("http3 conn: {e}");
                    }
                }
                Err(e) => warn!("http3 accept: {e}"),
            }
        });
    }
    Ok(())
}

async fn handle_http3_conn(
    conn: quinn::Connection,
    service: ProxyService,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut h3_conn = h3::server::Connection::new(h3_quinn::Connection::new(conn)).await?;

    loop {
        match h3_conn.accept().await {
            Ok(Some(resolver)) => {
                let service = service.clone();
                tokio::spawn(async move {
                    match resolver.resolve_request().await {
                        Ok((req, stream)) => {
                            if let Err(e) = handle_http3_request(req, stream, service).await {
                                warn!("http3 request: {e}");
                            }
                        }
                        Err(e) => warn!("http3 resolve: {e}"),
                    }
                });
            }
            Ok(None) => break,
            Err(e) => {
                warn!("http3 accept stream: {e}");
                break;
            }
        }
    }
    Ok(())
}

async fn handle_http3_request<T>(
    req: Request<()>,
    mut stream: RequestStream<T, Bytes>,
    service: ProxyService,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>>
where
    T: BidiStream<Bytes>,
{
    let mut body = Vec::new();
    while let Some(mut chunk) = stream.recv_data().await? {
        let n = chunk.remaining();
        body.extend_from_slice(&chunk.copy_to_bytes(n));
    }

    let method = req.method().as_str().to_string();
    let path = req
        .uri()
        .path_and_query()
        .map(|pq| pq.as_str().to_string())
        .unwrap_or_else(|| req.uri().path().to_string());

    let mut headers: HashMap<String, Vec<String>> = HashMap::new();
    for (k, v) in req.headers() {
        headers
            .entry(k.as_str().to_string())
            .or_default()
            .push(String::from_utf8_lossy(v.as_bytes()).into_owned());
    }

    let (addr, tok) = service.selector.next();
    let result = service
        .forwarder
        .forward(
            &addr,
            &UpstreamRequest {
                method,
                path,
                host: addr.clone(),
                headers,
                body: Bytes::from(body),
            },
        )
        .await;
    service.selector.release(tok);

    match result {
        Ok(resp) => {
            let mut builder = Response::builder().status(resp.status_code);
            for (k, values) in &resp.headers {
                let lower = k.to_ascii_lowercase();
                if lower == "connection" || lower == "content-length" {
                    continue;
                }
                for v in values {
                    builder = builder.header(k.as_str(), v.as_str());
                }
            }
            let response = builder.body(())?;
            stream.send_response(response).await?;
            stream.send_data(resp.body).await?;
            stream.finish().await?;
        }
        Err(_) => {
            let response = Response::builder().status(502).body(())?;
            stream.send_response(response).await?;
            stream
                .send_data(Bytes::from_static(b"bad gateway"))
                .await?;
            stream.finish().await?;
        }
    }
    Ok(())
}
