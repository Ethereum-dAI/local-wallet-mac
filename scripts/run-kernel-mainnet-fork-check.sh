#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ETH_RPC_URL=<archive-or-public-rpc> WALLET_FORK_BLOCK_NUMBER=<block> \
#     scripts/run-kernel-mainnet-fork-check.sh
#
# The script also sources .env by default. Set WALLET_FORK_ENV_FILE=.env.fork
# to use a different ignored env file.
#
# If WALLET_FORK_BLOCK_NUMBER is omitted, the script forks latest state.
# Pinned historical blocks require an archive-capable RPC provider.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${WALLET_FORK_ENV_FILE:-${ROOT_DIR}/.env}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

RPC_URL="${ETH_RPC_URL:-https://ethereum-rpc.publicnode.com}"
FORK_PORT="${WALLET_FORK_PORT:-8545}"
FORK_URL="http://127.0.0.1:${FORK_PORT}"
ANVIL_LOG="$(mktemp -t wallet-kernel-fork-anvil.XXXXXX.log)"

cleanup() {
  if [[ -n "${ANVIL_PID:-}" ]]; then
    kill "${ANVIL_PID}" >/dev/null 2>&1 || true
    wait "${ANVIL_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

ANVIL_ARGS=(
  --host 127.0.0.1
  --port "${FORK_PORT}"
  --fork-url "${RPC_URL}"
)

if [[ -n "${WALLET_FORK_BLOCK_NUMBER:-}" ]]; then
  ANVIL_ARGS+=(--fork-block-number "${WALLET_FORK_BLOCK_NUMBER}")
  echo "Starting Anvil fork at block ${WALLET_FORK_BLOCK_NUMBER}"
else
  echo "Starting Anvil fork at latest"
fi

anvil "${ANVIL_ARGS[@]}" >"${ANVIL_LOG}" 2>&1 &
ANVIL_PID=$!

for _ in {1..60}; do
  if cast chain-id --rpc-url "${FORK_URL}" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "${ANVIL_PID}" >/dev/null 2>&1; then
    echo "Anvil exited before becoming ready. Log:"
    cat "${ANVIL_LOG}"
    exit 1
  fi
  sleep 0.5
done

if ! cast chain-id --rpc-url "${FORK_URL}" >/dev/null 2>&1; then
  echo "Timed out waiting for Anvil. Log:"
  cat "${ANVIL_LOG}"
  exit 1
fi

echo "Anvil ready at ${FORK_URL}; running Kernel fork validation"
(
  cd "${ROOT_DIR}/rust-core"
  WALLET_MAINNET_FORK_RPC_URL="${FORK_URL}" \
    cargo test -p wallet-node --test mainnet_fork_kernel -- --include-ignored --nocapture
)
