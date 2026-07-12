// Package upstream contains the proxy's logic for talking to upstream echo
// servers: dialing, request/response framing, connection selection
// (balancer.go) and pooling (pool.go, added in phase 2).
package upstream

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"net/http"
	"time"
)

// dialTimeout bounds how long dialing an upstream may take.
const dialTimeout = 5 * time.Second

// Request is a minimal representation of an HTTP request to forward to an
// upstream echo server. The body is read into memory up front so it can be
// replayed onto a freshly dialed or pooled connection.
type Request struct {
	Method string
	Path   string
	Host   string
	Header http.Header
	Body   []byte
}

// Response is a minimal representation of the upstream's HTTP response.
type Response struct {
	StatusCode int
	Header     http.Header
	Body       []byte
}

// Dial opens a fresh TCP connection to addr.
func Dial(addr string) (net.Conn, error) {
	return net.DialTimeout("tcp", addr, dialTimeout)
}

// Forward writes req to conn and reads back the upstream's response. conn
// must be a connection to an HTTP/1.1 server (the echo-upstream binary).
func Forward(conn net.Conn, req *Request) (*Response, error) {
	if err := writeRequest(conn, req); err != nil {
		return nil, err
	}
	return readResponse(conn)
}

// ForwardHTTP dials addr, forwards req, and closes the connection. It is
// the per-request-dial path used by phases 0, 1a and 1b (phase 2 replaces
// this with a pooled connection).
func ForwardHTTP(addr string, req *Request) (*Response, error) {
	conn, err := Dial(addr)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	return Forward(conn, req)
}

// writeRequest hand-serializes req onto w. Headers that describe framing
// (Content-Length, Connection) are recomputed rather than copied, since
// req.Body has already been read into memory and the upstream connection
// has its own lifecycle independent of the client connection.
func writeRequest(w io.Writer, req *Request) error {
	bw := bufio.NewWriter(w)

	if _, err := fmt.Fprintf(bw, "%s %s HTTP/1.1\r\n", req.Method, req.Path); err != nil {
		return err
	}
	if req.Host != "" {
		if _, err := fmt.Fprintf(bw, "Host: %s\r\n", req.Host); err != nil {
			return err
		}
	}
	for k, values := range req.Header {
		if k == "Connection" || k == "Content-Length" || k == "Host" {
			continue
		}
		for _, v := range values {
			if _, err := fmt.Fprintf(bw, "%s: %s\r\n", k, v); err != nil {
				return err
			}
		}
	}
	if _, err := fmt.Fprintf(bw, "Content-Length: %d\r\nConnection: keep-alive\r\n\r\n", len(req.Body)); err != nil {
		return err
	}
	if len(req.Body) > 0 {
		if _, err := bw.Write(req.Body); err != nil {
			return err
		}
	}
	return bw.Flush()
}

// readResponse reads a full HTTP/1.1 response off r, buffering the body
// into memory.
func readResponse(r io.Reader) (*Response, error) {
	resp, err := http.ReadResponse(bufio.NewReader(r), nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	return &Response{
		StatusCode: resp.StatusCode,
		Header:     resp.Header,
		Body:       body,
	}, nil
}

// WriteResponse hand-serializes resp onto w as an HTTP/1.1 response with
// Connection: close, matching the per-request connection lifecycle used by
// phases 0-2.
func WriteResponse(w io.Writer, resp *Response) error {
	bw := bufio.NewWriter(w)

	statusText := http.StatusText(resp.StatusCode)
	if _, err := fmt.Fprintf(bw, "HTTP/1.1 %d %s\r\n", resp.StatusCode, statusText); err != nil {
		return err
	}
	for k, values := range resp.Header {
		if k == "Connection" || k == "Content-Length" {
			continue
		}
		for _, v := range values {
			if _, err := fmt.Fprintf(bw, "%s: %s\r\n", k, v); err != nil {
				return err
			}
		}
	}
	if _, err := fmt.Fprintf(bw, "Content-Length: %d\r\nConnection: close\r\n\r\n", len(resp.Body)); err != nil {
		return err
	}
	if len(resp.Body) > 0 {
		if _, err := bw.Write(resp.Body); err != nil {
			return err
		}
	}
	return bw.Flush()
}

// WriteError writes a minimal error response to w.
func WriteError(w io.Writer, statusCode int) error {
	return WriteResponse(w, &Response{StatusCode: statusCode, Header: http.Header{}, Body: nil})
}
