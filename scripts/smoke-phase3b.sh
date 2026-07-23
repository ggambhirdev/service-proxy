#!/usr/bin/env bash
# Smoke test for Phase 3b: brings up the proxy in HTTP/3-over-QUIC mode in
# front of 3 upstream echo servers, then runs cmd/http3-smoke-client to
# verify a POST /echo round-trips correctly over HTTP/3.
set -euo pipefail

cd "$(dirname "$0")/.."

COMPOSE_FILE="deploy/phase3b/docker-compose.yml"
URL="https://localhost:8443/echo"

cleanup() {
  docker compose -f "$COMPOSE_FILE" down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Building and starting Phase 3b stack..."
docker compose -f "$COMPOSE_FILE" up --build -d

echo "==> Waiting for proxy to accept HTTP/3 connections..."
for i in $(seq 1 30); do
  if go run ./cmd/http3-smoke-client -url "$URL" >/dev/null 2>&1; then
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "FAIL: proxy never became reachable" >&2
    docker compose -f "$COMPOSE_FILE" logs
    exit 1
  fi
  sleep 1
done

echo "==> Running HTTP/3 smoke client..."
go run ./cmd/http3-smoke-client -url "$URL"
