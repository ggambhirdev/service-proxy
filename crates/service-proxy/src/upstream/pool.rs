//! Bounded per-upstream connection pool (phase 2+).

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use tokio::net::TcpStream;
use tokio::sync::{Mutex, Notify};

use super::dial::{dial, forward, Request, Response, UpstreamError};

pub struct Pool {
    addr: String,
    max_size: usize,
    idle: Mutex<Vec<TcpStream>>,
    outstanding: AtomicUsize,
    notify: Notify,
}

impl Pool {
    pub fn new(addr: String, max_size: usize) -> Self {
        Self {
            addr,
            max_size,
            idle: Mutex::new(Vec::new()),
            outstanding: AtomicUsize::new(0),
            notify: Notify::new(),
        }
    }

    pub async fn get(&self) -> Result<TcpStream, UpstreamError> {
        loop {
            {
                let mut idle = self.idle.lock().await;
                if let Some(conn) = idle.pop() {
                    return Ok(conn);
                }
            }

            let prev = self.outstanding.fetch_add(1, Ordering::AcqRel);
            if prev < self.max_size {
                match dial(&self.addr).await {
                    Ok(conn) => return Ok(conn),
                    Err(e) => {
                        self.outstanding.fetch_sub(1, Ordering::AcqRel);
                        return Err(e);
                    }
                }
            }
            self.outstanding.fetch_sub(1, Ordering::AcqRel);

            self.notify.notified().await;
        }
    }

    pub async fn put(&self, conn: TcpStream, healthy: bool) {
        if !healthy {
            drop(conn);
            self.outstanding.fetch_sub(1, Ordering::AcqRel);
            self.notify.notify_one();
            return;
        }

        let mut idle = self.idle.lock().await;
        if idle.len() < self.max_size {
            idle.push(conn);
            drop(idle);
            self.notify.notify_one();
        } else {
            drop(idle);
            drop(conn);
            self.outstanding.fetch_sub(1, Ordering::AcqRel);
            self.notify.notify_one();
        }
    }
}

pub struct Manager {
    pools: HashMap<String, Arc<Pool>>,
}

impl Manager {
    pub fn new(addrs: &[String], size_per_upstream: usize) -> Self {
        let mut pools = HashMap::with_capacity(addrs.len());
        for addr in addrs {
            pools.insert(addr.clone(), Arc::new(Pool::new(addr.clone(), size_per_upstream)));
        }
        Self { pools }
    }

    pub fn pool(&self, addr: &str) -> Option<Arc<Pool>> {
        self.pools.get(addr).cloned()
    }
}

pub async fn forward_pooled(pool: &Pool, req: &Request) -> Result<Response, UpstreamError> {
    let mut conn = pool.get().await?;
    match forward(&mut conn, req).await {
        Ok(resp) => {
            pool.put(conn, true).await;
            Ok(resp)
        }
        Err(e) => {
            pool.put(conn, false).await;
            Err(e)
        }
    }
}

#[derive(Clone)]
pub enum ForwarderKind {
    Dial,
    Pool(Arc<Manager>),
}

impl ForwarderKind {
    pub async fn forward(&self, addr: &str, req: &Request) -> Result<Response, UpstreamError> {
        match self {
            Self::Dial => super::dial::forward_http(addr, req).await,
            Self::Pool(manager) => {
                let pool = manager
                    .pool(addr)
                    .ok_or_else(|| UpstreamError::Parse(format!("no pool for {addr}")))?;
                forward_pooled(&pool, req).await
            }
        }
    }
}
