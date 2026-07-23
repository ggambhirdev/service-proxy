//! Environment-variable configuration shared across all PROXY_MODE values.


use std::env;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    TcpSync,
    TcpGoroutine,
    Http2,
    Grpc,
    Pooled,
    Quic,
    Http3,
}

impl Mode {
    pub fn parse(s: &str) -> Self {
        match s {
            "tcp-goroutine" => Self::TcpGoroutine,
            "http2" => Self::Http2,
            "grpc" => Self::Grpc,
            "pooled" => Self::Pooled,
            "quic" => Self::Quic,
            "http3" => Self::Http3,
            _ => Self::TcpSync, // including "tcp-sync"
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::TcpSync => "tcp-sync",
            Self::TcpGoroutine => "tcp-goroutine",
            Self::Http2 => "http2",
            Self::Grpc => "grpc",
            Self::Pooled => "pooled",
            Self::Quic => "quic",
            Self::Http3 => "http3",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Config {
    pub listen_addr: String,
    pub upstream_addrs: Vec<String>,
    pub mode: Mode,
    pub lb_strategy: String,
    pub stats_addr: String,
    pub pprof_addr: String,
    pub pool_size_per_upstream: usize,
    pub worker_pool_size: usize,
    pub worker_queue_depth: usize,
}

impl Config {
    pub fn load() -> Self {
        Self {
            listen_addr: env_or("LISTEN_ADDR", ":8080"),
            upstream_addrs: split_addrs(&env_or(
                "UPSTREAM_ADDRS",
                &env_or("UPSTREAM_ADDR", "upstream:9000"),
            )),
            mode: Mode::parse(&env_or("PROXY_MODE", "tcp-sync")),
            lb_strategy: env::var("LB_STRATEGY").unwrap_or_default(),
            stats_addr: env::var("STATS_ADDR").unwrap_or_default(),
            pprof_addr: env::var("PPROF_ADDR").unwrap_or_default(),
            pool_size_per_upstream: env_int("POOL_SIZE_PER_UPSTREAM", 16),
            worker_pool_size: env_int("WORKER_POOL_SIZE", 64),
            worker_queue_depth: env_int("WORKER_QUEUE_DEPTH", 256),
        }
    }
}

fn env_or(key: &str, default: &str) -> String {
    env::var(key).unwrap_or_else(|_| default.to_string())
}

fn env_int(key: &str, default: usize) -> usize {
    env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

fn split_addrs(s: &str) -> Vec<String> {
    s.split(',')
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .map(str::to_string)
        .collect()
}
