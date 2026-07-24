#!/usr/bin/env bash
# Histogram the proxy's *scheduling* (run-queue) latency: the time a thread
# spends runnable-but-waiting for a turn on a core, between being woken and
# actually executing.
#
# Why this exists: neither of the other two flamegraph paths can see this.
# `flamegraph-rust-perf.sh` only samples while a thread is on-CPU, so it
# found phase 1a's N=500 spike correlates with far more `park_internal`
# on-CPU time — but converting that to an absolute number (see
# benchmark-findings/writing/week3.md) showed it amortizes to ~655ns/request,
# about 70,000x too small to be the actual 46ms p99.9 gap.
# `flamegraph-rust-offcpu.sh` measures total time blocked/asleep, but that's
# dominated by legitimate idle time at low load and, empirically, isn't
# elevated at N=500 either. The remaining candidate is the gap in between:
# a worker gets woken (it's runnable) but has to wait its turn for a core.
# That's exactly what `runqlat` measures, directly, in time units — no
# amortization or unit-conversion guesswork required to get a real "X ms"
# figure.
#
# Method: bcc's runqlat (eBPF), PID-scoped. No perf-based fallback is
# implemented here — there's no single-command equivalent; `perf sched
# latency` after a `perf sched record` gives per-thread avg/max scheduling
# delay stats but not a full histogram, so if bcc isn't available, use that
# manually: `perf sched record -p <pid> -- sleep <duration>` then
# `perf sched latency -i perf.data`.
#
# Two run modes, same convention as flamegraph-rust-perf.sh /
# flamegraph-rust-offcpu.sh:
#   HOST=1 (Linux recommended): release binary on the host + Go echo upstream.
#   default: compose stack up, profile the proxy container's host PID.
#
# Prerequisites:
#   - Linux with root/sudo
#   - bpfcc-tools / bcc-tools package (runqlat-bpfcc or runqlat on PATH)
#   - oha on PATH; go on PATH for HOST=1 upstream; python3 on PATH (used to
#     turn the raw log2 histogram into estimated percentiles)
#
# Usage:
#   scripts/runqlat-rust.sh [phase] [offered_rps] [duration_s]
#   HOST=1 scripts/runqlat-rust.sh 1a 500
#   make runqlat-rust PHASE=1a N=500
#   make runqlat-rust HOST=1 PHASE=1a N=500
#   make runqlat-rust HOST=1 PHASE=1a N=1000   # comparison point
#
# THREADS=1 env var adds runqlat's -L flag (per-thread-ID breakdown) instead
# of one process-wide histogram — useful for isolating tokio-rt-worker
# threads specifically, at the cost of one histogram per thread to read.
set -euo pipefail

PHASE="${1:-2a}"
N="${2:-2000}"
DURATION="${3:-30}"
HOST="${HOST:-0}"
THREADS="${THREADS:-0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${ROOT}/benchmark-findings/output/runqlat"
mkdir -p "${OUT_DIR}"

RAW="${OUT_DIR}/phase${PHASE}_N${N}.runqlat.txt"
SUMMARY="${OUT_DIR}/phase${PHASE}_N${N}.runqlat.summary.txt"

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

# Same load-generation matrix as flamegraph-rust-perf.sh / -offcpu.sh — kept
# identical so captures at the same phase/N are directly comparable.
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

find_runqlat_bin() {
  for candidate in runqlat-bpfcc runqlat /usr/share/bcc/tools/runqlat /usr/sbin/runqlat-bpfcc; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}

# Parse bcc's log2 histogram text output into estimated percentiles. Each
# bucket's *upper* bound is used as that bucket's representative value —
# a deliberately pessimistic (upper-bound) estimate, not the true value,
# since the histogram doesn't retain individual samples. Handles the plain
# (no -L/-P) single-histogram case; with THREADS=1 this summarizes each
# per-TID block separately and also emits a merged process-wide total.
summarize_histogram() {
  local raw="$1"
  local summary="$2"
  python3 - "${raw}" "${summary}" <<'PYEOF'
import re, sys

raw_path, summary_path = sys.argv[1], sys.argv[2]
text = open(raw_path).read()

bucket_re = re.compile(
    r'^\s*(\d+)\s*->\s*(\d+)\s*:\s*(\d+)\s*\|', re.MULTILINE
)
header_re = re.compile(r'^\s*(usecs|msecs)\s*:', re.MULTILINE)
tid_re = re.compile(r'^(pid|tid)\s*=\s*(\d+)', re.MULTILINE)

unit = "usecs"
m = header_re.search(text)
if m:
    unit = m.group(1)

buckets = [(int(a), int(b), int(c)) for a, b, c in bucket_re.findall(text)]

def percentiles(buckets):
    total = sum(c for _, _, c in buckets)
    if total == 0:
        return None
    cum = 0
    out = {}
    targets = [50, 90, 99, 99.9]
    ti = 0
    for lo, hi, c in buckets:
        cum += c
        while ti < len(targets) and cum / total * 100 >= targets[ti]:
            out[targets[ti]] = hi
            ti += 1
    out["max"] = max(hi for lo, hi, c in buckets if c > 0) if any(c > 0 for _, _, c in buckets) else 0
    out["n"] = total
    return out

lines = []
lines.append(f"Unit: {unit} (bcc runqlat; values are upper-bound estimates per log2 bucket)")
p = percentiles(buckets)
if p is None:
    lines.append("No scheduling events captured (empty histogram).")
else:
    lines.append(f"Samples: {p['n']}")
    for k in (50, 90, 99, 99.9):
        lines.append(f"p{k}: <= {p[k]} {unit}")
    lines.append(f"max observed bucket: <= {p['max']} {unit}")

out = "\n".join(lines) + "\n"
open(summary_path, "w").write(out)
print(out, end="")
PYEOF
}

COMPOSE="deploy/phase${PHASE}/docker-compose.yml"
case "${PHASE}" in
  0) COMPOSE="deploy/phase0/docker-compose.yml" ;;
  5) COMPOSE="deploy/phase5/docker-compose.yml" ;;
esac

MODE="$(proxy_mode_for_phase "${PHASE}")"

echo "=== runqlat-rust phase=${PHASE} N=${N} duration=${DURATION}s HOST=${HOST} mode=${MODE} ==="

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "runqlat needs Linux (eBPF scheduler tracepoints); this box is $(uname -s)." >&2
  echo "Run this on a Linux bench box — see CLAUDE.md section 12." >&2
  exit 1
fi

RUNQLAT_BIN="$(find_runqlat_bin)" || {
  echo "No bcc runqlat found (looked for runqlat-bpfcc / runqlat)." >&2
  echo "Install bpfcc-tools / bcc-tools, or fall back to manual" >&2
  echo "'perf sched record -p PID -- sleep N' + 'perf sched latency -i perf.data'." >&2
  exit 1
}

capture_runqlat() {
  local pid="$1"
  local flags=(-p "${pid}")
  if [[ "${THREADS}" == "1" ]]; then
    flags+=(-L)
  fi
  echo "Capturing run-queue latency via ${RUNQLAT_BIN} for ${DURATION}s..."
  # `tee` instead of a plain `>` redirect: runqlat-bpfcc writes its status
  # line, histogram, and any error text all to stdout (not stderr), so a
  # bare redirect swallows failures silently into ${RAW} with nothing shown
  # on screen. `2>&1 | tee` surfaces everything live while still capturing
  # it; `set -o pipefail` (from `set -euo pipefail` above) makes a failing
  # runqlat still fail the pipeline even though `tee` itself exits 0.
  sudo "${RUNQLAT_BIN}" "${flags[@]}" "${DURATION}" 1 2>&1 | tee "${RAW}"
  echo "Wrote ${RAW}"
  summarize_histogram "${RAW}" "${SUMMARY}"
  echo "Wrote ${SUMMARY}"
}

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
  capture_runqlat "${PROXY_PID}"
  wait "${LOAD_PID}" || true

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
capture_runqlat "${PID}"
wait "${LOAD_PID}" || true
