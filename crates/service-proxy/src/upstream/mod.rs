//! Upstream dial, pool, balancer, and Forwarder abstractions.
//! Mirrors go/internal/upstream.

mod balancer;
mod dial;
mod pool;

pub use balancer::*;
pub use dial::*;
pub use pool::*;
