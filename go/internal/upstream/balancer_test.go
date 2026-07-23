package upstream

import "testing"

// TestLeastConnPicksLeastLoaded verifies least-connections routes to the
// upstream with the fewest in-flight requests — the whole point of phase 5b.
func TestLeastConnPicksLeastLoaded(t *testing.T) {
	lc := NewLeastConn([]string{"a", "b", "c"})
	lc.inflight[0].Store(10) // a: busy
	lc.inflight[2].Store(3)  // c: moderately busy
	// b is idle, so it must win.

	addr, tok := lc.Next()
	if addr != "b" {
		t.Fatalf("want least-loaded b, got %s", addr)
	}
	if tok != 1 {
		t.Fatalf("want release token 1 (index of b), got %d", tok)
	}
	if got := lc.inflight[1].Load(); got != 1 {
		t.Fatalf("Next should have incremented b's in-flight to 1, got %d", got)
	}
	lc.Release(tok)
	if got := lc.inflight[1].Load(); got != 0 {
		t.Fatalf("Release should have decremented b's in-flight to 0, got %d", got)
	}
}

// TestP2CPicksLessLoaded pins P2C to two upstreams: with n=2 it always
// samples both distinct indices, so selection is deterministic and must land
// on the less-loaded one. This also exercises both branches of the
// distinct-index mapping (j >= i ? j+1 : j).
func TestP2CPicksLessLoaded(t *testing.T) {
	p := NewP2C([]string{"x", "y"})
	p.inflight[0].Store(5) // x busy; y idle

	for i := 0; i < 20; i++ {
		addr, tok := p.Next()
		if addr != "y" {
			t.Fatalf("iter %d: want less-loaded y, got %s", i, addr)
		}
		p.Release(tok) // keep y idle so the invariant holds each iteration
	}
}

// TestCountingRoundRobinEvenDistribution verifies 5a spreads load evenly and
// reports it through Stats, and that Release drains in-flight back to zero.
func TestCountingRoundRobinEvenDistribution(t *testing.T) {
	rr := NewCountingRoundRobin([]string{"a", "b", "c"})
	for i := 0; i < 30; i++ {
		_, tok := rr.Next()
		rr.Release(tok)
	}

	for _, s := range rr.Stats(false) {
		if s.Total != 10 {
			t.Fatalf("want 10 requests to %s, got %d", s.Addr, s.Total)
		}
		if s.InFlight != 0 {
			t.Fatalf("want 0 in-flight to %s after release, got %d", s.Addr, s.InFlight)
		}
	}
}

// TestStatsReset verifies the ?reset=1 semantics used by bench5: cumulative
// Total is snapshotted then zeroed, while the live InFlight gauge is left
// alone.
func TestStatsReset(t *testing.T) {
	lc := NewLeastConn([]string{"a", "b"})
	lc.Next() // no Release: leaves one request in-flight
	lc.Next() // no Release: leaves a second in-flight

	var total int64
	for _, s := range lc.Stats(true) {
		total += s.Total
	}
	if total != 2 {
		t.Fatalf("want 2 total before reset, got %d", total)
	}

	var totalAfter, inflightAfter int64
	for _, s := range lc.Stats(false) {
		totalAfter += s.Total
		inflightAfter += s.InFlight
	}
	if totalAfter != 0 {
		t.Fatalf("want Total zeroed after reset, got %d", totalAfter)
	}
	if inflightAfter != 2 {
		t.Fatalf("want InFlight preserved at 2, got %d", inflightAfter)
	}
}

// TestNewSelector verifies strategy dispatch and that only the load-aware
// selectors expose distribution stats.
func TestNewSelector(t *testing.T) {
	if _, ok := NewSelector([]string{"a"}, "").(Fixed); !ok {
		t.Error("empty strategy + single addr: want Fixed")
	}
	if _, ok := NewSelector([]string{"a", "b"}, "").(*RoundRobin); !ok {
		t.Error("empty strategy + multi addr: want plain *RoundRobin")
	}
	if _, ok := NewSelector([]string{"a", "b"}, LBRoundRobin).(*CountingRoundRobin); !ok {
		t.Error("round-robin: want *CountingRoundRobin")
	}
	if _, ok := NewSelector([]string{"a", "b"}, LBLeastConn).(*LeastConn); !ok {
		t.Error("least-conn: want *LeastConn")
	}
	if _, ok := NewSelector([]string{"a", "b"}, LBP2C).(*P2C); !ok {
		t.Error("p2c: want *P2C")
	}

	// Phases 0-3 selectors must NOT be StatsProvider (stats endpoint stays off);
	// phase-5 selectors must be.
	if _, ok := NewSelector([]string{"a", "b"}, "").(StatsProvider); ok {
		t.Error("plain RoundRobin should not implement StatsProvider")
	}
	if _, ok := NewSelector([]string{"a", "b"}, LBP2C).(StatsProvider); !ok {
		t.Error("P2C should implement StatsProvider")
	}
}
