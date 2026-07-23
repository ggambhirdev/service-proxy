// Command grpc-smoke-client is a minimal correctness check for phase 2b: it
// dials the proxy's gRPC EchoService, sends a known payload, and verifies
// it round-trips unchanged.
package main

import (
	"context"
	"flag"
	"log"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	pb "ggambhir.dev/service-proxy/internal/grpcproxy/proto"
)

func main() {
	addr := flag.String("addr", "localhost:8080", "proxy gRPC address")
	payload := flag.String("payload", "hello-phase2b", "payload to echo")
	flag.Parse()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, err := grpc.NewClient(*addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		log.Fatalf("dial %s: %v", *addr, err)
	}
	defer conn.Close()

	client := pb.NewEchoServiceClient(conn)
	resp, err := client.Echo(ctx, &pb.EchoRequest{Payload: []byte(*payload)})
	if err != nil {
		log.Fatalf("Echo: %v", err)
	}

	if string(resp.GetPayload()) != *payload {
		log.Fatalf("FAIL: expected %q, got %q", *payload, resp.GetPayload())
	}

	log.Printf("PASS: echoed %q (upstream_id=%q)", resp.GetPayload(), resp.GetUpstreamId())
}
