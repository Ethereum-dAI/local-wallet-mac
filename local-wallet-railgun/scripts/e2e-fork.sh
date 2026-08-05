#!/usr/bin/env bash
# End-to-end: shield native ETH into RAILGUN on an anvil Sepolia fork, then exit it twice
# through RAILGUN's privacy paymaster as ERC-4337 UserOperations on EntryPoint v0.8, and
# confirm the recipient received NATIVE ETH on-chain. See tests/e2e_fork.rs.
#
# Usage:
#   RPC_URL_SEPOLIA="https://sepolia.infura.io/v3/<key>" ./scripts/e2e-fork.sh
#
# Requires:
#   * foundry (anvil) on PATH;
#   * a local ALTO bundler — a public bundler cannot see the fork, and the pinned
#     PimlicoBundler client needs `pimlico_getUserOperationGasPrice`. The fixture spawns it via
#     `npx --yes @pimlico/alto@0.0.20` (so node/npx must be on PATH and able to reach npm), or
#     from $LOCAL_WALLET_ALTO_BIN if that is set. There is NO skip path: without a bundler the
#     fixture fails loudly rather than reporting a hollow pass.
#   * outbound network (RAILGUN Subsquid + Groth16 circuit-artifact download on the first exit).
#
# Testnet only. Nothing here needs funding beyond anvil's own dev accounts: the paymaster pays
# gas from an in-pool fee note, so there is no relayer/broadcaster EOA anywhere in this path.
set -euo pipefail

if [[ -z "${RPC_URL_SEPOLIA:-}" ]]; then
  echo "error: set RPC_URL_SEPOLIA to a Sepolia RPC URL" >&2
  exit 1
fi
if ! command -v anvil >/dev/null 2>&1; then
  echo "error: anvil not found (install foundry: https://getfoundry.sh)" >&2
  exit 1
fi
if [[ -n "${LOCAL_WALLET_ALTO_BIN:-}" ]]; then
  if [[ ! -x "${LOCAL_WALLET_ALTO_BIN}" ]]; then
    echo "error: LOCAL_WALLET_ALTO_BIN=${LOCAL_WALLET_ALTO_BIN} is not executable" >&2
    exit 1
  fi
elif ! command -v npx >/dev/null 2>&1; then
  echo "error: neither LOCAL_WALLET_ALTO_BIN nor npx found; the fixture needs a local Alto" >&2
  echo "       bundler (install node, or point LOCAL_WALLET_ALTO_BIN at an alto binary)" >&2
  exit 1
fi

export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
# `railgun=info` is required, not cosmetic: the fixture's FEE CALIBRATION line counts the SDK's
# fee-loop and proving-artifact log lines to report the proof-round count per exit.
export RUST_LOG="${RUST_LOG:-railgun_helper=info,railgun=info}"

cd "$(dirname "$0")/.."
exec cargo test --features fork-sync --test e2e_fork -- --ignored --nocapture
