//! Opt-in CPU profiling via tikv/pprof-rs, exposed over HTTP like Go's
//! `net/http/pprof`. Enabled only when `PPROF_ADDR` is set so default benches
//! stay uninstrumented.
//!
//! Endpoints (mirror Go where possible):
//! - `GET /debug/pprof/profile?seconds=N` → pprof protobuf (userspace samples)
//! - `GET /debug/pprof/flamegraph?seconds=N` → SVG flamegraph

use std::net::SocketAddr;
use std::time::Duration;

use bytes::Bytes;
use http_body_util::Full;
use hyper::body::Incoming;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use pprof::protos::Message;
use tokio::net::TcpListener;
use tokio::sync::Mutex;
use tracing::{info, warn};

/// Serialize profile collection — Go's pprof also runs one CPU profile at a time.
static PROFILE_LOCK: Mutex<()> = Mutex::const_new(());

pub async fn serve_pprof(addr: SocketAddr) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let ln = TcpListener::bind(addr).await?;
    info!("pprof endpoint listening on {addr}");

    loop {
        let (stream, _) = ln.accept().await?;
        tokio::spawn(async move {
            let io = TokioIo::new(stream);
            let svc = service_fn(handle);
            if let Err(e) = hyper::server::conn::http1::Builder::new()
                .serve_connection(io, svc)
                .await
            {
                warn!("pprof conn: {e}");
            }
        });
    }
}

async fn handle(
    req: Request<Incoming>,
) -> Result<Response<Full<Bytes>>, std::convert::Infallible> {
    if req.method() != Method::GET {
        return Ok(simple(StatusCode::METHOD_NOT_ALLOWED, "text/plain", b"method not allowed"));
    }

    let path = req.uri().path();
    let seconds = query_seconds(req.uri().query()).unwrap_or(30).clamp(1, 300);

    match path {
        "/debug/pprof/profile" => match collect(seconds, Format::Protobuf).await {
            Ok(body) => Ok(Response::builder()
                .header("content-type", "application/octet-stream")
                .header("content-disposition", "attachment; filename=\"profile.pb\"")
                .body(Full::new(Bytes::from(body)))
                .unwrap()),
            Err(e) => Ok(simple(
                StatusCode::INTERNAL_SERVER_ERROR,
                "text/plain",
                format!("profile failed: {e}").as_bytes(),
            )),
        },
        "/debug/pprof/flamegraph" => match collect(seconds, Format::Flamegraph).await {
            Ok(body) => Ok(Response::builder()
                .header("content-type", "image/svg+xml")
                .body(Full::new(Bytes::from(body)))
                .unwrap()),
            Err(e) => Ok(simple(
                StatusCode::INTERNAL_SERVER_ERROR,
                "text/plain",
                format!("flamegraph failed: {e}").as_bytes(),
            )),
        },
        _ => Ok(simple(
            StatusCode::NOT_FOUND,
            "text/plain",
            b"try /debug/pprof/profile?seconds=30 or /debug/pprof/flamegraph?seconds=30",
        )),
    }
}

enum Format {
    Protobuf,
    Flamegraph,
}

async fn collect(seconds: u64, format: Format) -> Result<Vec<u8>, String> {
    // Hold the async mutex across the blocking profile so concurrent curls queue.
    let _guard = PROFILE_LOCK.lock().await;
    tokio::task::spawn_blocking(move || profile_blocking(seconds, format))
        .await
        .map_err(|e| format!("join: {e}"))?
}

fn profile_blocking(seconds: u64, format: Format) -> Result<Vec<u8>, String> {
    let guard = pprof::ProfilerGuardBuilder::default()
        .frequency(100)
        .blocklist(&["libc", "libgcc", "pthread", "vdso"])
        .build()
        .map_err(|e| format!("start profiler: {e}"))?;

    std::thread::sleep(Duration::from_secs(seconds));

    let report = guard
        .report()
        .build()
        .map_err(|e| format!("build report: {e}"))?;

    match format {
        Format::Protobuf => {
            let profile = report.pprof().map_err(|e| format!("pprof encode: {e}"))?;
            if profile.sample.is_empty() {
                return Err(
                    "no samples collected (empty profile — common on macOS; use Linux/Docker)"
                        .into(),
                );
            }
            let mut buf = Vec::new();
            profile
                .encode(&mut buf)
                .map_err(|e| format!("prost encode: {e}"))?;
            Ok(buf)
        }
        Format::Flamegraph => {
            let mut buf = Vec::new();
            report
                .flamegraph(&mut buf)
                .map_err(|e| format!("flamegraph: {e}"))?;
            if buf.is_empty() {
                return Err(
                    "no samples collected (empty flamegraph — common on macOS; use Linux/Docker)"
                        .into(),
                );
            }
            Ok(buf)
        }
    }
}

fn query_seconds(query: Option<&str>) -> Option<u64> {
    query?
        .split('&')
        .find_map(|p| p.strip_prefix("seconds="))
        .and_then(|v| v.parse().ok())
}

fn simple(status: StatusCode, content_type: &str, body: &[u8]) -> Response<Full<Bytes>> {
    Response::builder()
        .status(status)
        .header("content-type", content_type)
        .body(Full::new(Bytes::copy_from_slice(body)))
        .unwrap()
}
