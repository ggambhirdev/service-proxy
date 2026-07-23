#!/usr/bin/env bash
# Capture a Rust *off-CPU* time flamegraph: how long each stack spends
# blocked/sleeping (I/O, locks, involuntary context switches, parking) rather
# than executing.
#
#
# Two capture methods, tried in this order:
#   1. bcc's offcputime (eBPF) — preferred. Purpose-built for this: exact
#      per-stack off-CPU durations aggregated in-kernel (no sampling error),
#      `-f` emits folded-stack output flamegraph.pl/inferno read directly.
#      https://www.brendangregg.com/blog/2016-01-20/ebpf-offcpu-flame-graph.html
#   2. `perf sched record` (sched:sched_stat_sleep + sched:sched_switch +
#      sched:sched_process_exit tracepoints) + `perf inject -s` + a small awk
#      reshape + stackcollapse.pl — fallback for boxes without bcc-tools.
#      Recipe: https://www.brendangregg.com/blog/2015-02-26/linux-perf-off-cpu-flame-graph.html
#      Needs CONFIG_SCHEDSTATS; on kernels >= 4.5 also:
#        echo 1 | sudo tee /proc/sys/kernel/sched_schedstats
#
# Both methods need root (kernel tracepoints / eBPF), so this script runs its
# capture step under sudo, same as flamegraph-rust-perf.sh.
#
# Two run modes, same convention as flamegraph-rust-perf.sh:
#   HOST=1 (Linux recommended): release binary on the host + Go echo upstream,
#     then profile that PID directly.
#   default: compose stack up, profile the proxy container's host PID (Mac
#     Docker doesn't have real eBPF/perf visibility into the VM — Linux only).
#
# Prerequisites:
#   - Linux with root/sudo
#   - Method 1: bpfcc-tools / bcc-tools package (offcputime-bpfcc or offcputime
#     on PATH)
#   - Method 2: perf (linux-perf / linux-tools) + FlameGraph's stackcollapse.pl
#     (https://github.com/brendangregg/FlameGraph)
#   - oha on PATH; go on PATH for HOST=1 upstream
#   - flamegraph.pl or inferno-flamegraph to render the SVG
#
# Usage:
#   scripts/flamegraph-rust-offcpu.sh [phase] [offered_rps] [duration_s]
#   HOST=1 scripts/flamegraph-rust-offcpu.sh 1a 500
#   make flamegraph-rust-offcpu PHASE=1a N=500
#   make flamegraph-rust-offcpu HOST=1 PHASE=1a N=500
#   make flamegraph-rust-offcpu HOST=1 PHASE=1a N=1000   # comparison point
set -euo pipefail

PHASE="${1:-2a}"
N="${2:-2000}"
DURATION="${3:-30}"
HOST="${HOST:-0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${ROOT}/benchmark-findings/output/flamegraphs/rust-offcpu"
mkdir -p "${OUT_DIR}"

SVG="${OUT_DIR}/phase${PHASE}_N${N}.svg"
RAW_PREFIX="${OUT_DIR}/phase${PHASE}_N${N}"

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

# Same load-generation matrix as flamegraph-rust-perf.sh — kept identical so
# on-CPU and off-CPU captures at the same phase/N are directly comparable.
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

find_offcputime_bin() {
  for candidate in offcputime-bpfcc offcputime /usr/share/bcc/tools/offcputime /usr/sbin/offcputime-bpfcc; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}

render_folded_svg() {
  local folded="$1"
  local out="$2"
  local countname="$3"
  local title="$4"
  if command -v flamegraph.pl >/dev/null 2>&1; then
    flamegraph.pl --countname="${countname}" --title="${title}" --colors=io \
      "${folded}" > "${out}"
  elif command -v inferno-flamegraph >/dev/null 2>&1; then
    inferno-flamegraph --countname "${countname}" --title "${title}" --colors io \
      "${folded}" > "${out}"
  else
    echo "Install FlameGraph's flamegraph.pl or inferno-flamegraph to render ${folded}" >&2
    echo "Wrote folded stacks: ${folded}"
    return 1
  fi
}

# Method 1: bcc offcputime (eBPF). Aggregates off-CPU durations in-kernel by
# stack, in microseconds. -p filters in-kernel to just the proxy PID.
capture_offcpu_bcc() {
  local bin="$1"
  local pid="$2"
  local folded="${RAW_PREFIX}.offcpu.folded"
  echo "Capturing off-CPU stacks via ${bin} (bcc/eBPF) for ${DURATION}s..."
  sudo "${bin}" -f -p "${pid}" "${DURATION}" > "${folded}"
  render_folded_svg "${folded}" "${SVG}" "us" \
    "Off-CPU Time Flame Graph (phase${PHASE} N=${N}, bcc offcputime)"
  echo "Wrote ${folded}"
}

# Method 2: perf sched tracepoints, per Brendan Gregg's documented recipe
# (see header link). -p scopes it to the target PID instead of -a system-wide
# to keep tracepoint overhead down.
capture_offcpu_perf() {
  local pid="$1"
  local raw="${RAW_PREFIX}.offcpu.perf.data.raw"
  local data="${RAW_PREFIX}.offcpu.perf.data"
  local folded="${RAW_PREFIX}.offcpu.folded"

  if ! command -v stackcollapse.pl >/dev/null 2>&1; then
    echo "stackcollapse.pl not found on PATH (from brendangregg/FlameGraph)." >&2
    echo "Install bpfcc-tools for the preferred eBPF path, or put FlameGraph's" >&2
    echo "stackcollapse.pl + flamegraph.pl on PATH for this fallback." >&2
    return 1
  fi

  echo "sched_schedstats must be enabled on kernels >= 4.5:" \
       "echo 1 | sudo tee /proc/sys/kernel/sched_schedstats"
  echo 1 | sudo tee /proc/sys/kernel/sched_schedstats >/dev/null 2>&1 || true

  echo "Capturing off-CPU stacks via perf sched tracepoints for ${DURATION}s..."
  sudo perf record -e sched:sched_stat_sleep -e sched:sched_switch \
    -e sched:sched_process_exit -p "${pid}" -g -o "${raw}" -- sleep "${DURATION}"
  sudo perf inject -v -s -i "${raw}" -o "${data}"
  sudo chmod a+r "${data}"

  # Reshape `perf script` period-annotated output into the exec/frame/blank
  # format stackcollapse.pl expects, exactly per Gregg's documented awk.
  sudo perf script -i "${data}" -F comm,pid,tid,cpu,time,period,event,ip,sym,dso,trace | awk '
      NF > 4 { exec = $1; period_ms = int($5 / 1000000) }
      NF > 1 && NF <= 4 && period_ms > 0 { print $2 }
      NF < 2 && period_ms > 0 { printf "%s\n%d\n\n", exec, period_ms }' \
    > "${RAW_PREFIX}.offcpu.stacks.txt"

  stackcollapse.pl "${RAW_PREFIX}.offcpu.stacks.txt" > "${folded}"
  render_folded_svg "${folded}" "${SVG}" "ms" \
    "Off-CPU Time Flame Graph (phase${PHASE} N=${N}, perf sched)"
  echo "Wrote ${folded}"
}

capture_offcpu() {
  local pid="$1"
  local bcc_bin
  if bcc_bin="$(find_offcputime_bin)"; then
    capture_offcpu_bcc "${bcc_bin}" "${pid}"
  else
    echo "No bcc offcputime found; falling back to perf sched record." >&2
    capture_offcpu_perf "${pid}"
  fi
}

COMPOSE="deploy/phase${PHASE}/docker-compose.yml"
case "${PHASE}" in
  0) COMPOSE="deploy/phase0/docker-compose.yml" ;;
  5) COMPOSE="deploy/phase5/docker-compose.yml" ;;
esac

MODE="$(proxy_mode_for_phase "${PHASE}")"

echo "=== flamegraph-rust-offcpu phase=${PHASE} N=${N} duration=${DURATION}s HOST=${HOST} mode=${MODE} ==="

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "Off-CPU capture needs Linux (eBPF/perf sched tracepoints); this box is $(uname -s)." >&2
  echo "Run this on a Linux bench box — see CLAUDE.md section 12." >&2
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
    pkill -9 -f 'cmd/echo-upstream' >/dev/null 2>&1 || true
    fuser -k 9000/tcp >/dev/null 2>&1 || true
  }
  trap cleanup_host EXIT
  sleep 1

  run_load "${MODE}" "127.0.0.1" &
  LOAD_PID=$!
  sleep 2
  capture_offcpu "${PROXY_PID}"
  wait "${LOAD_PID}" || true

  echo "Wrote ${SVG}"
  exit 0
fi

# --- Docker compose + host PID attach ---
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
capture_offcpu "${PID}"
wait "${LOAD_PID}" || true

echo "Wrote ${SVG}"
