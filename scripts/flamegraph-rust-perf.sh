#!/usr/bin/env bash
# Capture a Rust CPU flamegraph via perf (kernel-inclusive stacks).
#
# 
#
# Two modes:
#   HOST=1 (Linux recommended): release binary on the host + Go echo upstream,
#     then `perf record -p <pid>`.
#   default: compose stack up, then perf-record the proxy container's host PID
#     (needs Linux host with perf/sudo; Mac Docker is approximate).
#
# Prerequisites:
#   - Linux: perf (linux-perf / linux-tools)
#   - oha on PATH; go on PATH for HOST=1 upstream
#   - flamegraph.pl + stackcollapse-perf.pl, or inferno-*-perf / inferno-flamegraph
#
# Usage:
#   scripts/flamegraph-rust-perf.sh [phase] [offered_rps]
#   HOST=1 scripts/flamegraph-rust-perf.sh 1a 500
#   make flamegraph-rust-perf PHASE=1a N=500
#   make flamegraph-rust-perf HOST=1 PHASE=2a N=500
set -euo pipefail

PHASE="${1:-2a}"
N="${2:-2000}"
HOST="${HOST:-0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${ROOT}/benchmark-findings/output/flamegraphs/rust-perf"
mkdir -p "${OUT_DIR}"

SVG="${OUT_DIR}/phase${PHASE}_N${N}.svg"
PERF_DATA="${OUT_DIR}/phase${PHASE}_N${N}.perf"

proxy_mode_for_phase() {
  case "$1" in
    0) echo tcp-sync ;;
    1a) echo tcp-goroutine ;;
    1b) echo http2 ;;
    2a|5) echo pooled ;;
    2b) echo grpc ;;
    3a) echo quic ;;
    3b) echo http3 ;;
    *) echo pooled ;;
  esac
}

fold_perf_to_svg() {
  local data="$1"
  local out="$2"
  # perf script needs to read /proc/kallsyms to resolve kernel-side frames;
  # kernel.kptr_restrict hides real addresses from non-root on most distros,
  # so run just this step (not the folding/rendering after it) via sudo.
  # sudo's PATH won't have inferno/flamegraph.pl (installed under the
  # invoking user's home), which is exactly why only `perf script` is
  # elevated here and the rest of the pipe stays as the normal user.
  if command -v inferno-collapse-perf >/dev/null && command -v inferno-flamegraph >/dev/null; then
    sudo perf script -i "${data}" | inferno-collapse-perf | inferno-flamegraph > "${out}"
  elif command -v stackcollapse-perf.pl >/dev/null && command -v flamegraph.pl >/dev/null; then
    sudo perf script -i "${data}" | stackcollapse-perf.pl | flamegraph.pl > "${out}"
  else
    echo "Install FlameGraph (stackcollapse-perf.pl + flamegraph.pl) or inferno to convert ${data}" >&2
    sudo perf script -i "${data}" > "${data}.script.txt"
    echo "Wrote ${data} and ${data}.script.txt"
    return 1
  fi
}

run_load() {
  local mode="$1"
  local target_host="$2"
  case "${mode}" in
    http2)
      oha -z 40s -q "${N}" -c 1 -p 50 --latency-correction --http2 \
        "http://${target_host}:8080/echo" >/dev/null 2>&1 || true
      ;;
    grpc)
      ghz -z 40s -r "${N}" -c 50 --connections=1 --async --insecure \
        --data '{"payload": ""}' \
        --proto "${ROOT}/proto/echo.proto" \
        --call echo.EchoService.Echo \
        "${target_host}:8080" >/dev/null 2>&1 || true
      ;;
    quic)
      (cd "${ROOT}/go" && go run ./cmd/quic-bench-client \
        -addr "${target_host}:8443" -rate "${N}" -duration 40s) >/dev/null 2>&1 || true
      ;;
    http3)
      oha-http3 -z 40s -q "${N}" -c 50 --latency-correction --http3 \
        "https://${target_host}:8443/echo" >/dev/null 2>&1 || \
        oha -z 40s -q "${N}" -c 50 --latency-correction --http3 \
          "https://${target_host}:8443/echo" >/dev/null 2>&1 || true
      ;;
    *)
      oha -z 40s -q "${N}" -c 50 --latency-correction \
        "http://${target_host}:8080/echo" >/dev/null 2>&1 || \
        oha -z 40s -q "${N}" -c 50 --latency-correction \
          "http://${target_host}:8080" >/dev/null 2>&1 || true
      ;;
  esac
}

record_perf() {
  local pid="$1"
  local data="$2"
  local cmd=(perf record -F 99 -p "${pid}" -g --call-graph dwarf -o "${data}" -- sleep 30)
  if [[ "$(id -u)" -eq 0 ]]; then
    "${cmd[@]}"
  else
    # Leave ${data} owned by root (whatever sudo perf record produces).
    # fold_perf_to_svg below reads it via `sudo perf script`, and perf
    # itself refuses to read a perf.data file unless it's owned by root or
    # by the user invoking it (a safety check against a tampered file being
    # read with elevated privileges) — so root reading a root-owned file is
    # exactly what it wants. Only `perf script`'s piped stdout goes to the
    # unprivileged inferno/flamegraph.pl step; the file itself is never
    # touched by anything other than root.
    sudo "${cmd[@]}" || "${cmd[@]}"
  fi
}

COMPOSE="deploy/phase${PHASE}/docker-compose.yml"
case "${PHASE}" in
  0) COMPOSE="deploy/phase0/docker-compose.yml" ;;
  5) COMPOSE="deploy/phase5/docker-compose.yml" ;;
esac

MODE="$(proxy_mode_for_phase "${PHASE}")"

echo "=== flamegraph-rust-perf phase=${PHASE} N=${N} HOST=${HOST} mode=${MODE} ==="

if ! command -v perf >/dev/null; then
  echo "perf not found on PATH. Install linux-perf / linux-tools on Linux." >&2
  echo "(Mac hosts: run this script on a Linux bench box, or use flamegraph-rust-pprof.sh.)" >&2
  exit 1
fi

if [[ "${HOST}" == "1" ]]; then
  if ! command -v cargo >/dev/null; then
    echo "cargo not found" >&2
    exit 1
  fi

  echo "Building release service-proxy..."
  (cd "${ROOT}" && cargo build --release -p service-proxy)

  LISTEN=":8080"
  case "${MODE}" in
    quic|http3) LISTEN=":8443" ;;
  esac

  (cd "${ROOT}/go" && ECHO_ADDR=:9000 UPSTREAM_ID=a go run ./cmd/echo-upstream) &
  ECHO_PID=$!

  echo "Waiting for upstream :9000..."
  for i in $(seq 1 60); do
    if (exec 3<>/dev/tcp/127.0.0.1/9000) 2>/dev/null; then
      exec 3<&- 3>&- 2>/dev/null || true
      echo "Upstream is up after ${i}s"
      break
    fi
    if [[ "${i}" -eq 60 ]]; then
      echo "Upstream never came up on :9000 after 60s. Aborting." >&2
      exit 1
    fi
    sleep 1
  done

  PROXY_MODE="${MODE}" UPSTREAM_ADDRS=127.0.0.1:9000 LISTEN_ADDR="${LISTEN}" \
    "${ROOT}/target/release/service-proxy" &
  PROXY_PID=$!

  cleanup_host() {
    kill "${PROXY_PID}" "${ECHO_PID}" >/dev/null 2>&1 || true
    wait "${PROXY_PID}" 2>/dev/null || true
    wait "${ECHO_PID}" 2>/dev/null || true
    # `go run` execs a child binary that doesn't inherit signals sent to the
    # wrapper PID above (SIGKILL especially can't be forwarded at all), so it
    # can survive and keep holding :9000. Belt-and-suspenders: kill anything
    # still matching the actual binary/port directly.
    pkill -9 -f 'cmd/echo-upstream' >/dev/null 2>&1 || true
    fuser -k 9000/tcp >/dev/null 2>&1 || true
  }
  trap cleanup_host EXIT
  sleep 1

  run_load "${MODE}" "127.0.0.1" &
  LOAD_PID=$!
  sleep 2
  record_perf "${PROXY_PID}" "${PERF_DATA}"
  wait "${LOAD_PID}" || true

  fold_perf_to_svg "${PERF_DATA}" "${SVG}" || exit 0
  echo "Wrote ${PERF_DATA}"
  echo "Wrote ${SVG}"
  exit 0
fi

# --- Docker compose + host perf attach ---
export PROXY_IMPL=rust

cleanup() {
  PROXY_IMPL=rust docker compose -f "${ROOT}/${COMPOSE}" down >/dev/null 2>&1 || true
}
trap cleanup EXIT

PROXY_IMPL=rust docker compose -f "${ROOT}/${COMPOSE}" up --build -d --wait
CID="$(PROXY_IMPL=rust docker compose -f "${ROOT}/${COMPOSE}" ps -q proxy)"
PID="$(docker inspect -f '{{.State.Pid}}' "${CID}")"
echo "Proxy container=${CID} host_pid=${PID}"

run_load "${MODE}" "localhost" &
LOAD_PID=$!
sleep 2
record_perf "${PID}" "${PERF_DATA}"
wait "${LOAD_PID}" || true

fold_perf_to_svg "${PERF_DATA}" "${SVG}" || exit 0
echo "Wrote ${PERF_DATA}"
echo "Wrote ${SVG}"
