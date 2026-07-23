#!/usr/bin/env bash
# Smoke test for Phase 0: brings up the proxy + a single upstream echo
# server, sends a known request through the proxy, and asserts the body
# round-trips unchanged.
set -euo pipefail

cd "$(dirname "$0")/.."

COMPOSE_FILE="deploy/phase0/docker-compose.yml"
PROXY_URL="http://localhost:8080/echo"
BODY="hello-phase0"

cleanup() {
  docker compose -f "$COMPOSE_FILE" down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Building and starting Phase 0 stack..."
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

echo "==> Sending request through proxy..."
RESPONSE=$(curl -sf -X POST -d "$BODY" "$PROXY_URL")

if [ "$RESPONSE" != "$BODY" ]; then
  echo "FAIL: expected '$BODY', got '$RESPONSE'" >&2
  docker compose -f "$COMPOSE_FILE" logs
  exit 1
fi

echo "PASS: echoed '$RESPONSE'"
