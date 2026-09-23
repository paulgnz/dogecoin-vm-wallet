#!/usr/bin/env bash
# Copies the wallet test vectors from a dogecoin-vm checkout (default
# ../dogecoin-vm), where the web wallet generates them and the Go code checks
# them. The core's tests must then pass unchanged.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/../dogecoin-vm}/cmd/dogevm/testdata/wallet-vectors.json"
cp "$SRC" "$ROOT/core/tests/vectors/wallet-vectors.json"
(cd "$ROOT/core" && cargo test --quiet)
