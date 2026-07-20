// Command echo-upstream is a minimal HTTP server used as the upstream
// target for the service proxy. It echoes request bodies back to the
// caller and is reused unchanged across benchmark phases 0-4.
//
// Phase 5 adds an optional random response delay (RESPONSE_DELAY_MIN_MS /
// RESPONSE_DELAY_MAX_MS): when enabled on a subset of upstreams, it makes
// them deliberately slow so the load-aware selectors (least-connections,
// power-of-two-choices) have something to steer traffic away from. It only
// affects /echo, never the healthcheck.
package main

import (
	"io"
	"log"
	"math/rand/v2"
	"net/http"
	"os"
	"strconv"
	"time"
)

func main() {
	addr := os.Getenv("ECHO_ADDR")
	if addr == "" {
		addr = ":9000"
	}
	upstreamID := os.Getenv("UPSTREAM_ID")
	delayMin := getEnvDuration("RESPONSE_DELAY_MIN_MS", 0)
	delayMax := getEnvDuration("RESPONSE_DELAY_MAX_MS", 0)
	if delayMax < delayMin {
		delayMax = delayMin
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("/echo", func(w http.ResponseWriter, r *http.Request) {
		if upstreamID != "" {
			w.Header().Set("X-Upstream-ID", upstreamID)
		}

		// Optional artificial latency (phase 5). Kept well under
		// WriteTimeout so a slow response is never truncated.
		if delayMax > 0 {
			d := delayMin
			if delayMax > delayMin {
				d += rand.N(delayMax - delayMin)
			}
			time.Sleep(d)
		}

		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "failed to read body", http.StatusInternalServerError)
			return
		}

		if len(body) == 0 {
			w.Header().Set("Content-Type", "text/plain")
			w.WriteHeader(http.StatusOK)
			w.Write([]byte("echo-ok\n"))
			return
		}

		if ct := r.Header.Get("Content-Type"); ct != "" {
			w.Header().Set("Content-Type", ct)
		}
		w.WriteHeader(http.StatusOK)
		w.Write(body)
	})

	srv := &http.Server{
		Addr:         addr,
		Handler:      mux,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 5 * time.Second,
	}

	log.Printf("echo-upstream listening on %s (upstream_id=%q delay=%v..%v)", addr, upstreamID, delayMin, delayMax)
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}

// getEnvDuration reads key as an integer number of milliseconds, returning
// def when unset, empty, or unparseable.
func getEnvDuration(key string, def time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if ms, err := strconv.Atoi(v); err == nil {
			return time.Duration(ms) * time.Millisecond
		}
	}
	return def
}
