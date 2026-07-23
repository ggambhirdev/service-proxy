package upstream

import (
	"math/rand/v2"
	"sync/atomic"
)

// Selector chooses which upstream address a request should be forwarded to.
//
// Next returns the chosen address and a token the caller must hand back to
// Release when the request completes. For load-aware selectors (phase 5:
// least-connections, power-of-two-choices) Release frees the upstream's
// in-flight slot; for the stateless selectors (Fixed, RoundRobin) the token
// is -1 and Release is a no-op. The token is a plain int (the upstream
// index) rather than a closure so selection stays allocation-free on the hot
// path.
type Selector interface {
	Next() (addr string, token int)
	Release(token int)
}

// Load-balancing strategy identifiers, selected via the LB_STRATEGY env var
// (phase 5). An empty strategy keeps the pre-phase-5 behavior (Fixed /
// plain RoundRobin), so phases 0-3 are unaffected.
const (
	LBRoundRobin = "round-robin" // phase 5a
	LBLeastConn  = "least-conn"  // phase 5b
	LBP2C        = "p2c"         // phase 5c
)

// Fixed is a Selector that always returns the same address (phase 0: a
// single upstream).
type Fixed string

// Next implements Selector.
func (f Fixed) Next() (string, int) { return string(f), -1 }

// Release implements Selector (no-op: Fixed tracks no load).
func (Fixed) Release(int) {}

// RoundRobin cycles through a fixed set of upstream addresses using an
// atomic counter, avoiding mutex contention between concurrent callers
// (phase 1a-3b: multiple upstreams, no load-awareness). It tracks no
// per-upstream state; phase 5's CountingRoundRobin adds that.
type RoundRobin struct {
	addrs   []string
	counter atomic.Uint64
}

// NewRoundRobin returns a RoundRobin selector over addrs. addrs must be
// non-empty.
func NewRoundRobin(addrs []string) *RoundRobin {
	return &RoundRobin{addrs: addrs}
}

// Next implements Selector.
func (r *RoundRobin) Next() (string, int) {
	i := r.counter.Add(1) - 1
	return r.addrs[i%uint64(len(r.addrs))], -1
}

// Release implements Selector (no-op: RoundRobin tracks no load).
func (*RoundRobin) Release(int) {}

// UpstreamStat is a snapshot of one upstream's routing counters, reported by
// selectors that implement StatsProvider (phase 5 distribution tracking).
type UpstreamStat struct {
	Addr     string `json:"addr"`
	Total    int64  `json:"total"`    // cumulative requests routed here
	InFlight int64  `json:"inflight"` // requests currently outstanding
}

// StatsProvider is implemented by the load-aware selectors so cmd/proxy can
// expose per-upstream request distribution (phase 5): so we can see where
// requests go, and whether the slow upstreams are being steered around.
type StatsProvider interface {
	// Stats returns a snapshot of every upstream's counters. If reset is
	// true, the cumulative Total counters are zeroed after the snapshot is
	// taken (used to isolate a measured run from its warmup); InFlight is a
	// live gauge and is never reset.
	Stats(reset bool) []UpstreamStat
}

// counters holds the shared per-upstream state the phase-5 selectors track,
// index-aligned to addrs. total is cumulative (for distribution reporting);
// inflight is a gauge incremented at selection and decremented at Release
// (the signal least-connections / P2C balance on).
type counters struct {
	addrs    []string
	total    []atomic.Int64
	inflight []atomic.Int64
}

func newCounters(addrs []string) counters {
	return counters{
		addrs:    addrs,
		total:    make([]atomic.Int64, len(addrs)),
		inflight: make([]atomic.Int64, len(addrs)),
	}
}

// pick records a selection on the upstream at idx and returns its address
// and idx as the release token.
func (c *counters) pick(idx int) (string, int) {
	c.total[idx].Add(1)
	c.inflight[idx].Add(1)
	return c.addrs[idx], idx
}

// Release implements Selector for all counting selectors.
func (c *counters) Release(token int) {
	if token >= 0 {
		c.inflight[token].Add(-1)
	}
}

// Stats implements StatsProvider for all counting selectors.
func (c *counters) Stats(reset bool) []UpstreamStat {
	stats := make([]UpstreamStat, len(c.addrs))
	for i := range c.addrs {
		total := c.total[i].Load()
		if reset {
			c.total[i].Add(-total)
		}
		stats[i] = UpstreamStat{
			Addr:     c.addrs[i],
			Total:    total,
			InFlight: c.inflight[i].Load(),
		}
	}
	return stats
}

// CountingRoundRobin is round-robin (phase 5a) plus the per-upstream
// counters, so its even distribution can be compared against the load-aware
// strategies. Selection is identical to RoundRobin; only the bookkeeping
// differs.
type CountingRoundRobin struct {
	counters
	counter atomic.Uint64
}

// NewCountingRoundRobin returns a CountingRoundRobin over addrs.
func NewCountingRoundRobin(addrs []string) *CountingRoundRobin {
	return &CountingRoundRobin{counters: newCounters(addrs)}
}

// Next implements Selector.
func (r *CountingRoundRobin) Next() (string, int) {
	i := r.counter.Add(1) - 1
	return r.pick(int(i % uint64(len(r.addrs))))
}

// LeastConn selects the upstream with the fewest in-flight requests (phase
// 5b), so slow upstreams — which accumulate in-flight requests while they
// sleep — receive proportionally less traffic. Ties (e.g. several idle fast
// upstreams all at zero) are broken by a uniform random choice among the
// tied minima via reservoir sampling, so load spreads evenly instead of
// piling onto the lowest index.
type LeastConn struct {
	counters
}

// NewLeastConn returns a LeastConn selector over addrs.
func NewLeastConn(addrs []string) *LeastConn {
	return &LeastConn{counters: newCounters(addrs)}
}

// Next implements Selector.
func (l *LeastConn) Next() (string, int) {
	best := 0
	bestLoad := l.inflight[0].Load()
	ties := 1
	for i := 1; i < len(l.addrs); i++ {
		load := l.inflight[i].Load()
		switch {
		case load < bestLoad:
			best, bestLoad, ties = i, load, 1
		case load == bestLoad:
			// Reservoir sample: pick each equal-minimum upstream with
			// probability 1/ties so ties spread uniformly.
			ties++
			if rand.IntN(ties) == 0 {
				best = i
			}
		}
	}
	return l.pick(best)
}

// P2C is power-of-two-choices (phase 5c): sample two distinct upstreams at
// random and route to the less loaded of the two. It approximates
// least-connections' load-shedding without the O(n) scan, and avoids the
// herd behavior a global-minimum selector can exhibit at high fan-out.
type P2C struct {
	counters
}

// NewP2C returns a P2C selector over addrs.
func NewP2C(addrs []string) *P2C {
	return &P2C{counters: newCounters(addrs)}
}

// Next implements Selector.
func (p *P2C) Next() (string, int) {
	n := len(p.addrs)
	i := rand.IntN(n)
	j := rand.IntN(n - 1)
	if j >= i {
		j++ // map j into [0,n) \ {i} so the two picks are distinct
	}
	if p.inflight[j].Load() < p.inflight[i].Load() {
		i = j
	}
	return p.pick(i)
}

// NewSelector returns a Selector for addrs under the given load-balancing
// strategy. An empty strategy preserves the pre-phase-5 behavior (Fixed for
// a single address, plain RoundRobin otherwise) so phases 0-3b are
// unchanged; the phase-5 strategies use the counting, load-aware selectors.
// An unrecognized non-empty strategy falls back to the pre-phase-5 behavior.
func NewSelector(addrs []string, strategy string) Selector {
	switch strategy {
	case LBRoundRobin:
		return NewCountingRoundRobin(addrs)
	case LBLeastConn:
		return NewLeastConn(addrs)
	case LBP2C:
		return NewP2C(addrs)
	}
	if len(addrs) == 1 {
		return Fixed(addrs[0])
	}
	return NewRoundRobin(addrs)
}
