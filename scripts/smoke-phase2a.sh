#!/usr/bin/env bash
# Smoke test for Phase 2a: brings up the proxy with pooled upstream
# connections + a worker pool in front of 3 upstreams, verifies echo
# correctness, round-robin distribution, and that a burst of concurrent
# requests completes without deadlock or panic (exercising the pool and
# worker-pool paths).
set -euo pipefail

cd "$(dirname "$0")/.."

COMPOSE_FILE="deploy/phase2a/docker-compose.yml"
PROXY_URL="http://localhost:8080/echo"
BODY="hello-phase2a"
REQUESTS=6
BURST=20

cleanup() {
  docker compose -f "$COMPOSE_FILE" down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Building and starting Phase 2a stack..."
docker compose -f "$COMPOSE_FILE" up --build -d

echo "==> Waiting for proxy to accept connections..."
for i in $(seq 1 30); do
  if curl -sf -o /dev/null -X POST -d "$BODY" "$PROXY_URL"; then
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "FAIL: proxy never became reachable" >&2
    docker compose -f "$COMPOSE_FILE" logs
    exit 1
  fi
  sleep 1
done

echo "==> Sending $REQUESTS sequential requests through proxy..."
IDS=""
for i in $(seq 1 "$REQUESTS"); do
  RESPONSE=$(curl -sf -X POST -d "$BODY" "$PROXY_URL")
  if [ "$RESPONSE" != "$BODY" ]; then
    echo "FAIL: request $i expected '$BODY', got '$RESPONSE'" >&2
    docker compose -f "$COMPOSE_FILE" logs
    exit 1
  fi
  ID=$(curl -sf -o /dev/null -D - -X POST -d "$BODY" "$PROXY_URL" | grep -i '^X-Upstream-Id:' | tr -d '\r' | awk '{print $2}')
  IDS="$IDS $ID"
done

echo "==> Upstream IDs seen: $IDS"
DISTINCT=$(echo "$IDS" | tr ' ' '\n' | sort -u | grep -c . || true)
if [ "$DISTINCT" -lt 2 ]; then
  echo "FAIL: expected requests to be distributed across multiple upstreams, saw $DISTINCT distinct ID(s)" >&2
  docker compose -f "$COMPOSE_FILE" logs
  exit 1
fi

echo "==> Sending $BURST concurrent requests through proxy..."
PIDS=()
for i in $(seq 1 "$BURST"); do
  (
    RESPONSE=$(curl -sf -X POST -d "$BODY" "$PROXY_URL")
    [ "$RESPONSE" = "$BODY" ]
  ) &
  PIDS+=($!)
done

FAIL=0
for pid in "${PIDS[@]}"; do
  wait "$pid" || FAIL=1
done

if [ "$FAIL" -ne 0 ]; then
  echo "FAIL: one or more concurrent requests failed" >&2
  docker compose -f "$COMPOSE_FILE" logs
  exit 1
fi

echo "PASS: echo correctness verified, requests distributed across $DISTINCT upstreams, concurrent burst OK"
