package main

import (
	"context"
	"sync"
	"time"

	"github.com/quic-go/quic-go"

	"ggambhir.dev/service-proxy/internal/quicproxy"
)

// sample records one dispatched request's timing. intendedSend is the
// scheduled dispatch time (start + seq*interval), used to compute
// coordinated-omission-corrected latency; actualSend is when the request
// actually began (after any semaphore wait), used for raw service latency.
type sample struct {
	seq          int64
	intendedSend time.Time
	actualSend   time.Time
	completed    time.Time
	err          error
}

type runConfig struct {
	rate        int
	duration    time.Duration
	maxInflight int
	timeout     time.Duration
	payload     []byte
}

// run dispatches requests at a fixed offered rate (open-loop: one goroutine
// per tick, regardless of whether earlier requests have completed) for
// cfg.duration, round-robining across conns, and returns one sample per
// dispatched request. Backpressure is enforced by a bounded semaphore
// inside each dispatch goroutine, never by the ticker loop, so intended
// send times never drift due to overload.
func run(conns []*quic.Conn, cfg runConfig) []sample {
	interval := time.Second / time.Duration(cfg.rate)
	sem := make(chan struct{}, cfg.maxInflight)
	results := make(chan sample, cfg.maxInflight*2)

	var collected []sample
	done := make(chan struct{})
	go func() {
		for s := range results {
			collected = append(collected, s)
		}
		close(done)
	}()

	start := time.Now()
	deadline := start.Add(cfg.duration)
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	var wg sync.WaitGroup
	var seq int64
	for now := range ticker.C {
		if now.After(deadline) {
			break
		}
		seq++
		intended := start.Add(time.Duration(seq) * interval)
		conn := conns[int(seq-1)%len(conns)]
		wg.Add(1)
		go dispatchOne(conn, seq, intended, sem, results, cfg.payload, cfg.timeout, &wg)
	}

	wg.Wait()
	close(results)
	<-done
	return collected
}

func dispatchOne(conn *quic.Conn, seq int64, intended time.Time, sem chan struct{}, results chan<- sample, payload []byte, timeout time.Duration, wg *sync.WaitGroup) {
	defer wg.Done()
	sem <- struct{}{}
	defer func() { <-sem }()

	actualSend := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		results <- sample{seq, intended, actualSend, time.Now(), err}
		return
	}
	defer stream.Close()
	// Stream.Close() only closes the send side; the receive side stays
	// open until read to EOF or explicitly cancelled. We read exactly the
	// framed payload length and never issue a further Read, so without
	// this the receive side of every stream leaks — invisible at low
	// request rates, but it eventually stalls the whole connection once
	// enough un-reclaimed streams pile up.
	defer stream.CancelRead(0)
	_ = stream.SetDeadline(time.Now().Add(timeout))

	if err := quicproxy.WriteFrame(stream, payload); err != nil {
		results <- sample{seq, intended, actualSend, time.Now(), err}
		return
	}
	_, err = quicproxy.ReadFrame(stream)
	results <- sample{seq, intended, actualSend, time.Now(), err}
}
