//! Load-balancing selectors. Mirrors go/internal/upstream/balancer.go.

use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::Arc;

use rand::RngExt;
use serde::Serialize;

pub const LB_ROUND_ROBIN: &str = "round-robin";
pub const LB_LEAST_CONN: &str = "least-conn";
pub const LB_P2C: &str = "p2c";

pub trait Selector: Send + Sync {
    fn next(&self) -> (String, i32);
    fn release(&self, token: i32);
}

pub trait StatsProvider: Selector {
    fn stats(&self, reset: bool) -> Vec<UpstreamStat>;
}

#[derive(Debug, Clone, Serialize)]
pub struct UpstreamStat {
    pub addr: String,
    pub total: i64,
    pub inflight: i64,
}

pub struct Fixed {
    addr: String,
}

impl Fixed {
    pub fn new(addr: String) -> Self {
        Self { addr }
    }
}

impl Selector for Fixed {
    fn next(&self) -> (String, i32) {
        (self.addr.clone(), -1)
    }
    fn release(&self, _token: i32) {}
}

pub struct RoundRobin {
    addrs: Vec<String>,
    counter: AtomicU64,
}

impl RoundRobin {
    pub fn new(addrs: Vec<String>) -> Self {
        Self {
            addrs,
            counter: AtomicU64::new(0),
        }
    }
}

impl Selector for RoundRobin {
    fn next(&self) -> (String, i32) {
        let i = self.counter.fetch_add(1, Ordering::Relaxed);
        let addr = self.addrs[i as usize % self.addrs.len()].clone();
        (addr, -1)
    }
    fn release(&self, _token: i32) {}
}

struct Counters {
    addrs: Vec<String>,
    total: Vec<AtomicI64>,
    inflight: Vec<AtomicI64>,
}

impl Counters {
    fn new(addrs: Vec<String>) -> Self {
        let n = addrs.len();
        Self {
            addrs,
            total: (0..n).map(|_| AtomicI64::new(0)).collect(),
            inflight: (0..n).map(|_| AtomicI64::new(0)).collect(),
        }
    }

    fn pick(&self, idx: usize) -> (String, i32) {
        self.total[idx].fetch_add(1, Ordering::Relaxed);
        self.inflight[idx].fetch_add(1, Ordering::Relaxed);
        (self.addrs[idx].clone(), idx as i32)
    }

    fn release(&self, token: i32) {
        if token >= 0 {
            self.inflight[token as usize].fetch_sub(1, Ordering::Relaxed);
        }
    }

    fn stats(&self, reset: bool) -> Vec<UpstreamStat> {
        self.addrs
            .iter()
            .enumerate()
            .map(|(i, addr)| {
                let total = self.total[i].load(Ordering::Relaxed);
                if reset {
                    self.total[i].fetch_sub(total, Ordering::Relaxed);
                }
                UpstreamStat {
                    addr: addr.clone(),
                    total,
                    inflight: self.inflight[i].load(Ordering::Relaxed),
                }
            })
            .collect()
    }
}

pub struct CountingRoundRobin {
    counters: Counters,
    counter: AtomicU64,
}

impl CountingRoundRobin {
    pub fn new(addrs: Vec<String>) -> Self {
        Self {
            counters: Counters::new(addrs),
            counter: AtomicU64::new(0),
        }
    }
}

impl Selector for CountingRoundRobin {
    fn next(&self) -> (String, i32) {
        let i = self.counter.fetch_add(1, Ordering::Relaxed);
        let idx = i as usize % self.counters.addrs.len();
        self.counters.pick(idx)
    }
    fn release(&self, token: i32) {
        self.counters.release(token);
    }
}

impl StatsProvider for CountingRoundRobin {
    fn stats(&self, reset: bool) -> Vec<UpstreamStat> {
        self.counters.stats(reset)
    }
}

pub struct LeastConn {
    counters: Counters,
}

impl LeastConn {
    pub fn new(addrs: Vec<String>) -> Self {
        Self {
            counters: Counters::new(addrs),
        }
    }

    /// Test helper: set inflight for index.
    #[cfg(test)]
    pub fn set_inflight(&self, idx: usize, v: i64) {
        self.counters.inflight[idx].store(v, Ordering::Relaxed);
    }
}

impl Selector for LeastConn {
    fn next(&self) -> (String, i32) {
        let mut best = 0usize;
        let mut best_load = self.counters.inflight[0].load(Ordering::Relaxed);
        let mut ties = 1usize;
        let mut rng = rand::rng();
        for i in 1..self.counters.addrs.len() {
            let load = self.counters.inflight[i].load(Ordering::Relaxed);
            if load < best_load {
                best = i;
                best_load = load;
                ties = 1;
            } else if load == best_load {
                ties += 1;
                if rng.random_range(0..ties) == 0 {
                    best = i;
                }
            }
        }
        self.counters.pick(best)
    }
    fn release(&self, token: i32) {
        self.counters.release(token);
    }
}

impl StatsProvider for LeastConn {
    fn stats(&self, reset: bool) -> Vec<UpstreamStat> {
        self.counters.stats(reset)
    }
}

pub struct P2C {
    counters: Counters,
}

impl P2C {
    pub fn new(addrs: Vec<String>) -> Self {
        Self {
            counters: Counters::new(addrs),
        }
    }

    #[cfg(test)]
    pub fn set_inflight(&self, idx: usize, v: i64) {
        self.counters.inflight[idx].store(v, Ordering::Relaxed);
    }
}

impl Selector for P2C {
    fn next(&self) -> (String, i32) {
        let n = self.counters.addrs.len();
        let mut rng = rand::rng();
        let mut i = rng.random_range(0..n);
        let mut j = rng.random_range(0..n - 1);
        if j >= i {
            j += 1;
        }
        if self.counters.inflight[j].load(Ordering::Relaxed)
            < self.counters.inflight[i].load(Ordering::Relaxed)
        {
            i = j;
        }
        self.counters.pick(i)
    }
    fn release(&self, token: i32) {
        self.counters.release(token);
    }
}

impl StatsProvider for P2C {
    fn stats(&self, reset: bool) -> Vec<UpstreamStat> {
        self.counters.stats(reset)
    }
}

/// Type-erased selector with optional stats.
pub enum SelectorKind {
    Fixed(Fixed),
    RoundRobin(RoundRobin),
    CountingRoundRobin(CountingRoundRobin),
    LeastConn(LeastConn),
    P2C(P2C),
}

impl Selector for SelectorKind {
    fn next(&self) -> (String, i32) {
        match self {
            Self::Fixed(s) => s.next(),
            Self::RoundRobin(s) => s.next(),
            Self::CountingRoundRobin(s) => s.next(),
            Self::LeastConn(s) => s.next(),
            Self::P2C(s) => s.next(),
        }
    }
    fn release(&self, token: i32) {
        match self {
            Self::Fixed(s) => s.release(token),
            Self::RoundRobin(s) => s.release(token),
            Self::CountingRoundRobin(s) => s.release(token),
            Self::LeastConn(s) => s.release(token),
            Self::P2C(s) => s.release(token),
        }
    }
}

impl SelectorKind {
    pub fn stats(&self, reset: bool) -> Option<Vec<UpstreamStat>> {
        match self {
            Self::CountingRoundRobin(s) => Some(s.stats(reset)),
            Self::LeastConn(s) => Some(s.stats(reset)),
            Self::P2C(s) => Some(s.stats(reset)),
            _ => None,
        }
    }

    pub fn has_stats(&self) -> bool {
        matches!(
            self,
            Self::CountingRoundRobin(_) | Self::LeastConn(_) | Self::P2C(_)
        )
    }
}

pub fn new_selector(addrs: Vec<String>, strategy: &str) -> Arc<SelectorKind> {
    let kind = match strategy {
        LB_ROUND_ROBIN => SelectorKind::CountingRoundRobin(CountingRoundRobin::new(addrs)),
        LB_LEAST_CONN => SelectorKind::LeastConn(LeastConn::new(addrs)),
        LB_P2C => SelectorKind::P2C(P2C::new(addrs)),
        _ if addrs.len() == 1 => SelectorKind::Fixed(Fixed::new(addrs.into_iter().next().unwrap())),
        _ => SelectorKind::RoundRobin(RoundRobin::new(addrs)),
    };
    Arc::new(kind)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn least_conn_picks_least_loaded() {
        let lc = LeastConn::new(vec!["a".into(), "b".into(), "c".into()]);
        lc.set_inflight(0, 10);
        lc.set_inflight(2, 3);
        let (addr, tok) = lc.next();
        assert_eq!(addr, "b");
        assert_eq!(tok, 1);
        lc.release(tok);
    }

    #[test]
    fn p2c_picks_less_loaded() {
        let p = P2C::new(vec!["x".into(), "y".into()]);
        p.set_inflight(0, 5);
        for _ in 0..20 {
            let (addr, tok) = p.next();
            assert_eq!(addr, "y");
            p.release(tok);
        }
    }

    #[test]
    fn counting_rr_even() {
        let rr = CountingRoundRobin::new(vec!["a".into(), "b".into(), "c".into()]);
        for _ in 0..30 {
            let (_, tok) = rr.next();
            rr.release(tok);
        }
        for s in rr.stats(false) {
            assert_eq!(s.total, 10);
            assert_eq!(s.inflight, 0);
        }
    }

    #[test]
    fn stats_reset() {
        let lc = LeastConn::new(vec!["a".into(), "b".into()]);
        lc.next();
        lc.next();
        let total: i64 = lc.stats(true).iter().map(|s| s.total).sum();
        assert_eq!(total, 2);
        let snap = lc.stats(false);
        assert_eq!(snap.iter().map(|s| s.total).sum::<i64>(), 0);
        assert_eq!(snap.iter().map(|s| s.inflight).sum::<i64>(), 2);
    }

    #[test]
    fn new_selector_dispatch() {
        assert!(matches!(
            &*new_selector(vec!["a".into()], ""),
            SelectorKind::Fixed(_)
        ));
        assert!(matches!(
            &*new_selector(vec!["a".into(), "b".into()], ""),
            SelectorKind::RoundRobin(_)
        ));
        assert!(new_selector(vec!["a".into(), "b".into()], LB_P2C).has_stats());
        assert!(!new_selector(vec!["a".into(), "b".into()], "").has_stats());
    }
}
