#!/usr/bin/env bash
set -euo pipefail

# The daemon crates live in-repo at local-wallet-daemon/ (consolidated from
# the former sibling checkout), so daemon-side cargo invocations resolve
# there by default. Override the location by setting
# LW_DAEMON_DIR=/path/to/local-wallet-daemon.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== Rust format ==="
(cd "${LW_DAEMON_DIR:-${ROOT_DIR}/local-wallet-daemon}" && cargo fmt --check)

echo "=== Rust workspace tests ==="
(cd "${LW_DAEMON_DIR:-${ROOT_DIR}/local-wallet-daemon}" && cargo test --workspace)

echo "=== Rust clippy ==="
(cd "${LW_DAEMON_DIR:-${ROOT_DIR}/local-wallet-daemon}" && cargo clippy --workspace -- -D warnings)

echo "=== wallet-node release build ==="
(cd "${LW_DAEMON_DIR:-${ROOT_DIR}/local-wallet-daemon}" && cargo build -p wallet-node --release)

echo "=== wallet-node fd integration ==="
(cd "${LW_DAEMON_DIR:-${ROOT_DIR}/local-wallet-daemon}" && cargo test -p wallet-node --test integration_fd_e2e -- --include-ignored)

echo "=== wallet-node Unix transport integration ==="
(cd "${LW_DAEMON_DIR:-${ROOT_DIR}/local-wallet-daemon}" && cargo test -p wallet-node --test integration_unix_e2e -- --include-ignored)

echo "=== wallet-node HTTP integration ==="
(cd "${LW_DAEMON_DIR:-${ROOT_DIR}/local-wallet-daemon}" && cargo test -p wallet-node --test integration_e2e -- --include-ignored)

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
