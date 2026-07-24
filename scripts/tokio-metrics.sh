#!/usr/bin/env bash
# Poll the proxy's Tokio runtime metrics (Handle::metrics(), see
# crates/service-proxy/src/tokio_metrics_server.rs) during a load run, and
# summarize per-worker local queue depth / busy fraction / poll & steal
# rates — the layer up from anything OS-level tools (perf, bcc, bpftrace)
# can see. See benchmark-findings/writing/week3.md: on-CPU cost, off-CPU
# blocked time, and OS scheduling latency all ruled themselves out as the
# cause of phase 1a's N=500 spike; this checks whether tasks are actually
# piling up in Tokio's own per-worker run queues instead.
#
# Portable, unlike the eBPF/perf tools: Handle::metrics() is pure userspace
# Tokio API, no kernel dependency at all. Runs natively on macOS or Linux —
# no Docker, no Linux bench box required. HOST-native only (no docker
# compose mode): the container image's Dockerfile doesn't currently pass
# RUSTFLAGS=--cfg tokio_unstable through the build, so this always builds
# and runs the release binary directly on this machine.
#
# Prerequisites:
#   - cargo/rustc on PATH
#   - oha on PATH; go on PATH (for the Go echo upstream)
#   - curl, python3 on PATH
#
# Usage:
#   scripts/tokio-metrics.sh [phase] [offered_rps] [duration_s] [poll_interval_s]
#   scripts/tokio-metrics.sh 1a 500
#   make tokio-metrics PHASE=1a N=500
#   make tokio-metrics PHASE=1a N=1000   # comparison point
set -euo pipefail

PHASE="${1:-2a}"
N="${2:-2000}"
DURATION="${3:-30}"
POLL_INTERVAL="${4:-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${ROOT}/benchmark-findings/output/tokio-metrics"
mkdir -p "${OUT_DIR}"

RAW="${OUT_DIR}/phase${PHASE}_N${N}.tokio-metrics.jsonl"
SUMMARY="${OUT_DIR}/phase${PHASE}_N${N}.tokio-metrics.summary.txt"
METRICS_ADDR="127.0.0.1:6670"

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

# Same load-generation matrix as the other rust-perf/-offcpu/runqlat
# scripts — kept identical so captures at the same phase/N are comparable.
run_load() {
  local mode="$1"
  local target_host="$2"
  case "${mode}" in
    http2)
      oha -z "${DURATION}s" -q "${N}" -c 1 -p 50 --latency-correction --http2 \
        "http://${target_host}:8080/echo" >/dev/null 2>&1 || true
      ;;
    grpc)
      ghz -z "${DURATION}s" -r "${N}" -c 50 --connections=1 --async --insecure \
        --data '{"payload": ""}' \
        --proto "${ROOT}/proto/echo.proto" \
        --call echo.EchoService.Echo \
        "${target_host}:8080" >/dev/null 2>&1 || true
      ;;
    quic)
      (cd "${ROOT}/go" && go run ./cmd/quic-bench-client \
        -addr "${target_host}:8443" -rate "${N}" -duration "${DURATION}s") >/dev/null 2>&1 || true
      ;;
    http3)
      oha-http3 -z "${DURATION}s" -q "${N}" -c 50 --latency-correction --http3 \
        "https://${target_host}:8443/echo" >/dev/null 2>&1 || \
        oha -z "${DURATION}s" -q "${N}" -c 50 --latency-correction --http3 \
          "https://${target_host}:8443/echo" >/dev/null 2>&1 || true
      ;;
    *)
      oha -z "${DURATION}s" -q "${N}" -c 50 --latency-correction \
        "http://${target_host}:8080/echo" >/dev/null 2>&1 || \
        oha -z "${DURATION}s" -q "${N}" -c 50 --latency-correction \
          "http://${target_host}:8080" >/dev/null 2>&1 || true
      ;;
  esac
}

poll_metrics() {
  : > "${RAW}"
  local end=$(( $(date +%s) + DURATION ))
  while [[ "$(date +%s)" -lt "${end}" ]]; do
    curl -sS --max-time 2 "http://${METRICS_ADDR}/tokio-metrics" >> "${RAW}" 2>/dev/null || true
    printf '\n' >> "${RAW}"
    sleep "${POLL_INTERVAL}"
  done
}

# Turns the newline-delimited JSON snapshots into: per-worker local queue
# depth distribution (a gauge, not cumulative — reported directly, not
# delta'd), and per-worker busy fraction / poll rate / steal rate (all
# cumulative counters — delta'd between first and last snapshot, matching
# the "% busy" methodology already used for Go's p2c N=4000 finding in
# week3.md, so the two are directly comparable).
summarize() {
  python3 - "${RAW}" "${SUMMARY}" <<'PYEOF'
import json, sys

raw_path, summary_path = sys.argv[1], sys.argv[2]
snapshots = []
for line in open(raw_path):
    line = line.strip()
    if not line:
        continue
    try:
        snapshots.append(json.loads(line))
    except json.JSONDecodeError:
        continue

lines = []
if len(snapshots) < 2:
    lines.append(f"Only {len(snapshots)} usable snapshot(s) captured — need at least 2 for rates.")
    lines.append("Check that the proxy was built with --cfg tokio_unstable and")
    lines.append("TOKIO_METRICS_ADDR was set (see the raw .jsonl for curl error text).")
    open(summary_path, "w").write("\n".join(lines) + "\n")
    print("\n".join(lines))
    sys.exit(0)

first, last = snapshots[0], snapshots[-1]
wall_ms = last["timestamp_ms"] - first["timestamp_ms"]
wall_s = wall_ms / 1000.0 if wall_ms > 0 else 1.0

lines.append(f"Snapshots: {len(snapshots)} over {wall_s:.1f}s wall time")
lines.append(f"num_workers: {last['num_workers']}")
lines.append("")

gqd = [s["global_queue_depth"] for s in snapshots]
nat = [s["num_alive_tasks"] for s in snapshots]
lines.append(f"global_queue_depth: max={max(gqd)} avg={sum(gqd)/len(gqd):.2f}")
lines.append(f"num_alive_tasks: max={max(nat)} avg={sum(nat)/len(nat):.2f}")
lines.append(
    f"remote_schedule_count: +{last['remote_schedule_count'] - first['remote_schedule_count']}"
)
lines.append(
    f"budget_forced_yield_count: +{last['budget_forced_yield_count'] - first['budget_forced_yield_count']}"
)
lines.append("")

n_workers = last["num_workers"]
for i in range(n_workers):
    w_first = next(w for w in first["workers"] if w["worker"] == i)
    w_last = next(w for w in last["workers"] if w["worker"] == i)
    lqd_series = [
        next(w["local_queue_depth"] for w in s["workers"] if w["worker"] == i)
        for s in snapshots
    ]
    busy_delta_us = w_last["total_busy_duration_us"] - w_first["total_busy_duration_us"]
    busy_pct = (busy_delta_us / 1000.0) / wall_ms * 100 if wall_ms > 0 else 0.0
    poll_delta = w_last["poll_count"] - w_first["poll_count"]
    park_delta = w_last["park_count"] - w_first["park_count"]
    steal_delta = w_last["steal_count"] - w_first["steal_count"]
    overflow_delta = w_last["overflow_count"] - w_first["overflow_count"]

    lines.append(f"worker {i}:")
    lines.append(
        f"  local_queue_depth: max={max(lqd_series)} avg={sum(lqd_series)/len(lqd_series):.2f}"
    )
    lines.append(f"  busy: {busy_pct:.2f}% of wall time")
    lines.append(f"  poll_count: +{poll_delta} ({poll_delta/wall_s:.1f}/s)")
    lines.append(f"  park_count: +{park_delta} ({park_delta/wall_s:.1f}/s)")
    lines.append(f"  steal_count: +{steal_delta}")
    lines.append(f"  overflow_count: +{overflow_delta}")

out = "\n".join(lines) + "\n"
open(summary_path, "w").write(out)
print(out, end="")
PYEOF
}

MODE="$(proxy_mode_for_phase "${PHASE}")"
echo "=== tokio-metrics phase=${PHASE} N=${N} duration=${DURATION}s mode=${MODE} ==="

if ! command -v cargo >/dev/null; then
  echo "cargo not found" >&2
  exit 1
fi

echo "Building release service-proxy with --cfg tokio_unstable..."
(cd "${ROOT}" && RUSTFLAGS="--cfg tokio_unstable" cargo build --release -p service-proxy)

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
  TOKIO_METRICS_ADDR=":6670" \
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

echo "Waiting for tokio-metrics endpoint on ${METRICS_ADDR}..."
for i in $(seq 1 30); do
  if curl -sS --max-time 1 "http://${METRICS_ADDR}/tokio-metrics" >/dev/null 2>&1; then
    break
  fi
  if [[ "${i}" -eq 30 ]]; then
    echo "tokio-metrics endpoint never came up. Was the binary built with" >&2
    echo "--cfg tokio_unstable? Check the build output above." >&2
    exit 1
  fi
  sleep 1
done

run_load "${MODE}" "127.0.0.1" &
LOAD_PID=$!
sleep 1
poll_metrics
wait "${LOAD_PID}" || true

echo "Wrote ${RAW}"
summarize
echo "Wrote ${SUMMARY}"
