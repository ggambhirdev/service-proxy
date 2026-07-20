// Package config parses the environment-variable configuration shared by
// cmd/proxy across all benchmark phases. Behavior is selected at runtime via
// PROXY_MODE so a single binary/image serves every phase.
package config

import (
	"os"
	"strconv"
	"strings"
)

// Mode selects which proxy implementation cmd/proxy runs.
type Mode string

const (
	ModeTCPSync      Mode = "tcp-sync"      // phase 0: synchronous, no goroutines
	ModeTCPGoroutine Mode = "tcp-goroutine" // phase 1a: goroutine-per-connection
	ModeHTTP2        Mode = "http2"         // phase 1b: cleartext HTTP/2 (h2c), no gRPC
	ModeGRPC         Mode = "grpc"          // phase 2b
	ModePooled       Mode = "pooled"        // phase 2a: connection pool + worker pool
	ModeQUIC         Mode = "quic"          // phase 3a
	ModeHTTP3        Mode = "http3"         // phase 3b
)

// Config holds all proxy configuration, populated from environment
// variables with sensible defaults for local/dev use.
type Config struct {
	// ListenAddr is the address the proxy listens on for client traffic.
	ListenAddr string
	// UpstreamAddrs is the set of upstream echo-server addresses the proxy
	// forwards to. Phase 0 uses a single address; phase 1a+ uses 2-3 for
	// round-robin.
	UpstreamAddrs []string
	// Mode selects the proxy implementation (see Mode constants).
	Mode Mode

	// LBStrategy selects the load-balancing strategy (phase 5): one of
	// upstream.LBRoundRobin / LBLeastConn / LBP2C. Empty keeps the
	// pre-phase-5 behavior (Fixed / plain round-robin), so phases 0-3b are
	// unaffected.
	LBStrategy string
	// StatsAddr, if non-empty, is the address of an out-of-band HTTP
	// endpoint exposing per-upstream request distribution (phase 5). Empty
	// disables it.
	StatsAddr string

	// PoolSizePerUpstream bounds the number of pooled connections kept open
	// to each upstream (phase 2+).
	PoolSizePerUpstream int
	// WorkerPoolSize bounds the number of goroutines processing client
	// connections concurrently (phase 2+).
	WorkerPoolSize int
	// WorkerQueueDepth bounds the backlog of accepted connections waiting
	// for a free worker before Accept() blocks, applying backpressure
	// (phase 2+).
	WorkerQueueDepth int
}

// Load reads configuration from the environment, applying defaults.
func Load() Config {
	cfg := Config{
		ListenAddr:          getEnv("LISTEN_ADDR", ":8080"),
		UpstreamAddrs:       splitAddrs(getEnv("UPSTREAM_ADDRS", getEnv("UPSTREAM_ADDR", "upstream:9000"))),
		Mode:                Mode(getEnv("PROXY_MODE", string(ModeTCPSync))),
		LBStrategy:          getEnv("LB_STRATEGY", ""),
		StatsAddr:           getEnv("STATS_ADDR", ""),
		PoolSizePerUpstream: getEnvInt("POOL_SIZE_PER_UPSTREAM", 16),
		WorkerPoolSize:      getEnvInt("WORKER_POOL_SIZE", 64),
		WorkerQueueDepth:    getEnvInt("WORKER_QUEUE_DEPTH", 256),
	}
	return cfg
}

func splitAddrs(s string) []string {
	parts := strings.Split(s, ",")
	addrs := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			addrs = append(addrs, p)
		}
	}
	return addrs
}

func getEnv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func getEnvInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}
