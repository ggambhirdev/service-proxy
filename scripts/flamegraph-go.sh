#!/usr/bin/env bash
# Capture a Go CPU profile via pprof and write an SVG flamegraph.
#
# Prerequisites:
#   - stack running with PPROF_ADDR=:6060 published (see script body)
#   - go on PATH
#   - optional: Brendan Gregg's flamegraph.pl for SVG (falls back to
#     `go tool pprof -svg` if flamegraph.pl is absent)
#
# Usage:
#   scripts/flamegraph-go.sh [phase] [offered_rps]
#   make flamegraph-go PHASE=2a N=2000
#
# This script brings the phase up, runs oha load, captures a 30s CPU profile,
# then tears the stack down. Prefer running the profile capture steps by hand
# if you already have a steady-state load going.
set -euo pipefail

PHASE="${1:-2a}"
N="${2:-2000}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${ROOT}/benchmark-findings/output/flamegraphs/go"
mkdir -p "${OUT_DIR}"

COMPOSE="deploy/phase${PHASE}/docker-compose.yml"
case "${PHASE}" in
  0) COMPOSE="deploy/phase0/docker-compose.yml" ;;
  5) COMPOSE="deploy/phase5/docker-compose.yml" ;;
esac

export PROXY_IMPL=go
export PPROF_ADDR=:6060

# Patch: ensure pprof port is published for this run by appending an override.
OVERRIDE="${ROOT}/.flamegraph-compose.override.yml"
cat > "${OVERRIDE}" <<'EOF'
services:
  proxy:
    environment:
      - PPROF_ADDR=:6060
    ports:
      - "6060:6060"
EOF

cleanup() {
  PROXY_IMPL=go docker compose -f "${ROOT}/${COMPOSE}" -f "${OVERRIDE}" down >/dev/null 2>&1 || true
  rm -f "${OVERRIDE}"
}
trap cleanup EXIT

echo "=== flamegraph-go phase=${PHASE} N=${N} ==="
PROXY_IMPL=go docker compose -f "${ROOT}/${COMPOSE}" -f "${OVERRIDE}" up --build -d --wait

# Warm briefly, then sustained load while we sample.
oha -z 5s -q "${N}" -c 50 --latency-correction "http://localhost:8080/echo" >/dev/null 2>&1 || \
  oha -z 5s -q "${N}" -c 50 --latency-correction "http://localhost:8080" >/dev/null

PROFILE="${OUT_DIR}/phase${PHASE}_N${N}.pb.gz"
SVG="${OUT_DIR}/phase${PHASE}_N${N}.svg"

(
  oha -z 40s -q "${N}" -c 50 --latency-correction "http://localhost:8080/echo" >/dev/null 2>&1 || \
    oha -z 40s -q "${N}" -c 50 --latency-correction "http://localhost:8080" >/dev/null
) &
LOAD_PID=$!
sleep 2
curl -sS --max-time 60 -o "${PROFILE}" "http://localhost:6060/debug/pprof/profile?seconds=30"
wait "${LOAD_PID}" || true

if command -v go >/dev/null; then
  go tool pprof -svg -output "${SVG}" "${PROFILE}" || go tool pprof -png -output "${SVG%.svg}.png" "${PROFILE}" || true
fi

echo "Wrote ${PROFILE}"
echo "Wrote ${SVG} (or .png). Open with: go tool pprof -http=:8081 ${PROFILE}"
