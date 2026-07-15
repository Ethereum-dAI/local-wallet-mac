#!/usr/bin/env bash
set -euo pipefail

# Daemon-driven end-to-end check on a forked Sepolia chain. Spawns an Anvil fork,
# then runs the ignored `sepolia_fork_daemon_e2e` test, which spawns the real
# wallet-node against the fork and submits a passkey UserOperation signed with
# usePrecompiled=true through the daemon's send pipeline.
#
# Usage:
#   FORK_RPC_URL=<sepolia-rpc> scripts/run-sepolia-fork-daemon-e2e.sh
#   (ETH_RPC_URL is also accepted; .env is sourced by default.)
#
# Forks latest Sepolia state, where Fusaka (EIP-7951 P256VERIFY at 0x100) is live.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${WALLET_FORK_ENV_FILE:-${ROOT_DIR}/.env}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

RPC_URL="${FORK_RPC_URL:-${ETH_RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}}"
FORK_PORT="${WALLET_FORK_PORT:-8546}"
FORK_URL="http://127.0.0.1:${FORK_PORT}"
ANVIL_LOG="$(mktemp -t wallet-sepolia-daemon-anvil.XXXXXX.log)"

cleanup() {
  if [[ -n "${ANVIL_PID:-}" ]]; then
    kill "${ANVIL_PID}" >/dev/null 2>&1 || true
    wait "${ANVIL_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "Starting Anvil fork of Sepolia at latest via ${RPC_URL}"
anvil \
  --host 127.0.0.1 \
  --port "${FORK_PORT}" \
  --fork-url "${RPC_URL}" \
  --chain-id 11155111 \
  >"${ANVIL_LOG}" 2>&1 &
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

echo "Anvil ready at ${FORK_URL}; running daemon-driven Sepolia fork E2E"
(
  cd "${ROOT_DIR}"
  WALLET_SEPOLIA_FORK_RPC_URL="${FORK_URL}" \
    cargo test -p wallet-node --test sepolia_fork_daemon_e2e -- --include-ignored --nocapture
)
