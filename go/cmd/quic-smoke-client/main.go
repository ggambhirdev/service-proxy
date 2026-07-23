// Command quic-smoke-client is a minimal correctness check for phase 3a: it
// dials the proxy over QUIC, opens a stream, sends one length-prefixed
// frame, and verifies the response frame echoes the payload unchanged.
package main

import (
	"context"
	"crypto/tls"
	"flag"
	"log"
	"time"

	"github.com/quic-go/quic-go"

	"ggambhir.dev/service-proxy/internal/quicproxy"
)

func main() {
	addr := flag.String("addr", "localhost:8443", "proxy QUIC address")
	payload := flag.String("payload", "hello-phase3a", "payload to echo")
	flag.Parse()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tlsConf := &tls.Config{
		InsecureSkipVerify: true,
		NextProtos:         []string{"service-proxy-quic"},
	}

	conn, err := quic.DialAddr(ctx, *addr, tlsConf, nil)
	if err != nil {
		log.Fatalf("dial %s: %v", *addr, err)
	}
	defer conn.CloseWithError(0, "")

	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		log.Fatalf("open stream: %v", err)
	}
	defer stream.Close()

	if err := quicproxy.WriteFrame(stream, []byte(*payload)); err != nil {
		log.Fatalf("write frame: %v", err)
	}

	resp, err := quicproxy.ReadFrame(stream)
	if err != nil {
		log.Fatalf("read frame: %v", err)
	}

	if string(resp) != *payload {
		log.Fatalf("FAIL: expected %q, got %q", *payload, resp)
	}

	log.Printf("PASS: echoed %q", resp)
}
