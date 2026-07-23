// Command http3-smoke-client is a minimal correctness check for phase 3b:
// it sends an HTTP/3 request to the proxy and verifies the body echoes
// back unchanged. Avoids relying on macOS system curl's inconsistent
// HTTP/3 support.
package main

import (
	"bytes"
	"crypto/tls"
	"flag"
	"io"
	"log"
	"net/http"

	"github.com/quic-go/quic-go/http3"
)

func main() {
	url := flag.String("url", "https://localhost:8443/echo", "proxy HTTP/3 URL")
	payload := flag.String("payload", "hello-phase3b", "payload to echo")
	flag.Parse()

	client := &http.Client{
		Transport: &http3.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		},
	}

	resp, err := client.Post(*url, "application/octet-stream", bytes.NewReader([]byte(*payload)))
	if err != nil {
		log.Fatalf("POST %s: %v", *url, err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		log.Fatalf("read body: %v", err)
	}

	if string(body) != *payload {
		log.Fatalf("FAIL: expected %q, got %q (status %s)", *payload, body, resp.Status)
	}

	log.Printf("PASS: echoed %q (status %s)", body, resp.Status)
}
