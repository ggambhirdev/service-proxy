//! Opt-in Tokio runtime metrics via `Handle::metrics()`, exposed as JSON.
//!
//! Needs `--cfg tokio_unstable` at build time (`RuntimeMetrics` is a Tokio
//! *unstable* API, not gated behind a Cargo feature). This whole module is
//! `cfg`'d out otherwise, so a normal `cargo build --release` — the one used
//! for the actual Go-vs-Rust comparison numbers — is completely unaffected:
//! no extra dependency, no feature flag, nothing to opt out of by omission.
//! No `tracing`/`console-subscriber` overhead either — this is a plain
//! poll-based counter snapshot, not span instrumentation.
//!
//! Why this exists: on-CPU sampling, off-CPU blocked-time, and OS
//! scheduling-latency (see flamegraph-rust-perf/-offcpu, runqlat-rust) all
//! ruled themselves out as the cause of phase 1a's N=500 latency spike —
//! none of them can see queueing *inside* Tokio's own userspace task
//! scheduler, which is a layer up from anything the OS can observe. This
//! endpoint exposes that layer directly: per-worker local run-queue depth,
//! park/steal/poll counts, and busy time, straight from Tokio's own
//! bookkeeping.
//!
//! Build: `RUSTFLAGS="--cfg tokio_unstable" cargo build --release -p service-proxy`
//! Run:   `TOKIO_METRICS_ADDR=:6670 ./target/release/service-proxy`
//! Poll:  `curl http://localhost:6670/tokio-metrics`
//!
//! Portable: this is pure userspace Tokio API, no eBPF/perf/kernel
//! dependency, so unlike the OS-level tools it runs the same on macOS as
//! on Linux — no Docker or Linux bench box required.
#![cfg(tokio_unstable)]

use std::net::SocketAddr;

use bytes::Bytes;
use http_body_util::Full;
use hyper::body::Incoming;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use serde::Serialize;
use tokio::net::TcpListener;
use tokio::runtime::Handle;
use tracing::{info, warn};

#[derive(Serialize)]
struct WorkerMetrics {
    worker: usize,
    local_queue_depth: usize,
    park_count: u64,
    park_unpark_count: u64,
    total_busy_duration_us: u128,
    poll_count: u64,
    mean_poll_time_ns: u128,
    steal_count: u64,
    overflow_count: u64,
    noop_count: u64,
    local_schedule_count: u64,
}

#[derive(Serialize)]
struct RuntimeMetricsSnapshot {
    // Milliseconds since the Unix epoch, so a client polling repeatedly can
    // compute real deltas between snapshots without relying on its own
    // wall-clock (which can drift from request round-trip time).
    timestamp_ms: u128,
    num_workers: usize,
    num_alive_tasks: usize,
    global_queue_depth: usize,
    remote_schedule_count: u64,
    budget_forced_yield_count: u64,
    workers: Vec<WorkerMetrics>,
}

fn snapshot() -> RuntimeMetricsSnapshot {
    let metrics = Handle::current().metrics();
    let num_workers = metrics.num_workers();

    let workers = (0..num_workers)
        .map(|i| WorkerMetrics {
            worker: i,
            local_queue_depth: metrics.worker_local_queue_depth(i),
            park_count: metrics.worker_park_count(i),
            park_unpark_count: metrics.worker_park_unpark_count(i),
            total_busy_duration_us: metrics.worker_total_busy_duration(i).as_micros(),
            poll_count: metrics.worker_poll_count(i),
            mean_poll_time_ns: metrics.worker_mean_poll_time(i).as_nanos(),
            steal_count: metrics.worker_steal_count(i),
            overflow_count: metrics.worker_overflow_count(i),
            noop_count: metrics.worker_noop_count(i),
            local_schedule_count: metrics.worker_local_schedule_count(i),
        })
        .collect();

    RuntimeMetricsSnapshot {
        timestamp_ms: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis(),
        num_workers,
        num_alive_tasks: metrics.num_alive_tasks(),
        global_queue_depth: metrics.global_queue_depth(),
        remote_schedule_count: metrics.remote_schedule_count(),
        budget_forced_yield_count: metrics.budget_forced_yield_count(),
        workers,
    }
}

pub async fn serve_tokio_metrics(
    addr: SocketAddr,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let ln = TcpListener::bind(addr).await?;
    info!("tokio-metrics endpoint listening on {addr}");

    loop {
        let (stream, _) = ln.accept().await?;
        tokio::spawn(async move {
            let io = TokioIo::new(stream);
            let svc = service_fn(handle);
            if let Err(e) = hyper::server::conn::http1::Builder::new()
                .serve_connection(io, svc)
                .await
            {
                warn!("tokio-metrics conn: {e}");
            }
        });
    }
}

async fn handle(
    req: Request<Incoming>,
) -> Result<Response<Full<Bytes>>, std::convert::Infallible> {
    if req.method() != Method::GET || req.uri().path() != "/tokio-metrics" {
        return Ok(Response::builder()
            .status(StatusCode::NOT_FOUND)
            .header("content-type", "text/plain")
            .body(Full::new(Bytes::from_static(b"try /tokio-metrics")))
            .unwrap());
    }

    let body = serde_json::to_vec(&snapshot()).unwrap_or_default();
    Ok(Response::builder()
        .header("content-type", "application/json")
        .body(Full::new(Bytes::from(body)))
        .unwrap())
}
