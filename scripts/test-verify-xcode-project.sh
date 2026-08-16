#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERIFIER="${SCRIPT_DIR}/verify-xcode-project.sh"

if [[ ! -x "${VERIFIER}" ]]; then
  echo "Missing executable verifier: ${VERIFIER}" >&2
  exit 1
fi

TMP_BASE="${TMPDIR:-/tmp}"
FIXTURE_ROOT="$(mktemp -d "${TMP_BASE%/}/local-wallet-xcode-project-test.XXXXXX")"
trap 'rm -rf "${FIXTURE_ROOT}"' EXIT

cp "${REPO_ROOT}/project.yml" "${FIXTURE_ROOT}/project.yml"
mkdir -p "${FIXTURE_ROOT}/LocalWallet.xcodeproj"
cp \
  "${REPO_ROOT}/LocalWallet.xcodeproj/project.pbxproj" \
  "${FIXTURE_ROOT}/LocalWallet.xcodeproj/project.pbxproj"

mkdir -p \
  "${FIXTURE_ROOT}/local-llm" \
  "${FIXTURE_ROOT}/swift-bridge" \
  "${FIXTURE_ROOT}/wallet-macos/Sources" \
  "${FIXTURE_ROOT}/wallet-macos/App"
cp -R \
  "${REPO_ROOT}/wallet-macos/Sources/WalletMacOSApp" \
  "${FIXTURE_ROOT}/wallet-macos/Sources/WalletMacOSApp"
cp -R \
  "${REPO_ROOT}/wallet-macos/App/Assets.xcassets" \
  "${FIXTURE_ROOT}/wallet-macos/App/Assets.xcassets"
cp \
  "${REPO_ROOT}/wallet-macos/App/Info.plist" \
  "${REPO_ROOT}/wallet-macos/App/LocalWallet.entitlements" \
  "${FIXTURE_ROOT}/wallet-macos/App/"

fixture_checksum() {
  shasum -a 256 \
    "${FIXTURE_ROOT}/LocalWallet.xcodeproj/project.pbxproj" \
    "${FIXTURE_ROOT}/project.yml" \
    "${FIXTURE_ROOT}/wallet-macos/App/Info.plist" \
    "${FIXTURE_ROOT}/wallet-macos/App/LocalWallet.entitlements" \
    | shasum -a 256 \
    | awk '{ print $1 }'
}

fixture_checksum_before="$(fixture_checksum)"

"${VERIFIER}" --repo-root "${FIXTURE_ROOT}"

fixture_checksum_after="$(fixture_checksum)"
if [[ "${fixture_checksum_after}" != "${fixture_checksum_before}" ]]; then
  echo "Verifier mutated the checked project or plist while validating the canonical fixture." >&2
  exit 1
fi

perl -0pi -e \
  's#options:\n#options:\n  postGenCommand: "touch HOOK_MARKER"\n#' \
  "${FIXTURE_ROOT}/project.yml"
perl -0pi -e \
  "s#HOOK_MARKER#${FIXTURE_ROOT}/hook-ran#" \
  "${FIXTURE_ROOT}/project.yml"

fixture_checksum_before_hook="$(fixture_checksum)"
if "${VERIFIER}" --repo-root "${FIXTURE_ROOT}" >/dev/null 2>&1; then
  echo "Verifier accepted a project.yml generation hook." >&2
  exit 1
fi
if [[ -e "${FIXTURE_ROOT}/hook-ran" ]]; then
  echo "Verifier executed a project.yml generation hook." >&2
  exit 1
fi
fixture_checksum_after_hook="$(fixture_checksum)"
if [[ "${fixture_checksum_after_hook}" != "${fixture_checksum_before_hook}" ]]; then
  echo "Verifier mutated canonical inputs while rejecting a generation hook." >&2
  exit 1
fi

cp "${REPO_ROOT}/project.yml" "${FIXTURE_ROOT}/project.yml"
printf '\ninclude: Included.yml\n' >> "${FIXTURE_ROOT}/project.yml"
printf 'options:\n  postGenCommand: "touch %s"\n' \
  "${FIXTURE_ROOT}/included-hook-ran" \
  > "${FIXTURE_ROOT}/Included.yml"

fixture_checksum_before_include="$(fixture_checksum)"
include_file_checksum_before="$(shasum -a 256 "${FIXTURE_ROOT}/Included.yml" | awk '{ print $1 }')"
if "${VERIFIER}" --repo-root "${FIXTURE_ROOT}" >/dev/null 2>&1; then
  echo "Verifier accepted an XcodeGen include file." >&2
  exit 1
fi
if [[ -e "${FIXTURE_ROOT}/included-hook-ran" ]]; then
  echo "Verifier executed a generation hook from an include file." >&2
  exit 1
fi
fixture_checksum_after_include="$(fixture_checksum)"
if [[ "${fixture_checksum_after_include}" != "${fixture_checksum_before_include}" ]]; then
  echo "Verifier mutated canonical inputs while rejecting an include file." >&2
  exit 1
fi
include_file_checksum_after="$(shasum -a 256 "${FIXTURE_ROOT}/Included.yml" | awk '{ print $1 }')"
if [[ "${include_file_checksum_after}" != "${include_file_checksum_before}" ]]; then
  echo "Verifier mutated a rejected XcodeGen include file." >&2
  exit 1
fi

cp "${REPO_ROOT}/project.yml" "${FIXTURE_ROOT}/project.yml"
perl -0pi -e \
  's#CODE_SIGN_ENTITLEMENTS: wallet-macos/App/LocalWallet\.entitlements#CODE_SIGN_ENTITLEMENTS: wallet-macos/App/Drifted.entitlements#' \
  "${FIXTURE_ROOT}/project.yml"

fixture_checksum_before_drift="$(fixture_checksum)"
if "${VERIFIER}" --repo-root "${FIXTURE_ROOT}" >/dev/null 2>&1; then
  echo "Verifier accepted a project that drifted from project.yml." >&2
  exit 1
fi

fixture_checksum_after_drift="$(fixture_checksum)"
if [[ "${fixture_checksum_after_drift}" != "${fixture_checksum_before_drift}" ]]; then
  echo "Verifier mutated the checked project or plist while rejecting drift." >&2
  exit 1
fi

echo "Xcode project integrity regression test passed."
