#!/usr/bin/env bash
# One-time dev-machine setup: builds oha with its experimental HTTP/3
# support (the `http3` cargo feature, backed by rustls) and installs it as
# `oha-http3` on PATH -- a separate binary name so it doesn't shadow the
# plain `oha` build the other benchmark phases use. Requires a Rust/cargo
# toolchain. Used by the Makefile's bench3b target ($(OHA_HTTP3)).
set -euo pipefail

if command -v oha-http3 >/dev/null 2>&1; then
  echo "oha-http3 already installed at $(command -v oha-http3)"
  exit 0
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not found; install a Rust toolchain first (e.g. https://rustup.rs)" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

echo "==> Building oha with --features http3 (this compiles rustls + h3)..."
cargo install --features http3 oha --root "$WORKDIR"

INSTALL_DIR="/usr/local/bin"
echo "==> Installing oha-http3 to ${INSTALL_DIR}/oha-http3 (may prompt for sudo)..."
sudo cp "$WORKDIR/bin/oha" "${INSTALL_DIR}/oha-http3"

echo "oha-http3 installed: $(oha-http3 --version 2>&1 | head -1 || true)"
