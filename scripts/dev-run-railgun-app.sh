#!/usr/bin/env bash
#
# One-shot dev runner for manually testing the RAILGUN /shield + /unshield flow in the
# macOS app. Consolidates every build step so you don't have to run them by hand:
#
#   1. build-ffi.sh                              (wallet-ffi + cbindgen -> swift-bridge)
#   2. cargo build -p wallet-node --release      (the daemon the app spawns)
#   3. cargo build --release --bins              (railgun-helper — one binary, no child
#                                                  process; the app spawns it on first
#                                                  /shield or /unshield)
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
#   scripts/dev-run-railgun-app.sh --doctor     # diagnose a Secure Enclave / signing error
#   scripts/dev-run-railgun-app.sh --regen      # force-regenerate the Xcode project.
#                                               #   Rarely needed: the project regenerates
#                                               #   automatically whenever it disagrees with the
#                                               #   app source tree (a branch added or removed a
#                                               #   file). Either way your signing team is
#                                               #   carried forward, so a regen no longer
#                                               #   orphans an existing wallet.
#
#   DEVELOPMENT_TEAM=<team-id> scripts/dev-run-railgun-app.sh
#                                               # bake YOUR signing team into the generated
#                                               #   project (fixes the Secure Enclave
#                                               #   "Generation failed" onboarding error)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

OPEN=1
XCODEBUILD=0
E2E=0
DOCTOR=0
REGEN=0
for arg in "$@"; do
  case "$arg" in
    --no-open) OPEN=0 ;;
    --xcodebuild) XCODEBUILD=1 ;;
    --e2e) E2E=1 ;;
    --doctor) DOCTOR=1 ;;
    --regen) REGEN=1 ;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $arg (see --help)" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$1"; }

# --doctor: diagnose the #1 manual-test failure — a Secure Enclave onboarding error
# ("Secure Enclave key reference is missing" / "Generation failed"), which is really a
# code-signing/entitlement problem: the SE keychain-access-group needs a REAL signing team,
# not ad-hoc ("Sign to Run Locally"). Inspect the built app's signature + entitlements.
if [[ "$DOCTOR" == 1 ]]; then
  step "Signing doctor (Secure Enclave entitlement)"
  # PRODUCT_NAME is "Local Wallet", so the bundle is "Local Wallet.app" WITH A SPACE — a
  # 'LocalWallet*.app' glob never matches it and this reported "no built app" even when one
  # existed. Match on the DerivedData path instead, and pick the most recently built one:
  # stale DerivedData dirs accumulate, and reporting an old app's signature is worse than
  # reporting none. Sort on the built EXECUTABLE, not the .app directory — a rebuild rewrites
  # the binary but leaves the bundle directory's own mtime untouched, so ranking by the
  # directory silently prefers a months-old bundle.
  APP_BIN="$(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 9 -type f \
    -path '*/LocalWallet-*/Build/Products/Debug/*.app/Contents/MacOS/*' -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null | head -1)"
  APP="${APP_BIN%/Contents/MacOS/*}"
  if [[ -z "$APP" ]]; then
    echo "No built app found — build/run it in Xcode once, then re-run --doctor."
    exit 0
  fi
  # Print the path relative to ~ : DerivedData lives under $HOME, so the absolute path leaks
  # the account name into pasted output. The path is only here to identify WHICH build was
  # inspected, which the DerivedData hash already does.
  # The `~` MUST be escaped: unquoted, bash tilde-expands the replacement straight back to
  # $HOME, so the substitution silently becomes a no-op that looks correct in the source.
  echo "app: ${APP/#"$HOME"/\~}"
  echo "--- signature ---"
  # `Authority=Apple Development: <you>@example.com (CERTSERIAL)` carries the developer's
  # email address, and this output is meant to be pasted into an issue when onboarding fails.
  # The diagnostic only needs to know THAT a real Apple Development authority signed the app,
  # never whose account it was, so strip the address. The team id is deliberately left intact:
  # a real team prefix is the exact thing being checked, and it is public anyway (it ships in
  # every signed binary).
  codesign -dvv "$APP" 2>&1 | grep -iE "Authority|TeamIdentifier|flags" \
    | sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<redacted>/g' || true
  echo "--- entitlements (keychain-access-groups must show a real team prefix, not blank/'-') ---"
  codesign -d --entitlements :- "$APP" 2>/dev/null | grep -iA2 "keychain-access-groups" \
    || echo "!! no keychain-access-groups entitlement — the app is NOT signed with a real team;"
  echo
  echo "If TeamIdentifier is 'not set'/adhoc or the entitlement prefix is blank, the Secure"
  echo "Enclave call will fail. Fix in Xcode → LocalWalletApp → Signing & Capabilities:"
  echo "select YOUR Development Team (Automatic), then Clean Build + Run. Or re-run this"
  echo "script with DEVELOPMENT_TEAM=<your-team-id> to bake it into the generated project."
  exit 0
fi

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

step "3/4  Building the railgun sidecar (release: railgun-helper)"
# One binary now: railgun-helper exits through RAILGUN's privacy paymaster as an ERC-4337
# UserOperation submitted by a public bundler, so there is no broadcaster child to build,
# spawn, or fund — `--bins` still works, it just resolves to one target.
( cd "$REPO_ROOT/local-wallet-railgun" && cargo build --release --bins )

# The Xcode project is generated from project.yml and is not committed, and xcodegen bakes the
# app target's sources into it file-by-file — so switching branches desynchronizes it from the
# tree in both directions, each failing in a way that does not point at the real cause. All of
# that (drift detection, and carrying your signing team forward so a regen never orphans an
# existing wallet's Secure Enclave key) lives in one place; --regen forces a rebuild.
step "4/4  Syncing LocalWallet.xcodeproj with project.yml"
if [[ "$REGEN" == 1 ]]; then
  "$REPO_ROOT/scripts/generate-xcode-project.sh" --force
else
  "$REPO_ROOT/scripts/generate-xcode-project.sh"
fi
echo "note: diagnose signing problems with $0 --doctor"

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
  - The app resolves the sidecar from local-wallet-railgun/target/release and the daemon
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
