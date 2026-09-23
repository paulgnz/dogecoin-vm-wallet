#!/usr/bin/env bash
# Builds the Rust core as a universal (Apple silicon + Intel) static library
# and places it where the macOS app links it. Run after changing core/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/apps/macos/Vendor"
LIB=libdogevm_wallet_core.a
cd "$ROOT/core"
for target in aarch64-apple-darwin x86_64-apple-darwin; do
  rustup target list --installed | grep -q "^$target$" || rustup target add "$target"
  MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --release --target "$target" --quiet
done
mkdir -p "$VENDOR"
lipo -create target/aarch64-apple-darwin/release/$LIB target/x86_64-apple-darwin/release/$LIB -output "$VENDOR/$LIB"
lipo -info "$VENDOR/$LIB"
