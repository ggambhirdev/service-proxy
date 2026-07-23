package quicproxy

import (
	"crypto/tls"
	"net/http"

	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/http3"
)

// ServeHTTP3 listens on addr and serves handler over HTTP/3 (phase 3b).
// handler is the same proxyhttp.Handler used to forward requests to
// upstreams; only the transport differs from earlier phases.
func ServeHTTP3(addr string, tlsConf *tls.Config, handler http.Handler) error {
	server := &http3.Server{
		Addr:      addr,
		TLSConfig: tlsConf,
		Handler:   handler,
		// See the matching comment in Serve (server.go): the same default
		// MaxIncomingStreams=100 stalls a single connection under
		// benchmark-level stream churn, since HTTP/3 opens a new request
		// stream per RPC just like raw QUIC does here.
		QUICConfig: &quic.Config{MaxIncomingStreams: 10000},
	}
	return server.ListenAndServe()
}
