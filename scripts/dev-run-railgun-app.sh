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
#   scripts/dev-run-railgun-app.sh --doctor     # diagnose a Secure Enclave / signing error
#   scripts/dev-run-railgun-app.sh --regen      # force-regenerate the Xcode project
#                                               #   (resets signing to project.yml — only
#                                               #   when you really want a clean project)
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
  APP="$(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 5 -name 'LocalWallet*.app' -path '*Debug*' 2>/dev/null | head -1)"
  if [[ -z "$APP" ]]; then
    echo "No built app found — build/run it in Xcode once, then re-run --doctor."
    exit 0
  fi
  echo "app: $APP"
  echo "--- signature ---"
  codesign -dvv "$APP" 2>&1 | grep -iE "Authority|TeamIdentifier|flags" || true
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

step "3/4  Building the railgun sidecars (release: railgun-helper + railgun-broadcaster)"
( cd "$REPO_ROOT/local-wallet-railgun" && cargo build --release --bins )

# Regenerating the project RESETS signing (team + bundle id) back to project.yml, which
# changes the Keychain/Secure-Enclave access group and ORPHANS an existing wallet's key
# ("Secure Enclave key reference is missing"). So only generate when the project is missing
# or --regen is passed — otherwise keep your existing project + whatever team you set in
# Xcode's Signing UI.
if [[ ! -e LocalWallet.xcodeproj || "$REGEN" == 1 ]]; then
  step "4/4  Generating LocalWallet.xcodeproj (xcodegen)"
  xcodegen generate
  REGENERATED=1
else
  step "4/4  Keeping existing LocalWallet.xcodeproj (signing preserved; --regen to rebuild it)"
  REGENERATED=0
fi

# On (re)generation only, bake in a signing override if provided; the SE access group needs
# a REAL team you have an Xcode account for, and the committed one likely isn't yours.
if [[ "$REGENERATED" == 1 && -n "${DEVELOPMENT_TEAM:-}" ]]; then
  step "Applying DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM to the generated project (local only)"
  find LocalWallet.xcodeproj -name project.pbxproj -exec \
    sed -i '' "s/DEVELOPMENT_TEAM = [A-Z0-9]*;/DEVELOPMENT_TEAM = ${DEVELOPMENT_TEAM};/g" {} +
  # If the committed bundle id is already claimed by another team, set your own here too.
  if [[ -n "${PRODUCT_BUNDLE_IDENTIFIER:-}" ]]; then
    echo "  + PRODUCT_BUNDLE_IDENTIFIER=$PRODUCT_BUNDLE_IDENTIFIER (changes the Keychain/SE access group ⇒ fresh wallet)"
    find LocalWallet.xcodeproj -name project.pbxproj -exec \
      sed -i '' "s/PRODUCT_BUNDLE_IDENTIFIER = ai.ethereum.localwallet.demo;/PRODUCT_BUNDLE_IDENTIFIER = ${PRODUCT_BUNDLE_IDENTIFIER};/g" {} +
  fi
elif [[ "$REGENERATED" == 1 ]]; then
  committed_team="$(grep -E 'DEVELOPMENT_TEAM' project.yml | head -1 | sed 's/.*: *//')"
  printf '\033[1;33mnote:\033[0m fresh project — signing team is "%s" (from project.yml). If that is\n' "$committed_team"
  echo "      not YOUR Apple Developer team, onboarding fails with a Secure Enclave error."
  echo "      Set your team ONCE in Xcode → LocalWalletApp → Signing & Capabilities (then just"
  echo "      re-run this script WITHOUT --regen so it won't reset it), or re-run with"
  echo "      DEVELOPMENT_TEAM=<your-team-id> --regen. Keep team + bundle id STABLE — changing"
  echo "      either orphans the Secure Enclave key of an existing wallet. Diagnose: $0 --doctor"
fi

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
