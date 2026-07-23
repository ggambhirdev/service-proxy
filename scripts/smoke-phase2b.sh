#!/usr/bin/env bash
# Smoke test for Phase 2b: brings up the proxy in gRPC mode in front of 3
# upstream echo servers, then runs cmd/grpc-smoke-client to verify the
# EchoService RPC round-trips correctly.
set -euo pipefail

cd "$(dirname "$0")/.."

COMPOSE_FILE="deploy/phase2b/docker-compose.yml"

cleanup() {
  docker compose -f "$COMPOSE_FILE" down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Building and starting Phase 2b stack..."
docker compose -f "$COMPOSE_FILE" up --build -d

echo "==> Waiting for proxy to accept connections..."
for i in $(seq 1 30); do
  if go run ./cmd/grpc-smoke-client -addr localhost:8080 >/dev/null 2>&1; then
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "FAIL: proxy never became reachable" >&2
    docker compose -f "$COMPOSE_FILE" logs
    exit 1
  fi
  sleep 1
done

echo "==> Running gRPC smoke client..."
go run ./cmd/grpc-smoke-client -addr localhost:8080
