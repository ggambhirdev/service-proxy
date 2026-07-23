// Command proxy is the low-latency service proxy benchmark harness. A
// single binary serves every phase; PROXY_MODE selects the concurrency and
// protocol model.
package main

import (
	"encoding/json"
	"log"
	"net"
	"net/http"
	_ "net/http/pprof"

	"github.com/quic-go/quic-go/http3"
	"golang.org/x/net/http2"
	"golang.org/x/net/http2/h2c"
	"google.golang.org/grpc"

	"ggambhir.dev/service-proxy/internal/config"
	"ggambhir.dev/service-proxy/internal/grpcproxy"
	echopb "ggambhir.dev/service-proxy/internal/grpcproxy/proto"
	"ggambhir.dev/service-proxy/internal/proxyhttp"
	"ggambhir.dev/service-proxy/internal/quicproxy"
	"ggambhir.dev/service-proxy/internal/upstream"
)

func main() {
	cfg := config.Load()
	selector := upstream.NewSelector(cfg.UpstreamAddrs, cfg.LBStrategy)

	if cfg.PprofAddr != "" {
		go servePprof(cfg.PprofAddr)
	}

	if sp, ok := selector.(upstream.StatsProvider); ok && cfg.StatsAddr != "" {
		go serveStats(cfg.StatsAddr, sp)
	}

	switch cfg.Mode {
	case config.ModeQUIC:
		serveQUIC(cfg, selector)
		return
	case config.ModeHTTP3:
		serveHTTP3(cfg, selector)
		return
	}

	ln, err := net.Listen("tcp", cfg.ListenAddr)
	if err != nil {
		log.Fatalf("listen %s: %v", cfg.ListenAddr, err)
	}
	log.Printf("proxy listening on %s mode=%s upstreams=%v", cfg.ListenAddr, cfg.Mode, cfg.UpstreamAddrs)

	switch cfg.Mode {
	case config.ModeHTTP2:
		serveHTTP2(ln, selector)
	case config.ModeGRPC:
		serveGRPC(ln, cfg, selector)
	case config.ModePooled:
		servePooled(ln, cfg, selector)
	default:
		serveHTTP(ln, cfg, selector)
	}
}

// serveHTTP runs the raw-conn HTTP/1.1 accept loop used by phases 0 and 1a,
// dialing a fresh connection to the upstream for every request.
func serveHTTP(ln net.Listener, cfg config.Config, selector upstream.Selector) {
	forwarder := upstream.DialForwarder{}
	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("accept: %v", err)
			continue
		}

		switch cfg.Mode {
		case config.ModeTCPGoroutine:
			go proxyhttp.HandleConn(conn, selector, forwarder)
		default:
			// ModeTCPSync (phase 0): handle inline, no goroutine — fully
			// synchronous, single connection at a time.
			proxyhttp.HandleConn(conn, selector, forwarder)
		}
	}
}

// servePooled runs the phase 2a accept loop: a bounded pool of connections
// per upstream (reused across requests) and a fixed-size worker pool that
// bounds goroutine growth. When all workers are busy and the job queue is
// full, Accept blocks — applying backpressure to the client.
func servePooled(ln net.Listener, cfg config.Config, selector upstream.Selector) {
	manager := upstream.NewManager(cfg.UpstreamAddrs, cfg.PoolSizePerUpstream)
	forwarder := upstream.PoolForwarder{Manager: manager}

	jobs := make(chan net.Conn, cfg.WorkerQueueDepth)
	for i := 0; i < cfg.WorkerPoolSize; i++ {
		go func() {
			for conn := range jobs {
				proxyhttp.HandleConn(conn, selector, forwarder)
			}
		}()
	}

	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("accept: %v", err)
			continue
		}
		jobs <- conn
	}
}

// serveQUIC runs the phase 3a raw-QUIC server (client<->proxy leg only;
// the proxy->upstream leg reuses phase 2a's pooled forwarding).
func serveQUIC(cfg config.Config, selector upstream.Selector) {
	tlsConf, err := quicproxy.GenerateSelfSignedTLSConfig([]string{"service-proxy-quic"})
	if err != nil {
		log.Fatalf("generate tls config: %v", err)
	}

	manager := upstream.NewManager(cfg.UpstreamAddrs, cfg.PoolSizePerUpstream)
	forwarder := upstream.PoolForwarder{Manager: manager}

	log.Printf("proxy listening on %s mode=%s upstreams=%v (quic/udp)", cfg.ListenAddr, cfg.Mode, cfg.UpstreamAddrs)
	if err := quicproxy.Serve(cfg.ListenAddr, tlsConf, selector, forwarder); err != nil {
		log.Fatalf("quic serve: %v", err)
	}
}

// serveHTTP3 runs the phase 3b HTTP/3 server (client<->proxy leg only;
// the proxy->upstream leg reuses phase 2a's pooled forwarding).
func serveHTTP3(cfg config.Config, selector upstream.Selector) {
	tlsConf, err := quicproxy.GenerateSelfSignedTLSConfig([]string{http3.NextProtoH3})
	if err != nil {
		log.Fatalf("generate tls config: %v", err)
	}

	manager := upstream.NewManager(cfg.UpstreamAddrs, cfg.PoolSizePerUpstream)
	forwarder := upstream.PoolForwarder{Manager: manager}
	handler := proxyhttp.Handler(selector, forwarder)

	log.Printf("proxy listening on %s mode=%s upstreams=%v (http3/udp)", cfg.ListenAddr, cfg.Mode, cfg.UpstreamAddrs)
	if err := quicproxy.ServeHTTP3(cfg.ListenAddr, tlsConf, handler); err != nil {
		log.Fatalf("http3 serve: %v", err)
	}
}

// serveGRPC runs the phase 2b gRPC server (client<->proxy leg only; the
// proxy->upstream leg uses pooled connections via upstream.PoolForwarder,
// the same pooling mechanism phase 2a uses — see servePooled).
func serveGRPC(ln net.Listener, cfg config.Config, selector upstream.Selector) {
	manager := upstream.NewManager(cfg.UpstreamAddrs, cfg.PoolSizePerUpstream)
	forwarder := upstream.PoolForwarder{Manager: manager}

	grpcServer := grpc.NewServer()
	echopb.RegisterEchoServiceServer(grpcServer, &grpcproxy.Server{Selector: selector, Forwarder: forwarder})
	if err := grpcServer.Serve(ln); err != nil {
		log.Fatalf("grpc serve: %v", err)
	}
}

// serveHTTP2 runs the phase 1b cleartext HTTP/2 (h2c) server: the same
// request/response forwarding as phase 1a's HandleConn, but multiplexed
// over a single HTTP/2 connection via net/http + h2c instead of one
// HTTP/1.1 connection per request. This isolates transport-layer
// multiplexing from the gRPC framing/protobuf overhead added in phase 2b —
// the proxy->upstream leg uses the same fresh-dial-per-request forwarder as
// phase 1a.
func serveHTTP2(ln net.Listener, selector upstream.Selector) {
	h2s := &http2.Server{}
	handler := h2c.NewHandler(proxyhttp.Handler(selector, upstream.DialForwarder{}), h2s)
	srv := &http.Server{Handler: handler}
	if err := srv.Serve(ln); err != nil {
		log.Fatalf("http2 serve: %v", err)
	}
}

// serveStats exposes per-upstream request distribution over HTTP for phase 5
// (enabled by STATS_ADDR). It runs on its own listener, out of band from the
// proxy's request hot path. GET /stats returns a JSON snapshot of every
// upstream's cumulative and in-flight request counts; GET /stats?reset=1
// zeroes the cumulative counters after snapshotting, so a benchmark can
// discard its warmup and record only the measured run's distribution.
func serveStats(addr string, sp upstream.StatsProvider) {
	mux := http.NewServeMux()
	mux.HandleFunc("/stats", func(w http.ResponseWriter, r *http.Request) {
		reset := r.URL.Query().Get("reset") == "1"
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(sp.Stats(reset)); err != nil {
			log.Printf("stats encode: %v", err)
		}
	})

	log.Printf("stats endpoint listening on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Printf("stats server: %v", err)
	}
}

// servePprof exposes net/http/pprof on addr (PPROF_ADDR). Opt-in so default
// benches stay uninstrumented; used for phase 6 Go flamegraphs.
func servePprof(addr string) {
	log.Printf("pprof endpoint listening on %s", addr)
	if err := http.ListenAndServe(addr, nil); err != nil {
		log.Printf("pprof server: %v", err)
	}
}
