#!/usr/bin/env bash
# End-to-end: shield + unshield on an anvil Sepolia fork, unshield relayed by the local
# broadcaster. Confirms both txs on-chain. See tests/e2e_fork.rs.
#
# Usage:
#   RPC_URL_SEPOLIA="https://sepolia.infura.io/v3/<key>" ./scripts/e2e-fork.sh
#
# Requires: foundry (anvil) on PATH; outbound network (RAILGUN Subsquid + Groth16
# circuit-artifact download on first unshield). Testnet only.
set -euo pipefail

if [[ -z "${RPC_URL_SEPOLIA:-}" ]]; then
  echo "error: set RPC_URL_SEPOLIA to a Sepolia RPC URL" >&2
  exit 1
fi
if ! command -v anvil >/dev/null 2>&1; then
  echo "error: anvil not found (install foundry: https://getfoundry.sh)" >&2
  exit 1
fi

export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
export RUST_LOG="${RUST_LOG:-railgun_helper=info,railgun=warn}"

cd "$(dirname "$0")/.."
exec cargo test --features fork-sync --test e2e_fork -- --ignored --nocapture
