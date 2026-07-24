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
# Method: three-way cascade, each one tried only if the previous is missing
# or fails at runtime:
#
#   1. bcc's runqlat (eBPF), PID-scoped, preferred — full log2 histogram,
#      converted to estimated percentiles below.
#   2. bpftrace, comm-name-scoped — also a full log2 histogram. Added
#      specifically because of a real failure mode: bcc's runqlat compiles
#      its BPF program against the running kernel's actual headers at trace
#      time, and on a kernel newer than the installed bcc/bpfcc-tools
#      release supports, that compile can fail outright — e.g. a
#      `static_assert` on `struct filename` size or missing
#      `struct ns_common` fields from a recent kernel namespace refactor,
#      both observed against a very new kernel here. bpftrace instead uses
#      BTF/CO-RE (the kernel's own published type info), so it doesn't
#      compile against full headers and is far more resilient to this class
#      of kernel/tool version skew. It has no built-in PID/TGID filter for
#      kernel tracepoints (unlike bcc's/perf's `-p`), so the embedded
#      program below filters by thread comm name instead — see
#      `RUNQLAT_COMMS` below.
#   3. `perf sched record` + `perf sched latency` — per-task avg/max
#      scheduling delay, not a full histogram, but perf needs no
#      compilation at all, so it's the most portable of the three.
#
# Whichever bcc/bpftrace tool actually runs writes its status line,
# histogram, and any error text all to stdout (not stderr), so a bare `>`
# redirect would swallow failures silently into the raw output file with
# nothing shown on screen — every capture step below `tee`s instead.
#
# Two run modes, same convention as flamegraph-rust-perf.sh /
# flamegraph-rust-offcpu.sh:
#   HOST=1 (Linux recommended): release binary on the host + Go echo upstream.
#   default: compose stack up, profile the proxy container's host PID.
#
# Prerequisites:
#   - Linux with root/sudo
#   - Method 1: bpfcc-tools / bcc-tools package (runqlat-bpfcc or runqlat)
#   - Method 2: bpftrace, plus a kernel new enough to expose BTF
#     (/sys/kernel/btf/vmlinux — standard on any 5.x+ distro kernel)
#   - Method 3: perf (linux-perf / linux-tools) — no extra package beyond
#     what flamegraph-rust-perf.sh already needs
#   - oha on PATH; go on PATH for HOST=1 upstream; python3 on PATH (used to
#     turn the raw histograms into estimated percentiles)
#
# Usage:
#   scripts/runqlat-rust.sh [phase] [offered_rps] [duration_s]
#   HOST=1 scripts/runqlat-rust.sh 1a 500
#   make runqlat-rust PHASE=1a N=500
#   make runqlat-rust HOST=1 PHASE=1a N=500
#   make runqlat-rust HOST=1 PHASE=1a N=1000   # comparison point
#
# THREADS=1 env var adds runqlat's -L flag (per-thread-ID breakdown) instead
# of one process-wide histogram, when the bcc method is the one that runs —
# useful for isolating tokio-rt-worker threads specifically, at the cost of
# one histogram per thread to read.
#
# RUNQLAT_COMMS env var (default "service-proxy,tokio-rt-worker") sets the
# comma-separated thread comm names the bpftrace method scopes its
# histogram to — these are the exact names already confirmed on this proxy
# by the on-CPU/off-CPU captures earlier; override if a build's thread
# names differ.
set -euo pipefail

PHASE="${1:-2a}"
N="${2:-2000}"
DURATION="${3:-30}"
HOST="${HOST:-0}"
THREADS="${THREADS:-0}"
RUNQLAT_COMMS="${RUNQLAT_COMMS:-service-proxy,tokio-rt-worker}"
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

find_bpftrace_bin() {
  command -v bpftrace 2>/dev/null
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
lines.append("Method: bcc runqlat (eBPF)")
lines.append(f"Unit: {unit} (values are upper-bound estimates per log2 bucket)")
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

# Parse bpftrace's log2 histogram text output (bracket notation with K/M/G
# magnitude suffixes, e.g. "[16, 32)" or "[512K, 1M)") into estimated
# percentiles — same upper-bound-per-bucket methodology as summarize_histogram
# above, just a different text format to parse since bpftrace's hist()
# doesn't print the same way bcc's print_log2_hist() does.
summarize_bpftrace_histogram() {
  local raw="$1"
  local summary="$2"
  python3 - "${raw}" "${summary}" <<'PYEOF'
import re, sys

raw_path, summary_path = sys.argv[1], sys.argv[2]
text = open(raw_path).read()

def parse_num(s):
    s = s.strip()
    mult = 1
    if s and s[-1] in "KMG":
        mult = {"K": 1024, "M": 1024**2, "G": 1024**3}[s[-1]]
        s = s[:-1]
    return int(float(s) * mult)

single_re = re.compile(r'^\[(\d+)\]\s+(\d+)\s*\|', re.MULTILINE)
range_re = re.compile(r'^\[([\d.]+[KMG]?),\s*([\d.]+[KMG]?)\)\s+(\d+)\s*\|', re.MULTILINE)

buckets = []
for m in single_re.finditer(text):
    v, c = int(m.group(1)), int(m.group(2))
    buckets.append((v, v, c))
for m in range_re.finditer(text):
    lo, hi, c = parse_num(m.group(1)), parse_num(m.group(2)), int(m.group(3))
    buckets.append((lo, hi, c))
buckets.sort(key=lambda b: b[0])

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
lines.append("Method: bpftrace runqlat (eBPF, BTF/CO-RE)")
lines.append("Unit: usecs (values are upper-bound estimates per log2 bucket)")
p = percentiles(buckets)
if p is None:
    lines.append("No scheduling events captured — empty histogram, or no thread")
    lines.append("matched the comm filter (check RUNQLAT_COMMS against the raw file).")
else:
    lines.append(f"Samples: {p['n']}")
    for k in (50, 90, 99, 99.9):
        lines.append(f"p{k}: <= {p[k]} usecs")
    lines.append(f"max observed bucket: <= {p['max']} usecs")

out = "\n".join(lines) + "\n"
open(summary_path, "w").write(out)
print(out, end="")
PYEOF
}

# Parse `perf sched latency -p` table output (per-task Runtime/Count/Avg/Max
# delay in ms) into an aggregate. This is the fallback's ceiling: real
# avg/max numbers, but not a full percentile histogram — no p99/p99.9 the
# way the bcc path gives, since perf sched latency doesn't retain a
# distribution, only per-task summary stats.
summarize_perf_latency() {
  local raw="$1"
  local summary="$2"
  python3 - "${raw}" "${summary}" <<'PYEOF'
import re, sys

raw_path, summary_path = sys.argv[1], sys.argv[2]
text = open(raw_path).read()

row_re = re.compile(
    r'^\s*(\S+)\s*\|\s*([\d.]+)\s*ms\s*\|\s*(\d+)\s*\|\s*'
    r'avg:\s*([\d.]+)\s*ms\s*\|\s*max:\s*([\d.]+)\s*ms\s*\|',
    re.MULTILINE,
)

rows = [
    (task, float(runtime), int(count), float(avg), float(mx))
    for task, runtime, count, avg, mx in row_re.findall(text)
]

lines = []
lines.append("Method: perf sched latency (fallback; avg/max only, not a full histogram)")
lines.append("Unit: ms")
if not rows:
    lines.append("No matching task rows parsed (check the raw file for perf's actual output).")
else:
    total_count = sum(c for _, _, c, _, _ in rows)
    total_runtime = sum(r for _, r, _, _, _ in rows)
    weighted_avg = (
        sum(avg * c for _, _, c, avg, _ in rows) / total_count if total_count else 0.0
    )
    overall_max = max(mx for _, _, _, _, mx in rows)
    lines.append(f"Tasks: {len(rows)}")
    lines.append(f"Total scheduling events (count): {total_count}")
    lines.append(f"Total on-CPU runtime across tasks: {total_runtime:.3f} ms")
    lines.append(f"Count-weighted avg scheduling delay: {weighted_avg:.3f} ms")
    lines.append(f"Max scheduling delay observed (any task): {overall_max:.3f} ms")
    top = sorted(rows, key=lambda r: -r[4])[:5]
    lines.append("Top 5 tasks by max delay:")
    for task, runtime, count, avg, mx in top:
        lines.append(f"  {task}: avg={avg:.3f}ms max={mx:.3f}ms count={count}")

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

RUNQLAT_BIN="$(find_runqlat_bin)" || true
if [[ -z "${RUNQLAT_BIN:-}" ]]; then
  echo "No bcc runqlat found (looked for runqlat-bpfcc / runqlat)." >&2
fi

BPFTRACE_BIN="$(find_bpftrace_bin)" || true
if [[ -z "${BPFTRACE_BIN:-}" ]]; then
  echo "No bpftrace found on PATH either." >&2
fi

if [[ -z "${RUNQLAT_BIN:-}" && -z "${BPFTRACE_BIN:-}" ]]; then
  echo "Falling back to 'perf sched record' + 'perf sched latency' (avg/max only)." >&2
fi

capture_runqlat_bcc() {
  local bin="$1"
  local pid="$2"
  local flags=(-p "${pid}")
  if [[ "${THREADS}" == "1" ]]; then
    flags+=(-L)
  fi
  echo "Capturing run-queue latency via ${bin} (bcc/eBPF) for ${DURATION}s..."
  # `tee` instead of a plain `>` redirect: runqlat-bpfcc writes its status
  # line, histogram, and any error text all to stdout (not stderr), so a
  # bare redirect swallows failures silently into ${RAW} with nothing shown
  # on screen. `2>&1 | tee` surfaces everything live while still capturing
  # it; `set -o pipefail` (from `set -euo pipefail` above) makes a failing
  # runqlat still fail the pipeline even though `tee` itself exits 0.
  sudo "${bin}" "${flags[@]}" "${DURATION}" 1 2>&1 | tee "${RAW}"
}

# Builds a small bpftrace program (adapted from bpftrace's own tools/runqlat.bt
# by Brendan Gregg/Netflix) and runs it for ${DURATION}s. Unlike bcc's -p or
# perf's -p, there's no kernel-tracepoint-level PID/TGID filter available in
# bpftrace, so this scopes the *histogram* (not the wakeup bookkeeping, which
# stays unfiltered same as upstream — it's cheap, and filtering it risks
# missing legitimate wakeups) to threads whose comm matches RUNQLAT_COMMS.
capture_runqlat_bpftrace() {
  local bin="$1"
  local script="${OUT_DIR}/phase${PHASE}_N${N}.runqlat.bt"

  # RUNQLAT_COMMS is a plain comma list, no spaces (e.g.
  # "service-proxy,tokio-rt-worker") — keep it that way, this doesn't trim.
  local comm_cond="" name
  local IFS=','
  for name in ${RUNQLAT_COMMS}; do
    [[ -z "${name}" ]] && continue
    if [[ -n "${comm_cond}" ]]; then
      comm_cond+=" || "
    fi
    comm_cond+="args.next_comm == \"${name}\""
  done

  cat > "${script}" <<BPFEOF
#!/usr/bin/env bpftrace
// Run-queue latency histogram, scoped to comm in {${RUNQLAT_COMMS}}.
// Adapted from bpftrace's tools/runqlat.bt (Netflix/Brendan Gregg, 2018):
// same wakeup/prev-state bookkeeping, with a comm-name filter added only on
// the final histogram-record step.
#ifndef BPFTRACE_HAVE_BTF
#include <linux/sched.h>
#else
#define TASK_RUNNING 0
#endif

BEGIN
{
  printf("Tracing run-queue latency (comm in {${RUNQLAT_COMMS}})...\n");
}

tracepoint:sched:sched_wakeup,
tracepoint:sched:sched_wakeup_new
{
  @qtime[args.pid] = nsecs;
}

tracepoint:sched:sched_switch
{
  if (args.prev_state == TASK_RUNNING) {
    @qtime[args.prev_pid] = nsecs;
  }
  if (args.next_pid == 0) {
    return;
  }
  \$ns = @qtime[args.next_pid];
  if (\$ns && (${comm_cond})) {
    @usecs = hist((nsecs - \$ns) / 1000);
  }
  \$ignore = delete(@qtime, args.next_pid);
}

interval:s:${DURATION}
{
  exit();
}

END
{
  clear(@qtime);
}
BPFEOF

  echo "Capturing run-queue latency via bpftrace for ${DURATION}s (comm in {${RUNQLAT_COMMS}})..."
  sudo "${bin}" "${script}" 2>&1 | tee "${RAW}"
}

capture_runqlat_perf() {
  local pid="$1"
  local data="${OUT_DIR}/phase${PHASE}_N${N}.runqlat.perf.data"
  echo "Capturing run-queue latency via 'perf sched record'/'perf sched latency' for ${DURATION}s..."
  echo "(fallback method: avg/max scheduling delay per task, not a full percentile histogram)"
  sudo perf sched record -p "${pid}" -o "${data}" -- sleep "${DURATION}"
  sudo chmod a+r "${data}"
  # -p: per-pid rows instead of merged-by-command-name, so threads with the
  # same name (e.g. multiple tokio-rt-worker threads) stay distinguishable.
  perf sched latency -i "${data}" -p 2>&1 | tee "${RAW}"
}

# Tries bcc, then bpftrace, then perf — each only if the previous is
# missing or fails at runtime. `if cmd; then ... else ...` (rather than
# `cmd || fallback`) is used throughout so `set -e` doesn't abort the whole
# script on the first failed attempt; each capture_runqlat_* function's own
# exit status is what decides whether to move to the next method.
capture_runqlat() {
  local pid="$1"
  local method=""

  if [[ -n "${RUNQLAT_BIN:-}" ]] && capture_runqlat_bcc "${RUNQLAT_BIN}" "${pid}"; then
    method="bcc"
  else
    [[ -n "${RUNQLAT_BIN:-}" ]] && echo "bcc runqlat failed at runtime." >&2

    if [[ -n "${BPFTRACE_BIN:-}" ]] && capture_runqlat_bpftrace "${BPFTRACE_BIN}" "${pid}"; then
      method="bpftrace"
    else
      [[ -n "${BPFTRACE_BIN:-}" ]] && echo "bpftrace attempt failed at runtime." >&2
      echo "Falling back to 'perf sched record' + 'perf sched latency' (avg/max only)." >&2
      capture_runqlat_perf "${pid}"
      method="perf"
    fi
  fi

  echo "Wrote ${RAW}"
  case "${method}" in
    bcc) summarize_histogram "${RAW}" "${SUMMARY}" ;;
    bpftrace) summarize_bpftrace_histogram "${RAW}" "${SUMMARY}" ;;
    perf) summarize_perf_latency "${RAW}" "${SUMMARY}" ;;
  esac
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
