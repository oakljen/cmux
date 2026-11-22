#!/usr/bin/env bash
# Build cmux-tui on Debian/Ubuntu. Installs deps, Rust 1.95.0 and Zig 0.16.0 if missing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ZIG_DIR="${ZIG_DIR:-/opt/zig}"
sudo apt-get update -qq
sudo apt-get install -y -qq build-essential libclang-dev pkg-config unzip git curl xz-utils
if ! command -v cargo >/dev/null; then
  curl -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain 1.95.0 --profile minimal
fi
# shellcheck disable=SC1091
. "$HOME/.cargo/env"
if [ ! -x "$ZIG_DIR/zig" ]; then
  tmp="$(mktemp)"
  curl -sSLo "$tmp" https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz
  sudo mkdir -p "$ZIG_DIR" && sudo tar -xf "$tmp" -C "$ZIG_DIR" --strip-components=1
fi
export PATH="$ZIG_DIR:$PATH"
git -C "$ROOT" submodule update --init --depth 1 ghostty
cd "$ROOT/cmux-tui" && cargo build -p cmux-tui
echo "built: $ROOT/cmux-tui/target/debug/cmux-tui"
