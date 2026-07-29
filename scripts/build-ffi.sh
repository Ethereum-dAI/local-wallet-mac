#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUST_DIR="$REPO_ROOT/rust-core"
BRIDGE_DIR="$REPO_ROOT/swift-bridge"
DEPLOYMENT_TARGET="${LOCAL_WALLET_DEPLOYMENT_TARGET:-15.0}"

export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"

echo "=== Building wallet-ffi (transitively materializes wallet-node-api) ==="
cd "$RUST_DIR"
cargo build -p wallet-ffi --release --target aarch64-apple-darwin

echo "=== Generating C header with cbindgen ==="
mkdir -p "$BRIDGE_DIR/Sources/WalletFFI"
cbindgen --config crates/ffi/cbindgen.toml \
         --crate wallet-ffi \
         --output "$BRIDGE_DIR/Sources/WalletFFI/wallet_ffi.h"

echo "=== Locating wallet-node-api OUT_DIR (post-split: it's a transitive git dep) ==="
TARGET_DIR="target"

OUT_DIR="$(find "$TARGET_DIR/aarch64-apple-darwin/release/build" -path '*wallet-node-api-*/out/wallet_node_api_version.h' -print -quit | xargs -I{} dirname {})"
if [[ -z "$OUT_DIR" ]]; then
    OUT_DIR="$(find "$TARGET_DIR/release/build" -path '*wallet-node-api-*/out/wallet_node_api_version.h' -print -quit | xargs -I{} dirname {})"
fi
if [[ -z "$OUT_DIR" ]]; then
    echo "ERROR: Could not locate wallet-node-api build output." >&2
    echo "  Expected: $TARGET_DIR/aarch64-apple-darwin/release/build/wallet-node-api-*/out/" >&2
    echo "  Did 'cargo build -p wallet-ffi' run? wallet-node-api is a transitive git dep." >&2
    exit 1
fi

VERSION_HEADER_SRC="$OUT_DIR/wallet_node_api_version.h"
VERSION_HEADER_DST="$BRIDGE_DIR/Sources/WalletFFI/wallet_node_api_version.h"

if [[ ! -f "$VERSION_HEADER_SRC" ]]; then
    echo "ERROR: Missing wallet-node-api version header: $VERSION_HEADER_SRC" >&2
    exit 1
fi

cp -f "$VERSION_HEADER_SRC" "$VERSION_HEADER_DST"
echo "Version header: $VERSION_HEADER_SRC -> $VERSION_HEADER_DST"

echo "=== Copying static library ==="
mkdir -p "$BRIDGE_DIR/lib"
cp "target/aarch64-apple-darwin/release/libwallet_ffi.a" "$BRIDGE_DIR/lib/"

echo "=== Done ==="
echo "Library: $BRIDGE_DIR/lib/libwallet_ffi.a"
echo "Header:  $BRIDGE_DIR/Sources/WalletFFI/wallet_ffi.h"
