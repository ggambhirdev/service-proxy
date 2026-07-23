package main

import (
	"fmt"
	"math"
	"sort"
	"strings"
	"time"
)

type latencyStats struct {
	p50, p99, p999, min, max time.Duration
}

type report struct {
	offered        int
	completed      int
	errored        int
	wallClock      time.Duration
	correctedStats latencyStats
	rawStats       latencyStats
	errorCounts    map[string]int
}

// computeReport splits samples into successes and errors, and computes
// latency percentiles over two series: coordinated-omission-corrected
// (scheduled-send to completion) and raw service time (actual-send to
// completion, excluding time spent queued behind the concurrency limit).
// Errors are also grouped by message so a run's failure mode is visible
// without re-running under a debugger.
func computeReport(samples []sample, wallClock time.Duration) report {
	r := report{offered: len(samples), wallClock: wallClock, errorCounts: map[string]int{}}

	corrected := make([]time.Duration, 0, len(samples))
	raw := make([]time.Duration, 0, len(samples))

	for _, s := range samples {
		if s.err != nil {
			r.errored++
			r.errorCounts[s.err.Error()]++
			continue
		}
		r.completed++
		corrected = append(corrected, s.completed.Sub(s.intendedSend))
		raw = append(raw, s.completed.Sub(s.actualSend))
	}

	r.correctedStats = computeLatencyStats(corrected)
	r.rawStats = computeLatencyStats(raw)
	return r
}

func computeLatencyStats(d []time.Duration) latencyStats {
	if len(d) == 0 {
		return latencyStats{}
	}
	sorted := make([]time.Duration, len(d))
	copy(sorted, d)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })

	return latencyStats{
		p50:  percentile(sorted, 0.50),
		p99:  percentile(sorted, 0.99),
		p999: percentile(sorted, 0.999),
		min:  sorted[0],
		max:  sorted[len(sorted)-1],
	}
}

// percentile returns the p-th percentile of a pre-sorted slice using
// nearest-rank indexing.
func percentile(sorted []time.Duration, p float64) time.Duration {
	idx := int(math.Ceil(p*float64(len(sorted)))) - 1
	if idx < 0 {
		idx = 0
	}
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	return sorted[idx]
}

func formatReport(hdr string, r report) string {
	var b strings.Builder

	fmt.Fprintf(&b, "=== QUIC bench: %s ===\n\n", hdr)

	successRate := 0.0
	if r.offered > 0 {
		successRate = 100 * float64(r.completed) / float64(r.offered)
	}
	fmt.Fprintf(&b, "Requests:\n")
	fmt.Fprintf(&b, "  Offered:    %10d\n", r.offered)
	fmt.Fprintf(&b, "  Completed:  %10d (%.1f%%)\n", r.completed, successRate)
	fmt.Fprintf(&b, "  Errors:     %10d\n", r.errored)
	if r.errored > 0 {
		msgs := make([]string, 0, len(r.errorCounts))
		for msg := range r.errorCounts {
			msgs = append(msgs, msg)
		}
		sort.Slice(msgs, func(i, j int) bool { return r.errorCounts[msgs[i]] > r.errorCounts[msgs[j]] })
		fmt.Fprintf(&b, "  Error distribution:\n")
		for _, msg := range msgs {
			fmt.Fprintf(&b, "    [%d] %s\n", r.errorCounts[msg], msg)
		}
	}
	fmt.Fprintf(&b, "\n")

	throughput := 0.0
	if r.wallClock > 0 {
		throughput = float64(r.completed) / r.wallClock.Seconds()
	}
	fmt.Fprintf(&b, "Throughput:\n")
	fmt.Fprintf(&b, "  Achieved:             %.2f req/s\n", throughput)
	fmt.Fprintf(&b, "  Wall-clock duration:  %s\n\n", r.wallClock.Round(time.Millisecond))

	fmt.Fprintf(&b, "Latency, coordinated-omission corrected (scheduled-send to completion):\n")
	writeLatencyStats(&b, r.correctedStats)
	fmt.Fprintf(&b, "\nLatency, raw service time (actual-send to completion, excludes queueing):\n")
	writeLatencyStats(&b, r.rawStats)

	return b.String()
}

func writeLatencyStats(b *strings.Builder, s latencyStats) {
	fmt.Fprintf(b, "  p50:    %10s\n", fmtDur(s.p50))
	fmt.Fprintf(b, "  p99:    %10s\n", fmtDur(s.p99))
	fmt.Fprintf(b, "  p99.9:  %10s\n", fmtDur(s.p999))
	fmt.Fprintf(b, "  min:    %10s\n", fmtDur(s.min))
	fmt.Fprintf(b, "  max:    %10s\n", fmtDur(s.max))
}

func fmtDur(d time.Duration) string {
	return fmt.Sprintf("%.3f ms", float64(d.Microseconds())/1000)
}
