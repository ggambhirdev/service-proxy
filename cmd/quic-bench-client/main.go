// Command quic-bench-client is an open-loop, constant-rate load generator
// for phase 3a (raw QUIC): it dials one or more QUIC connections to the
// proxy, dispatches length-prefixed echo requests at a fixed offered rate
// for a configured duration, and reports p50/p99/p99.9 latency (both
// coordinated-omission corrected and raw) plus achieved throughput.
//
// Unlike cmd/quic-smoke-client, a single-shot correctness check polled by
// scripts/smoke-phase3a.sh, this tool is a load generator: the Makefile's
// bench3a target runs it twice per offered-load value, a discarded warmup
// followed by a measured run, the same pattern used for oha/ghz in the
// other benchmark phases.
package main

import (
	"context"
	"crypto/tls"
	"flag"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/quic-go/quic-go"
)

func main() {
	addr := flag.String("addr", "localhost:8443", "proxy QUIC address")
	payload := flag.String("payload", "hello-phase3a-bench", "request payload")
	rate := flag.Int("rate", 100, "offered load, requests/sec")
	duration := flag.Duration("duration", 30*time.Second, "measurement window")
	conns := flag.Int("conns", 1, "number of QUIC connections to spread load across")
	maxInflight := flag.Int("max-inflight", 50, "max concurrently-outstanding requests (streams)")
	timeout := flag.Duration("timeout", 5*time.Second, "per-request deadline")
	flag.Parse()

	if *rate <= 0 {
		log.Fatalf("-rate must be positive")
	}
	if *conns <= 0 {
		log.Fatalf("-conns must be positive")
	}
	if *maxInflight <= 0 {
		log.Fatalf("-max-inflight must be positive")
	}

	tlsConf := &tls.Config{
		InsecureSkipVerify: true,
		NextProtos:         []string{"service-proxy-quic"},
	}

	dialCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	connsList := make([]*quic.Conn, *conns)
	for i := range connsList {
		conn, err := quic.DialAddr(dialCtx, *addr, tlsConf, nil)
		if err != nil {
			log.Fatalf("dial %s: %v", *addr, err)
		}
		defer conn.CloseWithError(0, "")
		connsList[i] = conn
	}

	cfg := runConfig{
		rate:        *rate,
		duration:    *duration,
		maxInflight: *maxInflight,
		timeout:     *timeout,
		payload:     []byte(*payload),
	}

	start := time.Now()
	samples := run(connsList, cfg)
	wallClock := time.Since(start)

	r := computeReport(samples, wallClock)
	hdr := fmt.Sprintf("addr=%s rate=%d duration=%s conns=%d max-inflight=%d payload=%dB timeout=%s",
		*addr, *rate, *duration, *conns, *maxInflight, len(*payload), *timeout)
	fmt.Fprint(os.Stdout, formatReport(hdr, r))
}
