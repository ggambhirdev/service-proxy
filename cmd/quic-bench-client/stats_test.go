package main

import (
	"errors"
	"testing"
	"time"
)

func TestPercentileNearestRank(t *testing.T) {
	sorted := []time.Duration{
		1 * time.Millisecond,
		2 * time.Millisecond,
		3 * time.Millisecond,
		4 * time.Millisecond,
		5 * time.Millisecond,
		6 * time.Millisecond,
		7 * time.Millisecond,
		8 * time.Millisecond,
		9 * time.Millisecond,
		10 * time.Millisecond,
	}

	tests := []struct {
		p    float64
		want time.Duration
	}{
		{0.10, 1 * time.Millisecond},
		{0.50, 5 * time.Millisecond},
		{0.99, 10 * time.Millisecond},
		{0.999, 10 * time.Millisecond},
	}

	for _, tt := range tests {
		if got := percentile(sorted, tt.p); got != tt.want {
			t.Errorf("percentile(%.3f) = %v, want %v", tt.p, got, tt.want)
		}
	}
}

func TestComputeLatencyStatsEmpty(t *testing.T) {
	got := computeLatencyStats(nil)
	if got != (latencyStats{}) {
		t.Errorf("computeLatencyStats(nil) = %+v, want zero value", got)
	}
}

func TestComputeLatencyStatsMinMax(t *testing.T) {
	d := []time.Duration{5 * time.Millisecond, 1 * time.Millisecond, 3 * time.Millisecond}
	got := computeLatencyStats(d)
	if got.min != 1*time.Millisecond {
		t.Errorf("min = %v, want 1ms", got.min)
	}
	if got.max != 5*time.Millisecond {
		t.Errorf("max = %v, want 5ms", got.max)
	}
}

func TestComputeReportCountsErrors(t *testing.T) {
	now := time.Now()
	errTest := errors.New("test error")
	samples := []sample{
		{seq: 1, intendedSend: now, actualSend: now, completed: now.Add(time.Millisecond)},
		{seq: 2, intendedSend: now, actualSend: now, completed: now.Add(2 * time.Millisecond)},
		{seq: 3, intendedSend: now, actualSend: now, completed: now, err: errTest},
	}

	r := computeReport(samples, time.Second)
	if r.offered != 3 {
		t.Errorf("offered = %d, want 3", r.offered)
	}
	if r.completed != 2 {
		t.Errorf("completed = %d, want 2", r.completed)
	}
	if r.errored != 1 {
		t.Errorf("errored = %d, want 1", r.errored)
	}
}
