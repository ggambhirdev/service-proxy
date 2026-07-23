#!/usr/bin/env bash
# Capture a Rust CPU profile via pprof-rs (userspace SIGPROF) and write SVG.
#
# 
#
# Prerequisites:
#   - Docker stack with PPROF_ADDR=:6060 published (override appended here)
#   - oha on PATH
#   - optional: go on PATH to also render via `go tool pprof`
#
# Usage:
#   scripts/flamegraph-rust-pprof.sh [phase] [offered_rps]
#   make flamegraph-rust-pprof PHASE=1a N=500
set -euo pipefail

PHASE="${1:-2a}"
N="${2:-2000}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${ROOT}/benchmark-findings/output/flamegraphs/rust-pprof"
mkdir -p "${OUT_DIR}"

COMPOSE="deploy/phase${PHASE}/docker-compose.yml"
case "${PHASE}" in
  0) COMPOSE="deploy/phase0/docker-compose.yml" ;;
  5) COMPOSE="deploy/phase5/docker-compose.yml" ;;
esac

export PROXY_IMPL=rust

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
  PROXY_IMPL=rust docker compose -f "${ROOT}/${COMPOSE}" -f "${OVERRIDE}" down >/dev/null 2>&1 || true
  rm -f "${OVERRIDE}"
}
trap cleanup EXIT

echo "=== flamegraph-rust-pprof phase=${PHASE} N=${N} ==="
PROXY_IMPL=rust docker compose -f "${ROOT}/${COMPOSE}" -f "${OVERRIDE}" up --build -d --wait

# Warm briefly, then sustained load while we sample.
oha -z 5s -q "${N}" -c 50 --latency-correction "http://localhost:8080/echo" >/dev/null 2>&1 || \
  oha -z 5s -q "${N}" -c 50 --latency-correction "http://localhost:8080" >/dev/null

PROFILE="${OUT_DIR}/phase${PHASE}_N${N}.pb"
SVG="${OUT_DIR}/phase${PHASE}_N${N}.svg"

(
  oha -z 40s -q "${N}" -c 50 --latency-correction "http://localhost:8080/echo" >/dev/null 2>&1 || \
    oha -z 40s -q "${N}" -c 50 --latency-correction "http://localhost:8080" >/dev/null
) &
LOAD_PID=$!
sleep 2

# One 30s userspace sample → protobuf (same artifact class as flamegraph-go.sh).
HTTP_CODE="$(curl -sS --max-time 90 -o "${PROFILE}" -w '%{http_code}' \
  "http://localhost:6060/debug/pprof/profile?seconds=30")"

wait "${LOAD_PID}" || true

if [[ "${HTTP_CODE}" != "200" ]] || [[ ! -s "${PROFILE}" ]]; then
  echo "pprof profile failed (HTTP ${HTTP_CODE}). Body:" >&2
  head -c 500 "${PROFILE}" >&2 || true
  echo >&2
  exit 1
fi

if command -v go >/dev/null; then
  go tool pprof -svg -output "${SVG}" "${PROFILE}" \
    || go tool pprof -png -output "${SVG%.svg}.png" "${PROFILE}" \
    || true
fi

# Fallback if go tool pprof is missing: native SVG (second sample window).
if [[ ! -s "${SVG}" ]] && [[ ! -s "${SVG%.svg}.png" ]]; then
  echo "go tool pprof unavailable or failed; sampling again for native SVG..."
  (
    oha -z 40s -q "${N}" -c 50 --latency-correction "http://localhost:8080/echo" >/dev/null 2>&1 || \
      oha -z 40s -q "${N}" -c 50 --latency-correction "http://localhost:8080" >/dev/null
  ) &
  LOAD_PID=$!
  sleep 2
  HTTP_CODE="$(curl -sS --max-time 90 -o "${SVG}" -w '%{http_code}' \
    "http://localhost:6060/debug/pprof/flamegraph?seconds=30")"
  wait "${LOAD_PID}" || true
  if [[ "${HTTP_CODE}" != "200" ]] || [[ ! -s "${SVG}" ]]; then
    echo "native flamegraph failed (HTTP ${HTTP_CODE})" >&2
    head -c 500 "${SVG}" >&2 || true
    echo >&2
    exit 1
  fi
fi

echo "Wrote ${PROFILE}"
echo "Wrote ${SVG} (or .png). Open with: go tool pprof -http=:8081 ${PROFILE}"
