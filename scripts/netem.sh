#!/usr/bin/env bash
# netem.sh — inject or clear tc netem stress on a running proxy container's
# interface (phase 4). It runs tc from a throwaway helper container that
# SHARES the proxy's network namespace, so no change is needed to the proxy
# image or compose files: they grant no NET_ADMIN and ship no tc, but
# `--network container:<proxy> --cap-add NET_ADMIN` lets the helper shape the
# proxy's eth0 from the outside. This keeps the phase-2a/2b/3b stacks
# byte-for-byte identical to their un-stressed benchmarks.
#
# netem on the root qdisc shapes EGRESS (traffic the proxy sends): responses
# back to the client and requests out to the upstreams. Applied identically
# across 2a/2b/3b, the added degradation is equal, so a phase-vs-phase delta
# still isolates the client-leg protocol (pooled TCP vs gRPC/HTTP-2 vs
# HTTP-3/QUIC) under loss.
#
# Usage:
#   scripts/netem.sh <compose-file> add    <netem-args...>
#   scripts/netem.sh <compose-file> change <netem-args...>
#   scripts/netem.sh <compose-file> del
#   scripts/netem.sh <compose-file> show
#
# Examples:
#   scripts/netem.sh deploy/phase2a/docker-compose.yml add loss 1%
#   scripts/netem.sh deploy/phase3b/docker-compose.yml add delay 50ms 10ms distribution normal
#   scripts/netem.sh deploy/phase2a/docker-compose.yml del
#
# Env overrides: NETEM_IFACE (default eth0), NETEM_IMAGE (default
# nicolaka/netshoot — any image shipping `tc`/iproute2 works).
set -euo pipefail

COMPOSE="${1:?usage: netem.sh <compose-file> <add|change|del|show> [netem-args...]}"
ACTION="${2:?usage: netem.sh <compose-file> <add|change|del|show> [netem-args...]}"
shift 2

IFACE="${NETEM_IFACE:-eth0}"
IMAGE="${NETEM_IMAGE:-nicolaka/netshoot}"

PROXY="$(docker compose -f "$COMPOSE" ps -q proxy)"
if [ -z "$PROXY" ]; then
  echo "netem.sh: no running proxy container for $COMPOSE (is the stack up?)" >&2
  exit 1
fi

run_tc() {
  docker run --rm --network "container:$PROXY" --cap-add NET_ADMIN "$IMAGE" tc "$@"
}

case "$ACTION" in
  add|change)
    run_tc qdisc "$ACTION" dev "$IFACE" root netem "$@"
    ;;
  del)
    run_tc qdisc del dev "$IFACE" root netem
    ;;
  show)
    run_tc qdisc show dev "$IFACE"
    ;;
  *)
    echo "netem.sh: unknown action '$ACTION' (add|change|del|show)" >&2
    exit 1
    ;;
esac
