#!/usr/bin/env bash
# Smoke test for Phase 3a: brings up the proxy in raw-QUIC mode in front of
# 3 upstream echo servers, then runs cmd/quic-smoke-client to verify a
# length-prefixed frame round-trips correctly over a QUIC stream.
set -euo pipefail

cd "$(dirname "$0")/.."

COMPOSE_FILE="deploy/phase3a/docker-compose.yml"

cleanup() {
  docker compose -f "$COMPOSE_FILE" down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Building and starting Phase 3a stack..."
docker compose -f "$COMPOSE_FILE" up --build -d

echo "==> Waiting for proxy to accept QUIC connections..."
for i in $(seq 1 30); do
  if go run ./cmd/quic-smoke-client -addr localhost:8443 >/dev/null 2>&1; then
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "FAIL: proxy never became reachable" >&2
    docker compose -f "$COMPOSE_FILE" logs
    exit 1
  fi
  sleep 1
done

echo "==> Running QUIC smoke client..."
go run ./cmd/quic-smoke-client -addr localhost:8443
