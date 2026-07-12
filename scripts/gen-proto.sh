#!/usr/bin/env bash
# Regenerates Go code from internal/grpcproxy/proto/echo.proto.
# Requires protoc, protoc-gen-go and protoc-gen-go-grpc on PATH
# (the latter two: go install google.golang.org/protobuf/cmd/protoc-gen-go
# and google.golang.org/grpc/cmd/protoc-gen-go-grpc).
set -euo pipefail

cd "$(dirname "$0")/.."

export PATH="$PATH:$(go env GOPATH)/bin"

protoc \
  --go_out=. --go_opt=paths=source_relative \
  --go-grpc_out=. --go-grpc_opt=paths=source_relative \
  internal/grpcproxy/proto/echo.proto

echo "Generated internal/grpcproxy/proto/echo.pb.go and echo_grpc.pb.go"
