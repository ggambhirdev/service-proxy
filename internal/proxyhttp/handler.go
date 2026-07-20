// Package proxyhttp implements the raw-conn HTTP forwarding logic used by
// phases 0, 1a and 2. The proxy speaks HTTP/1.1 on the client-facing side
// and hand-rolls request/response framing to the upstream so the
// concurrency model (sync, goroutine-per-connection, pooled+worker-pool)
// stays fully under our control.
package proxyhttp

import (
	"bufio"
	"io"
	"log"
	"net"
	"net/http"

	"ggambhir.dev/service-proxy/internal/upstream"
)

// HandleConn reads a single HTTP/1.1 request off conn, forwards it to the
// upstream selected by selector via forwarder, writes the response back to
// conn, and closes conn. It never panics or exits the caller's accept loop
// on error.
func HandleConn(conn net.Conn, selector upstream.Selector, forwarder upstream.Forwarder) {
	defer conn.Close()

	req, err := http.ReadRequest(bufio.NewReader(conn))
	if err != nil {
		if err != io.EOF {
			log.Printf("read request: %v", err)
		}
		return
	}

	body, err := io.ReadAll(req.Body)
	req.Body.Close()
	if err != nil {
		log.Printf("read request body: %v", err)
		upstream.WriteError(conn, http.StatusBadRequest)
		return
	}

	addr, tok := selector.Next()
	defer selector.Release(tok)
	resp, err := forwarder.Forward(addr, &upstream.Request{
		Method: req.Method,
		Path:   req.URL.RequestURI(),
		Host:   req.Host,
		Header: req.Header,
		Body:   body,
	})
	if err != nil {
		log.Printf("forward to %s: %v", addr, err)
		upstream.WriteError(conn, http.StatusBadGateway)
		return
	}

	if err := upstream.WriteResponse(conn, resp); err != nil {
		log.Printf("write response: %v", err)
	}
}
