// Package grpcproxy implements the phase 2b client<->proxy protocol: gRPC
// over a single HTTP/2 connection, layering RPC framing and protobuf
// (de)serialization on top of the same transport-layer multiplexing phase
// 1b already exercises with plain h2c, instead of the per-request HTTP/1.1
// connections used in phase 1a. The proxy->upstream leg uses pooled
// connections via a Forwarder — the same upstream.PoolForwarder mechanism
// phase 2a uses — so gRPC no longer pays a fresh TCP dial per RPC on the
// upstream leg, and a 2a-vs-2b comparison isolates pure gRPC framing and
// protobuf overhead atop a shared pooled-upstream baseline.
package grpcproxy

import (
	"context"
	"net/http"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	pb "ggambhir.dev/service-proxy/internal/grpcproxy/proto"
	"ggambhir.dev/service-proxy/internal/upstream"
)

// Server implements the EchoService gRPC service by forwarding each call to
// an upstream echo server selected by Selector, using Forwarder to reach it.
type Server struct {
	pb.UnimplementedEchoServiceServer

	Selector  upstream.Selector
	Forwarder upstream.Forwarder
}

// Echo forwards req.Payload to an upstream over HTTP and returns its
// response body.
func (s *Server) Echo(ctx context.Context, req *pb.EchoRequest) (*pb.EchoResponse, error) {
	addr := s.Selector.Next()

	resp, err := s.Forwarder.Forward(addr, &upstream.Request{
		Method: http.MethodPost,
		Path:   "/echo",
		Host:   addr,
		Header: http.Header{"Content-Type": []string{"application/octet-stream"}},
		Body:   req.GetPayload(),
	})
	if err != nil {
		return nil, status.Errorf(codes.Unavailable, "forward to %s: %v", addr, err)
	}

	return &pb.EchoResponse{
		Payload:    resp.Body,
		UpstreamId: resp.Header.Get("X-Upstream-Id"),
	}, nil
}
