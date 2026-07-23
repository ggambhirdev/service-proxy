package proxyhttp

import (
	"io"
	"net/http"

	"ggambhir.dev/service-proxy/internal/upstream"
)

// Handler returns a standard http.HandlerFunc that forwards each request's
// body to the upstream selected by selector via forwarder and writes the
// upstream's response back. Used by phase 3b (HTTP/3), where net/http's
// request/response objects replace the raw-conn framing used by
// HandleConn.
func Handler(selector upstream.Selector, forwarder upstream.Forwarder) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		r.Body.Close()
		if err != nil {
			http.Error(w, "failed to read body", http.StatusBadRequest)
			return
		}

		addr, tok := selector.Next()
		defer selector.Release(tok)
		resp, err := forwarder.Forward(addr, &upstream.Request{
			Method: r.Method,
			Path:   r.URL.RequestURI(),
			Host:   addr,
			Header: r.Header,
			Body:   body,
		})
		if err != nil {
			http.Error(w, "bad gateway", http.StatusBadGateway)
			return
		}

		for k, values := range resp.Header {
			if k == "Connection" || k == "Content-Length" {
				continue
			}
			for _, v := range values {
				w.Header().Add(k, v)
			}
		}
		w.WriteHeader(resp.StatusCode)
		w.Write(resp.Body)
	}
}
