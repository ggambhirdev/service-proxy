package upstream

import "sync/atomic"

// Selector chooses which upstream address a request should be forwarded to.
type Selector interface {
	Next() string
}

// Fixed is a Selector that always returns the same address (phase 0: a
// single upstream).
type Fixed string

// Next implements Selector.
func (f Fixed) Next() string { return string(f) }

// RoundRobin cycles through a fixed set of upstream addresses using an
// atomic counter, avoiding mutex contention between concurrent callers
// (phase 1a+: multiple upstreams, goroutine-per-connection).
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
func (r *RoundRobin) Next() string {
	i := r.counter.Add(1) - 1
	return r.addrs[i%uint64(len(r.addrs))]
}

// NewSelector returns a Fixed selector for a single address, or a
// RoundRobin selector for multiple addresses.
func NewSelector(addrs []string) Selector {
	if len(addrs) == 1 {
		return Fixed(addrs[0])
	}
	return NewRoundRobin(addrs)
}
