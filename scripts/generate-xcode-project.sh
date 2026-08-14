#!/bin/bash
set -euo pipefail

# Generates LocalWallet.xcodeproj from project.yml.
#
# The project is a build artifact and is NOT committed. xcodegen bakes the app
# target's sources into it file-by-file, so a checked-in copy goes stale the
# moment anyone adds a Swift file — and both directions of that drift fail in a
# way that does not point at the real cause:
#
#   file on disk, not in project  -> "Cannot find type <X> in scope" at a CALLER,
#                                    which reads like a code bug and sends you
#                                    hunting in a file that is perfectly fine
#   file in project, not on disk  -> "Build input file cannot be found"
#
# Only the app target lists files this way; the SwiftPM packages (swift-bridge /
# local-llm / wallet-macos) are resolved by Xcode and need no regeneration.
#
# Regenerating RESETS signing (team + bundle id) back to project.yml, which
# changes the Keychain/Secure-Enclave access group and ORPHANS an existing
# wallet's key ("Secure Enclave key reference is missing"). That is why this
# script is not a bare `xcodegen generate`: it regenerates only when the project
# is missing or has drifted, and it carries forward whatever team and bundle id
# the current project has. An explicit env override still wins.
#
# Usage:
#   scripts/generate-xcode-project.sh            # generate if missing/stale/drifted
#   scripts/generate-xcode-project.sh --force    # regenerate unconditionally
#
# Env:
#   LOCAL_WALLET_SKIP_XCODEGEN=1   skip entirely (Rust-only / CI-only work)
#   DEVELOPMENT_TEAM=XXXXXXXXXX    bake this signing team into the project
#   PRODUCT_BUNDLE_IDENTIFIER=...  bake this bundle id into the project

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PROJECT="LocalWallet.xcodeproj"
PBXPROJ="$PROJECT/project.pbxproj"
APP_SOURCES="wallet-macos/Sources/WalletMacOSApp"
DEFAULT_BUNDLE_ID="ai.ethereum.localwallet.demo"

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help) sed -n '3,36p' "$0"; exit 0 ;;
    *) echo "error: unknown argument '$arg'" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1;36m==>\033[0m %s\n' "$1"; }

if [[ "${LOCAL_WALLET_SKIP_XCODEGEN:-0}" == "1" ]]; then
  say "Skipping Xcode project generation (LOCAL_WALLET_SKIP_XCODEGEN=1)"
  exit 0
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: 'xcodegen' not found on PATH — install it with 'brew install xcodegen'." >&2
  echo "       $PROJECT is generated from project.yml and is not committed, so it" >&2
  echo "       cannot be built or opened until xcodegen has run." >&2
  exit 1
fi

# Returns 0 (and prints why) when the project must be regenerated.
project_needs_regeneration() {
  [[ -e "$PBXPROJ" ]] || { echo "$PROJECT does not exist yet"; return 0; }
  if [[ "project.yml" -nt "$PBXPROJ" ]]; then
    echo "project.yml is newer than the project"
    return 0
  fi
  local file name
  while IFS= read -r file; do
    name="$(basename "$file")"
    grep -qF "$name" "$PBXPROJ" || { echo "$name is not in the project"; return 0; }
  done < <(find "$APP_SOURCES" -type f -name '*.swift')
  while IFS= read -r name; do
    [[ -n "$(find "$APP_SOURCES" -type f -name "$name" -print -quit)" ]] \
      || { echo "$name is in the project but gone from the tree"; return 0; }
  done < <(grep -oE 'path = [A-Za-z0-9_+.-]+\.swift' "$PBXPROJ" | sed 's/path = //' | sort -u)
  return 1
}

if [[ -e "$PBXPROJ" ]]; then
  EXISTING_TEAM="$(grep -o 'DEVELOPMENT_TEAM = [A-Z0-9]*;' "$PBXPROJ" | head -1 | sed 's/.*= *//; s/;//')"
  EXISTING_BUNDLE_ID="$(grep -o 'PRODUCT_BUNDLE_IDENTIFIER = [A-Za-z0-9.-]*;' "$PBXPROJ" | head -1 | sed 's/.*= *//; s/;//')"
else
  EXISTING_TEAM=""
  EXISTING_BUNDLE_ID=""
fi
TEAM="${DEVELOPMENT_TEAM:-$EXISTING_TEAM}"
BUNDLE_ID="${PRODUCT_BUNDLE_IDENTIFIER:-$EXISTING_BUNDLE_ID}"

if [[ "$FORCE" == 1 ]]; then
  say "Regenerating $PROJECT (--force)"
elif reason="$(project_needs_regeneration)"; then
  say "Generating $PROJECT ($reason)"
else
  say "Keeping existing $PROJECT (in sync; --force to rebuild it)"
  exit 0
fi

xcodegen generate

# Restore signing after (re)generation: the Secure Enclave access group needs a
# REAL team you have an Xcode account for, and project.yml's is likely not yours.
if [[ -n "$TEAM" ]]; then
  if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    say "Applying DEVELOPMENT_TEAM=$TEAM to the generated project (local only)"
  else
    say "Preserving DEVELOPMENT_TEAM=$TEAM from the previous project (local only)"
  fi
  find "$PROJECT" -name project.pbxproj -exec \
    sed -i '' "s/DEVELOPMENT_TEAM = [A-Z0-9]*;/DEVELOPMENT_TEAM = ${TEAM};/g" {} +
  # Keep the bundle id stable too: it is half of the Keychain/SE access group.
  if [[ -n "$BUNDLE_ID" && "$BUNDLE_ID" != "$DEFAULT_BUNDLE_ID" ]]; then
    echo "  + PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID"
    find "$PROJECT" -name project.pbxproj -exec \
      sed -i '' "s/PRODUCT_BUNDLE_IDENTIFIER = ${DEFAULT_BUNDLE_ID};/PRODUCT_BUNDLE_IDENTIFIER = ${BUNDLE_ID};/g" {} +
  fi
else
  project_yml_team="$(grep -E 'DEVELOPMENT_TEAM' project.yml | head -1 | sed 's/.*: *//')"
  printf '\033[1;33mnote:\033[0m fresh project — signing team is "%s" (from project.yml). If that is\n' "$project_yml_team"
  echo "      not YOUR Apple Developer team, onboarding fails with a Secure Enclave error."
  echo "      Set your team ONCE in Xcode -> LocalWalletApp -> Signing & Capabilities (this"
  echo "      script carries it forward across regenerations), or re-run with"
  echo "      DEVELOPMENT_TEAM=<your-team-id>. Keep team + bundle id STABLE — changing"
  echo "      either orphans the Secure Enclave key of an existing wallet."
fi
