#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== Rust format ==="
(
  cd "${ROOT_DIR}/rust-core"
  cargo fmt --check
)

echo "=== Rust workspace tests ==="
(
  cd "${ROOT_DIR}/rust-core"
  cargo test --workspace
)

echo "=== Rust clippy ==="
(
  cd "${ROOT_DIR}/rust-core"
  cargo clippy --workspace -- -D warnings
)

echo "=== wallet-node release build ==="
(
  cd "${ROOT_DIR}/rust-core"
  cargo build -p wallet-node --release
)

echo "=== wallet-node fd integration ==="
(
  cd "${ROOT_DIR}/rust-core"
  cargo test -p wallet-node --test integration_fd_e2e -- --include-ignored
)

echo "=== wallet-node Unix transport integration ==="
(
  cd "${ROOT_DIR}/rust-core"
  cargo test -p wallet-node --test integration_unix_e2e -- --include-ignored
)

echo "=== wallet-node HTTP integration ==="
(
  cd "${ROOT_DIR}/rust-core"
  cargo test -p wallet-node --test integration_e2e -- --include-ignored
)

echo "=== Swift bridge tests ==="
(
  cd "${ROOT_DIR}/swift-bridge"
  swift test
)

echo "=== macOS app package tests ==="
(
  cd "${ROOT_DIR}/wallet-macos"
  swift test
)

echo "=== signed macOS app target build ==="
(
  cd "${ROOT_DIR}"
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen is required to verify the signed macOS app target" >&2
    exit 1
  fi
  xcodegen generate
  xcodebuild -project LocalWallet.xcodeproj \
    -scheme LocalWalletApp \
    -configuration Debug \
    -destination 'platform=macOS' \
    build
)

echo "=== Diff whitespace check ==="
(
  cd "${ROOT_DIR}"
  git diff --check
)

echo "=== Bundler key hardening automated gate passed ==="
