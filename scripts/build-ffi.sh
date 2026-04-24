#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUST_DIR="$REPO_ROOT/rust-core"
BRIDGE_DIR="$REPO_ROOT/swift-bridge"

echo "=== Building wallet-ffi (release, aarch64-apple-darwin) ==="
cd "$RUST_DIR"
cargo build -p wallet-ffi --release --target aarch64-apple-darwin

echo "=== Generating C header with cbindgen ==="
mkdir -p "$BRIDGE_DIR/Sources/WalletFFI"
cbindgen --config crates/ffi/cbindgen.toml \
         --crate wallet-ffi \
         --output "$BRIDGE_DIR/Sources/WalletFFI/wallet_ffi.h"

echo "=== Copying static library ==="
mkdir -p "$BRIDGE_DIR/lib"
cp "target/aarch64-apple-darwin/release/libwallet_ffi.a" "$BRIDGE_DIR/lib/"

echo "=== Done ==="
echo "Library: $BRIDGE_DIR/lib/libwallet_ffi.a"
echo "Header:  $BRIDGE_DIR/Sources/WalletFFI/wallet_ffi.h"
