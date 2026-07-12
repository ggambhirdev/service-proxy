package quicproxy

import (
	"context"
	"crypto/tls"
	"io"
	"log"
	"net/http"

	"github.com/quic-go/quic-go"

	"ggambhir.dev/service-proxy/internal/upstream"
)

// Serve listens for QUIC connections on addr and, for each stream,
// reads one length-prefixed frame, forwards its payload to an upstream
// echo server, and writes the response back as a length-prefixed frame.
// Each connection and each stream is handled in its own goroutine,
// demonstrating QUIC's native per-stream multiplexing (phase 3a).
func Serve(addr string, tlsConf *tls.Config, selector upstream.Selector, forwarder upstream.Forwarder) error {
	// quic-go's default MaxIncomingStreams (100) throttles a single
	// connection's stream churn well below what this benchmark needs to
	// exercise: at a moderate request rate on one connection, streams
	// weren't being reclaimed by the client fast enough to stay under the
	// default cap, and the connection would stall and hit its idle
	// timeout. Raised generously since the interesting benchmark limits
	// (congestion control, UDP buffer sizing) should be the ones that
	// actually bind.
	listener, err := quic.ListenAddr(addr, tlsConf, &quic.Config{MaxIncomingStreams: 10000})
	if err != nil {
		return err
	}
	defer listener.Close()

	for {
		conn, err := listener.Accept(context.Background())
		if err != nil {
			log.Printf("quic accept: %v", err)
			continue
		}
		go handleConn(conn, selector, forwarder)
	}
}

func handleConn(conn *quic.Conn, selector upstream.Selector, forwarder upstream.Forwarder) {
	for {
		stream, err := conn.AcceptStream(context.Background())
		if err != nil {
			return
		}
		go handleStream(stream, selector, forwarder)
	}
}

func handleStream(stream *quic.Stream, selector upstream.Selector, forwarder upstream.Forwarder) {
	defer stream.Close()
	// Close only closes the send side; without also releasing the receive
	// side here, every request leaks a half-open stream on the client's
	// connection. Invisible at low request rates, but it stalls the whole
	// connection once enough accumulate under sustained load.
	defer stream.CancelRead(0)

	payload, err := ReadFrame(stream)
	if err != nil {
		if err != io.EOF {
			log.Printf("read frame: %v", err)
		}
		return
	}

	addr := selector.Next()
	resp, err := forwarder.Forward(addr, &upstream.Request{
		Method: http.MethodPost,
		Path:   "/echo",
		Host:   addr,
		Header: http.Header{"Content-Type": []string{"application/octet-stream"}},
		Body:   payload,
	})
	if err != nil {
		log.Printf("forward to %s: %v", addr, err)
		return
	}

	if err := WriteFrame(stream, resp.Body); err != nil {
		log.Printf("write frame: %v", err)
	}
}
