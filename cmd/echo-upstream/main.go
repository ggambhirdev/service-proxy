// Command echo-upstream is a minimal HTTP server used as the upstream
// target for the service proxy. It echoes request bodies back to the
// caller and is reused unchanged across benchmark phases.
package main

import (
	"io"
	"log"
	"net/http"
	"os"
	"time"
)

func main() {
	addr := os.Getenv("ECHO_ADDR")
	if addr == "" {
		addr = ":9000"
	}
	upstreamID := os.Getenv("UPSTREAM_ID")

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("/echo", func(w http.ResponseWriter, r *http.Request) {
		if upstreamID != "" {
			w.Header().Set("X-Upstream-ID", upstreamID)
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

	log.Printf("echo-upstream listening on %s (upstream_id=%q)", addr, upstreamID)
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}
