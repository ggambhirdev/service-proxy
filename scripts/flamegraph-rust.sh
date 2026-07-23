#!/usr/bin/env bash
# Capture a Rust CPU flamegraph via cargo-flamegraph / perf.
#
# Prerequisites (Linux preferred; Mac Docker profiles are approximate):
#   cargo install flamegraph
#   perf (linux-perf / linux-tools) on the host when profiling a host binary
#
# Two modes:
#   1) Host binary (recommended on Linux):
#        CARGO_PROFILE=1 scripts/flamegraph-rust.sh
#      Builds release proxy and runs cargo flamegraph with PROXY_MODE set.
#   2) Compose + attach (best-effort): brings phase stack up under PROXY_IMPL=rust
#      and prints instructions to `docker top` / `perf` the container PID.
#
# Usage:
#   scripts/flamegraph-rust.sh [phase] [offered_rps]
#   make flamegraph-rust PHASE=2a N=2000
set -euo pipefail

PHASE="${1:-2a}"
N="${2:-2000}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${ROOT}/benchmark-findings/output/flamegraphs/rust"
mkdir -p "${OUT_DIR}"

SVG="${OUT_DIR}/phase${PHASE}_N${N}.svg"

if ! command -v cargo >/dev/null; then
  echo "cargo not found" >&2
  exit 1
fi

if ! cargo flamegraph --help >/dev/null 2>&1; then
  echo "Installing cargo-flamegraph..."
  cargo install flamegraph --locked
fi

COMPOSE="deploy/phase${PHASE}/docker-compose.yml"
case "${PHASE}" in
  0) COMPOSE="deploy/phase0/docker-compose.yml" ;;
  5) COMPOSE="deploy/phase5/docker-compose.yml" ;;
esac

export PROXY_IMPL=rust

echo "=== flamegraph-rust phase=${PHASE} N=${N} ==="
echo
echo "Recommended (Linux host binary):"
echo "  1. Start a Go echo upstream: ECHO_ADDR=:9000 UPSTREAM_ID=a go run ./go/cmd/echo-upstream"
echo "  2. In another terminal, under load from oha, run:"
echo "       PROXY_MODE=pooled UPSTREAM_ADDRS=127.0.0.1:9000 \\"
echo "         cargo flamegraph -p service-proxy --release -o ${SVG}"
echo
echo "Docker compose path (bring stack up; attach perf yourself):"
PROXY_IMPL=rust docker compose -f "${ROOT}/${COMPOSE}" up --build -d --wait
echo "  Proxy container id: $(PROXY_IMPL=rust docker compose -f "${ROOT}/${COMPOSE}" ps -q proxy)"
echo "  Start load: oha -z 30s -q ${N} -c 50 --latency-correction http://localhost:8080/echo"
echo "  Then on Linux: sudo perf record -F 99 -p \$(docker inspect -f '{{.State.Pid}}' <container>) -g -- sleep 30"
echo "  Convert with flamegraph.pl or inferno-flamegraph → ${SVG}"
echo
echo "Stack left running for manual capture. Tear down with:"
echo "  PROXY_IMPL=rust docker compose -f ${COMPOSE} down"
echo
echo "(Script does not auto-capture Docker profiles.)"
