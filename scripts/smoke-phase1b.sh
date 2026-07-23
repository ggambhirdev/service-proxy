#!/usr/bin/env bash
# Smoke test for Phase 1b: brings up the proxy in cleartext HTTP/2 (h2c)
# mode in front of 3 upstream echo servers, sends several requests over a
# single HTTP/2 connection, and asserts both echo correctness and
# round-robin distribution across upstreams.
set -euo pipefail

cd "$(dirname "$0")/.."

COMPOSE_FILE="deploy/phase1b/docker-compose.yml"
PROXY_URL="http://localhost:8080/echo"
BODY="hello-phase1b"
REQUESTS=6

cleanup() {
  docker compose -f "$COMPOSE_FILE" down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Building and starting Phase 1b stack..."
docker compose -f "$COMPOSE_FILE" up --build -d

echo "==> Waiting for proxy to accept connections..."
for i in $(seq 1 30); do
  if curl -sf --http2-prior-knowledge -o /dev/null -X POST -d "$BODY" "$PROXY_URL"; then
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "FAIL: proxy never became reachable" >&2
    docker compose -f "$COMPOSE_FILE" logs
    exit 1
  fi
  sleep 1
done

echo "==> Sending $REQUESTS requests through proxy over HTTP/2..."
IDS=""
for i in $(seq 1 "$REQUESTS"); do
  RESPONSE=$(curl -sf --http2-prior-knowledge -X POST -d "$BODY" "$PROXY_URL")
  if [ "$RESPONSE" != "$BODY" ]; then
    echo "FAIL: request $i expected '$BODY', got '$RESPONSE'" >&2
    docker compose -f "$COMPOSE_FILE" logs
    exit 1
  fi

  ID=$(curl -sf --http2-prior-knowledge -o /dev/null -D - -X POST -d "$BODY" "$PROXY_URL" | grep -i '^x-upstream-id:' | tr -d '\r' | awk '{print $2}')
  IDS="$IDS $ID"
done

echo "==> Upstream IDs seen: $IDS"
DISTINCT=$(echo "$IDS" | tr ' ' '\n' | sort -u | grep -c . || true)
if [ "$DISTINCT" -lt 2 ]; then
  echo "FAIL: expected requests to be distributed across multiple upstreams, saw $DISTINCT distinct ID(s)" >&2
  docker compose -f "$COMPOSE_FILE" logs
  exit 1
fi

echo "PASS: echo correctness verified over HTTP/2, requests distributed across $DISTINCT upstreams"
