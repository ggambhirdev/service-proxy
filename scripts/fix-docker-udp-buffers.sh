#!/usr/bin/env bash
# Raises net.core.rmem_max/wmem_max inside the Docker Desktop (macOS) Linux
# VM. quic-go tries to set a UDP socket's receive buffer to 7MiB and logs a
# warning when the OS won't let it (Docker Desktop's default VM caps these
# at ~208KiB) -- relevant to phase 3a/3b (QUIC/HTTP3), which both hit this.
#
# These are host-global (non-namespaced) sysctls: an unprivileged container
# can't set them (Docker mounts that /proc/sys path read-only), so this
# reaches into the actual VM via a privileged, host-PID-namespace container
# and writes them there. Not persistent -- Docker Desktop resets the VM's
# sysctls on every restart, so re-run this after restarting Docker Desktop
# and before benchmarking phase 3a/3b.
#
# Only relevant on Docker Desktop for macOS. Not needed (and this script
# doesn't apply) on Linux, where net.core.rmem_max/wmem_max defaults are
# already high enough for this project's purposes.
set -euo pipefail

BUF_BYTES=7340032 # 7 MiB, matches what quic-go asks for

echo "==> Raising UDP buffer sysctls in the Docker Desktop VM..."
docker run --rm --privileged --pid=host alpine sh -c "
  nsenter -t 1 -m -u -n -i sh -c '
    echo ${BUF_BYTES} > /proc/sys/net/core/rmem_max
    echo ${BUF_BYTES} > /proc/sys/net/core/wmem_max
    echo ${BUF_BYTES} > /proc/sys/net/core/rmem_default
    echo ${BUF_BYTES} > /proc/sys/net/core/wmem_default
    echo \"rmem_max=\$(cat /proc/sys/net/core/rmem_max) wmem_max=\$(cat /proc/sys/net/core/wmem_max)\"
  '
"

echo "==> Done. Restart any already-running proxy containers to pick this up"
echo "    (a fresh 'docker compose up' after this point is sufficient)."
