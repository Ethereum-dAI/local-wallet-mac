#!/usr/bin/env bash
#
# One-shot dev runner for manually testing the RAILGUN /shield + /unshield flow in the
# macOS app. Consolidates every build step so you don't have to run them by hand:
#
#   1. build-ffi.sh                              (wallet-ffi + cbindgen -> swift-bridge)
#   2. cargo build -p wallet-node --release      (the daemon the app spawns)
#   3. cargo build --release --bins              (railgun-helper + railgun-broadcaster;
#                                                  the app spawns these on first /shield)
#   4. xcodegen generate                         (regenerate LocalWallet.xcodeproj)
#   5. open LocalWallet.xcodeproj                (you hit Run — signing/Secure Enclave
#                                                  needs the signed Xcode bundle)
#
# Then in the app's chat: `/shield 0.01`, then `/unshield 0.01 to 0x<addr>`. The app
# launches the sidecar on its active chain automatically — no manual sidecar or env vars.
#
# Usage:
#   scripts/dev-run-railgun-app.sh              # steps 1-4, then open Xcode
#   scripts/dev-run-railgun-app.sh --no-open    # steps 1-4 only (CI / re-build)
#   scripts/dev-run-railgun-app.sh --xcodebuild # also compile the app via xcodebuild
#   scripts/dev-run-railgun-app.sh --e2e        # skip the app; run the anvil fork e2e
#                                               #   (needs RPC_URL_SEPOLIA) — the automated
#                                               #   on-chain proof of shield+unshield
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

OPEN=1
XCODEBUILD=0
E2E=0
for arg in "$@"; do
  case "$arg" in
    --no-open) OPEN=0 ;;
    --xcodebuild) XCODEBUILD=1 ;;
    --e2e) E2E=1 ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $arg (see --help)" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$1"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' not found on PATH — $2" >&2; exit 1; }; }

# --- e2e shortcut: the automated on-chain proof, no app needed ---------------------------
if [[ "$E2E" == 1 ]]; then
  need cargo "install Rust"
  need anvil "install foundry (https://getfoundry.sh)"
  : "${RPC_URL_SEPOLIA:?set RPC_URL_SEPOLIA to a Sepolia RPC URL for the fork e2e}"
  step "RAILGUN fork e2e (shield + unshield on an anvil Sepolia fork)"
  exec "$REPO_ROOT/local-wallet-railgun/scripts/e2e-fork.sh"
fi

# --- prerequisites -----------------------------------------------------------------------
need cargo "install Rust (https://rustup.rs)"
need cbindgen "cargo install cbindgen"
need xcodegen "brew install xcodegen"

step "1/4  Building wallet-ffi (build-ffi.sh)"
"$REPO_ROOT/scripts/build-ffi.sh"

step "2/4  Building the wallet-node daemon (release)"
( cd "$REPO_ROOT/local-wallet-daemon" && cargo build -p wallet-node --release )

step "3/4  Building the railgun sidecars (release: railgun-helper + railgun-broadcaster)"
( cd "$REPO_ROOT/local-wallet-railgun" && cargo build --release --bins )

step "4/4  Regenerating LocalWallet.xcodeproj (xcodegen)"
xcodegen generate

if [[ "$XCODEBUILD" == 1 ]]; then
  need xcodebuild "install Xcode"
  step "Compiling the app via xcodebuild (LocalWalletApp, Debug)"
  echo "note: a code-signing team is required; pass DEVELOPMENT_TEAM=XXXXXXXXXX to override."
  xcodebuild \
    -project LocalWallet.xcodeproj \
    -scheme LocalWalletApp \
    -configuration Debug \
    ${DEVELOPMENT_TEAM:+DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"} \
    -allowProvisioningUpdates \
    build
fi

step "Done"
cat <<'NEXT'
Next:
  - The app resolves the sidecars from local-wallet-railgun/target/release and the daemon
    from local-wallet-daemon/target/release automatically (via the Xcode scheme + source
    paths) — nothing else to set.
  - In Xcode: select the LocalWalletApp scheme, choose your Apple Development team, Run.
    (Do NOT `swift run` the app — Secure Enclave/Keychain needs the signed bundle.)
  - Finish onboarding (create wallet, set the Sepolia RPC), then in chat type:
        /shield 0.01
        /unshield 0.01 to 0x<recipient-address>
NEXT

if [[ "$OPEN" == 1 ]]; then
  step "Opening LocalWallet.xcodeproj"
  open "$REPO_ROOT/LocalWallet.xcodeproj"
fi
