//! HTTP/1.1 raw-conn handler and hyper service for h2c / HTTP/3.

use std::collections::HashMap;
use std::convert::Infallible;
use std::sync::Arc;

use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use hyper::body::Incoming;
use hyper::{Request as HyperRequest, Response as HyperResponse};
use tokio::io::AsyncReadExt;
use tokio::net::TcpStream;
use tracing::warn;

use crate::upstream::{write_error, write_response, ForwarderKind, Request, Response, Selector, SelectorKind};

/// Read one HTTP/1.1 request, forward, write response, close conn.
pub async fn handle_conn(mut conn: TcpStream, selector: Arc<SelectorKind>, forwarder: ForwarderKind) {
    let req = match read_http11_request(&mut conn).await {
        Ok(r) => r,
        Err(e) => {
            if !is_benign_eof(&e) {
                warn!("read request: {e}");
            }
            return;
        }
    };

    let (addr, tok) = selector.next();
    let result = forwarder.forward(&addr, &req).await;
    selector.release(tok);

    match result {
        Ok(resp) => {
            if let Err(e) = write_response(&mut conn, &resp).await {
                warn!("write response: {e}");
            }
        }
        Err(e) => {
            warn!("forward to {addr}: {e}");
            let _ = write_error(&mut conn, 502).await;
        }
    }
}

fn is_benign_eof(e: &std::io::Error) -> bool {
    e.kind() == std::io::ErrorKind::UnexpectedEof || e.kind() == std::io::ErrorKind::ConnectionReset
}

async fn read_http11_request(conn: &mut TcpStream) -> Result<Request, std::io::Error> {
    let mut buf = Vec::with_capacity(4096);
    let mut tmp = [0u8; 1024];
    loop {
        let n = conn.read(&mut tmp).await?;
        if n == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "eof before headers",
            ));
        }
        buf.extend_from_slice(&tmp[..n]);
        if let Some(hdr_end) = find_header_end(&buf) {
            return parse_request(&buf, hdr_end, conn).await;
        }
        if buf.len() > 1024 * 1024 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "headers too large",
            ));
        }
    }
}

fn find_header_end(buf: &[u8]) -> Option<usize> {
    buf.windows(4).position(|w| w == b"\r\n\r\n").map(|i| i + 4)
}

async fn parse_request(
    buf: &[u8],
    hdr_end: usize,
    conn: &mut TcpStream,
) -> Result<Request, std::io::Error> {
    let header_bytes = &buf[..hdr_end];
    let mut headers = [httparse::EMPTY_HEADER; 64];
    let mut req = httparse::Request::new(&mut headers);
    match req.parse(header_bytes) {
        Ok(httparse::Status::Complete(_)) => {}
        Ok(httparse::Status::Partial) => {
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "partial headers",
            ));
        }
        Err(e) => {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                e.to_string(),
            ));
        }
    }

    let method = req.method.unwrap_or("GET").to_string();
    let path = req.path.unwrap_or("/").to_string();
    let mut header_map: HashMap<String, Vec<String>> = HashMap::new();
    let mut host = String::new();
    let mut content_length = 0usize;
    for h in req.headers.iter() {
        let name = h.name.to_string();
        let value = String::from_utf8_lossy(h.value).into_owned();
        if name.eq_ignore_ascii_case("host") {
            host = value.clone();
        }
        if name.eq_ignore_ascii_case("content-length") {
            content_length = value.parse().unwrap_or(0);
        }
        header_map.entry(name).or_default().push(value);
    }

    let mut body = buf[hdr_end..].to_vec();
    while body.len() < content_length {
        let mut tmp = vec![0u8; content_length - body.len()];
        let n = conn.read(&mut tmp).await?;
        if n == 0 {
            break;
        }
        body.extend_from_slice(&tmp[..n]);
    }
    body.truncate(content_length);

    Ok(Request {
        method,
        path,
        host,
        headers: header_map,
        body: Bytes::from(body),
    })
}

/// Hyper service used by HTTP/2 (h2c) and HTTP/3.
#[derive(Clone)]
pub struct ProxyService {
    pub selector: Arc<SelectorKind>,
    pub forwarder: ForwarderKind,
}

impl hyper::service::Service<HyperRequest<Incoming>> for ProxyService {
    type Response = HyperResponse<Full<Bytes>>;
    type Error = Infallible;
    type Future = std::pin::Pin<
        Box<dyn std::future::Future<Output = Result<Self::Response, Self::Error>> + Send>,
    >;

    fn call(&self, req: HyperRequest<Incoming>) -> Self::Future {
        let selector = self.selector.clone();
        let forwarder = self.forwarder.clone();
        Box::pin(async move {
            Ok(handle_hyper_request(req, selector, forwarder).await)
        })
    }
}

pub async fn handle_hyper_request(
    req: HyperRequest<Incoming>,
    selector: Arc<SelectorKind>,
    forwarder: ForwarderKind,
) -> HyperResponse<Full<Bytes>> {
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

    let body = match req.collect().await {
        Ok(c) => c.to_bytes(),
        Err(_) => {
            return HyperResponse::builder()
                .status(400)
                .body(Full::new(Bytes::from_static(b"failed to read body")))
                .unwrap();
        }
    };

    let (addr, tok) = selector.next();
    let upstream_req = Request {
        method,
        path,
        host: addr.clone(),
        headers,
        body,
    };
    let result = forwarder.forward(&addr, &upstream_req).await;
    selector.release(tok);

    match result {
        Ok(resp) => hyper_from_upstream(resp),
        Err(_) => HyperResponse::builder()
            .status(502)
            .body(Full::new(Bytes::from_static(b"bad gateway")))
            .unwrap(),
    }
}

fn hyper_from_upstream(resp: Response) -> HyperResponse<Full<Bytes>> {
    let mut builder = HyperResponse::builder().status(resp.status_code);
    for (k, values) in &resp.headers {
        let lower = k.to_ascii_lowercase();
        if lower == "connection" || lower == "content-length" {
            continue;
        }
        for v in values {
            builder = builder.header(k.as_str(), v.as_str());
        }
    }
    builder.body(Full::new(resp.body)).unwrap()
}
