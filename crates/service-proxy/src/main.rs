//! Service proxy binary: one binary, all phases via PROXY_MODE.

mod config;
mod grpc_proxy;
mod proxy_http;
mod quic_proxy;
mod upstream;

use std::net::{SocketAddr, ToSocketAddrs};
use std::sync::Arc;

use hyper::server::conn::http2;
use hyper_util::rt::{TokioExecutor, TokioIo};
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tracing::{info, warn};

use config::{Config, Mode};
use grpc_proxy::GrpcProxy;
use proxy_http::{handle_conn, ProxyService};
use upstream::{new_selector, ForwarderKind, Manager, SelectorKind};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    rustls::crypto::ring::default_provider()
        .install_default()
        .ok();
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let cfg = Config::load();
    let selector = new_selector(cfg.upstream_addrs.clone(), &cfg.lb_strategy);

    if !cfg.pprof_addr.is_empty() {
        // pprof for Rust is via flamegraph scripts / cargo-flamegraph, not an
        // in-process HTTP endpoint. Log so mis-set env is visible.
        warn!(
            "PPROF_ADDR={} set but Rust proxy has no pprof HTTP server; use make flamegraph-rust",
            cfg.pprof_addr
        );
    }

    if selector.has_stats() && !cfg.stats_addr.is_empty() {
        let sel = selector.clone();
        let addr = parse_listen_addr(&cfg.stats_addr)?;
        tokio::spawn(async move {
            if let Err(e) = serve_stats(addr, sel).await {
                warn!("stats server: {e}");
            }
        });
    }

    match cfg.mode {
        Mode::Quic => serve_quic_mode(&cfg, selector).await?,
        Mode::Http3 => serve_http3_mode(&cfg, selector).await?,
        Mode::Http2 => {
            let ln = bind_tcp(&cfg.listen_addr).await?;
            info!(
                "proxy listening on {} mode={} upstreams={:?}",
                cfg.listen_addr,
                cfg.mode.as_str(),
                cfg.upstream_addrs
            );
            serve_http2(ln, selector).await?;
        }
        Mode::Grpc => {
            let ln = bind_tcp(&cfg.listen_addr).await?;
            info!(
                "proxy listening on {} mode={} upstreams={:?}",
                cfg.listen_addr,
                cfg.mode.as_str(),
                cfg.upstream_addrs
            );
            serve_grpc(ln, &cfg, selector).await?;
        }
        Mode::Pooled => {
            let ln = bind_tcp(&cfg.listen_addr).await?;
            info!(
                "proxy listening on {} mode={} upstreams={:?}",
                cfg.listen_addr,
                cfg.mode.as_str(),
                cfg.upstream_addrs
            );
            serve_pooled(ln, &cfg, selector).await?;
        }
        Mode::TcpSync | Mode::TcpGoroutine => {
            let ln = bind_tcp(&cfg.listen_addr).await?;
            info!(
                "proxy listening on {} mode={} upstreams={:?}",
                cfg.listen_addr,
                cfg.mode.as_str(),
                cfg.upstream_addrs
            );
            serve_http(ln, &cfg, selector).await?;
        }
    }
    Ok(())
}

fn parse_listen_addr(addr: &str) -> Result<SocketAddr, Box<dyn std::error::Error + Send + Sync>> {
    let normalized = if let Some(port) = addr.strip_prefix(':') {
        format!("0.0.0.0:{port}")
    } else {
        addr.to_string()
    };
    Ok(normalized
        .to_socket_addrs()?
        .next()
        .ok_or("invalid listen addr")?)
}

async fn bind_tcp(addr: &str) -> Result<TcpListener, Box<dyn std::error::Error + Send + Sync>> {
    let sa = parse_listen_addr(addr)?;
    Ok(TcpListener::bind(sa).await?)
}

async fn serve_http(
    ln: TcpListener,
    cfg: &Config,
    selector: Arc<SelectorKind>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let forwarder = ForwarderKind::Dial;
    loop {
        let (conn, _) = ln.accept().await?;
        match cfg.mode {
            Mode::TcpGoroutine => {
                let sel = selector.clone();
                let fwd = forwarder.clone();
                tokio::spawn(async move {
                    handle_conn(conn, sel, fwd).await;
                });
            }
            _ => {
                // tcp-sync: handle inline before next Accept
                handle_conn(conn, selector.clone(), forwarder.clone()).await;
            }
        }
    }
}

async fn serve_pooled(
    ln: TcpListener,
    cfg: &Config,
    selector: Arc<SelectorKind>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let manager = Arc::new(Manager::new(&cfg.upstream_addrs, cfg.pool_size_per_upstream));
    let forwarder = ForwarderKind::Pool(manager);
    let (tx, rx) = mpsc::channel::<tokio::net::TcpStream>(cfg.worker_queue_depth);
    let rx = Arc::new(tokio::sync::Mutex::new(rx));

    for _ in 0..cfg.worker_pool_size {
        let rx = rx.clone();
        let sel = selector.clone();
        let fwd = forwarder.clone();
        tokio::spawn(async move {
            loop {
                let conn = {
                    let mut guard = rx.lock().await;
                    guard.recv().await
                };
                match conn {
                    Some(conn) => handle_conn(conn, sel.clone(), fwd.clone()).await,
                    None => break,
                }
            }
        });
    }

    loop {
        let (conn, _) = ln.accept().await?;
        // Blocks when queue is full — backpressure to the client.
        if tx.send(conn).await.is_err() {
            break;
        }
    }
    Ok(())
}

async fn serve_http2(
    ln: TcpListener,
    selector: Arc<SelectorKind>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let service = ProxyService {
        selector,
        forwarder: ForwarderKind::Dial,
    };
    loop {
        let (stream, _) = ln.accept().await?;
        let io = TokioIo::new(stream);
        let svc = service.clone();
        tokio::spawn(async move {
            // Prior-knowledge h2c (oha --http2).
            if let Err(e) = http2::Builder::new(TokioExecutor::new())
                .serve_connection(io, svc)
                .await
            {
                warn!("http2 conn: {e}");
            }
        });
    }
}

async fn serve_grpc(
    ln: TcpListener,
    cfg: &Config,
    selector: Arc<SelectorKind>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let manager = Arc::new(Manager::new(&cfg.upstream_addrs, cfg.pool_size_per_upstream));
    let forwarder = ForwarderKind::Pool(manager);
    let proxy = GrpcProxy::new(selector, forwarder);

    // tonic wants its own incoming stream from the listener.
    let incoming = tokio_stream::wrappers::TcpListenerStream::new(ln);
    // h2's default pending-accept-reset cap is 20; under packet loss that
    // closes the client HTTP/2 connection and produces the phase-4 gRPC
    // failure cliff vs grpc-go. Raise it so stream cancellations don't
    // tear down the connection.
    tonic::transport::Server::builder()
        .http2_max_pending_accept_reset_streams(Some(1024))
        .add_service(proxy.into_server())
        .serve_with_incoming(incoming)
        .await?;
    Ok(())
}

async fn serve_quic_mode(
    cfg: &Config,
    selector: Arc<SelectorKind>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let addr = parse_listen_addr(&cfg.listen_addr)?;
    let server_config = quic_proxy::generate_self_signed_server_config(&["service-proxy-quic"])?;
    let manager = Arc::new(Manager::new(&cfg.upstream_addrs, cfg.pool_size_per_upstream));
    let forwarder = ForwarderKind::Pool(manager);
    info!(
        "proxy listening on {} mode={} upstreams={:?} (quic/udp)",
        cfg.listen_addr,
        cfg.mode.as_str(),
        cfg.upstream_addrs
    );
    quic_proxy::serve_quic(addr, server_config, selector, forwarder).await
}

async fn serve_http3_mode(
    cfg: &Config,
    selector: Arc<SelectorKind>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let addr = parse_listen_addr(&cfg.listen_addr)?;
    let server_config = quic_proxy::generate_self_signed_server_config(&["h3"])?;
    let manager = Arc::new(Manager::new(&cfg.upstream_addrs, cfg.pool_size_per_upstream));
    let forwarder = ForwarderKind::Pool(manager);
    let service = ProxyService {
        selector,
        forwarder,
    };
    info!(
        "proxy listening on {} mode={} upstreams={:?} (http3/udp)",
        cfg.listen_addr,
        cfg.mode.as_str(),
        cfg.upstream_addrs
    );
    quic_proxy::serve_http3(addr, server_config, service).await
}

async fn serve_stats(
    addr: SocketAddr,
    selector: Arc<SelectorKind>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    use http_body_util::Full;
    use hyper::body::Incoming;
    use hyper::service::service_fn;
    use hyper::{Method, Request, Response, StatusCode};
    use hyper_util::rt::TokioIo;

    let ln = TcpListener::bind(addr).await?;
    info!("stats endpoint listening on {addr}");

    loop {
        let (stream, _) = ln.accept().await?;
        let sel = selector.clone();
        tokio::spawn(async move {
            let io = TokioIo::new(stream);
            let svc = service_fn(move |req: Request<Incoming>| {
                let sel = sel.clone();
                async move {
                    if req.method() == Method::GET && req.uri().path() == "/stats" {
                        let reset = req
                            .uri()
                            .query()
                            .map(|q| q.split('&').any(|p| p == "reset=1"))
                            .unwrap_or(false);
                        let stats = sel.stats(reset).unwrap_or_default();
                        let body = serde_json::to_vec(&stats).unwrap_or_default();
                        Ok::<_, std::convert::Infallible>(
                            Response::builder()
                                .header("content-type", "application/json")
                                .body(Full::new(bytes::Bytes::from(body)))
                                .unwrap(),
                        )
                    } else {
                        Ok(Response::builder()
                            .status(StatusCode::NOT_FOUND)
                            .body(Full::new(bytes::Bytes::new()))
                            .unwrap())
                    }
                }
            });
            let _ = hyper::server::conn::http1::Builder::new()
                .serve_connection(io, svc)
                .await;
        });
    }
}
