#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQUESTED_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ $# -gt 0 ]]; then
  if [[ $# -ne 2 || "$1" != "--repo-root" ]]; then
    echo "Usage: $0 [--repo-root PATH]" >&2
    exit 64
  fi
  REQUESTED_ROOT="$2"
fi

if [[ ! -d "${REQUESTED_ROOT}" ]]; then
  echo "Repository root does not exist: ${REQUESTED_ROOT}" >&2
  exit 1
fi

REPO_ROOT="$(cd "${REQUESTED_ROOT}" && pwd -P)"
SPEC_PATH="${REPO_ROOT}/project.yml"
CHECKED_PROJECT="${REPO_ROOT}/LocalWallet.xcodeproj/project.pbxproj"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required to verify LocalWallet.xcodeproj." >&2
  exit 1
fi
XCODEGEN_BIN="$(command -v xcodegen)"
CURRENT_USER="$(id -un)"

if ! command -v ruby >/dev/null 2>&1; then
  echo "ruby is required to inspect project.yml before running xcodegen." >&2
  exit 1
fi

for required_file in \
  "${SPEC_PATH}" \
  "${CHECKED_PROJECT}" \
  "${REPO_ROOT}/wallet-macos/App/Info.plist" \
  "${REPO_ROOT}/wallet-macos/App/LocalWallet.entitlements"; do
  if [[ ! -f "${required_file}" ]]; then
    echo "Missing required Xcode project input: ${required_file}" >&2
    exit 1
  fi
done

if ! ruby -rpsych -e '
  forbidden = %w[include preGenCommand postGenCommand]
  walk = lambda do |node|
    case node
    when Psych::Nodes::Mapping
      node.children.each_slice(2) do |key, value|
        abort("project.yml contains an unsupported complex mapping key") unless key.is_a?(Psych::Nodes::Scalar)
        abort("project.yml contains forbidden XcodeGen key: #{key.value}") if forbidden.include?(key.value)
        walk.call(value)
      end
    when Psych::Nodes::Alias
      abort("project.yml aliases are unsupported by the integrity verifier")
    else
      (node.children || []).each { |child| walk.call(child) } if node.respond_to?(:children)
    end
  end
  walk.call(Psych.parse_stream(File.read(ARGV.fetch(0))))
' "${SPEC_PATH}"; then
  echo "Refusing to run xcodegen with includes, generation hooks, aliases, or complex keys." >&2
  exit 1
fi

for required_directory in \
  local-llm \
  swift-bridge \
  wallet-macos/Sources/WalletMacOSApp \
  wallet-macos/App/Assets.xcassets; do
  if [[ ! -d "${REPO_ROOT}/${required_directory}" ]]; then
    echo "Missing required XcodeGen source root: ${REPO_ROOT}/${required_directory}" >&2
    exit 1
  fi
done

TMP_BASE="${TMPDIR:-/tmp}"
SCRATCH_ROOT="$(mktemp -d "${TMP_BASE%/}/local-wallet-xcode-project.XXXXXX")"
trap 'rm -rf "${SCRATCH_ROOT}"' EXIT

cp "${SPEC_PATH}" "${SCRATCH_ROOT}/project.yml"
mkdir -p \
  "${SCRATCH_ROOT}/snapshot/LocalWallet.xcodeproj" \
  "${SCRATCH_ROOT}/snapshot/wallet-macos/App" \
  "${SCRATCH_ROOT}/home" \
  "${SCRATCH_ROOT}/tmp"
cp "${SPEC_PATH}" "${SCRATCH_ROOT}/snapshot/project.yml"
cp "${CHECKED_PROJECT}" "${SCRATCH_ROOT}/snapshot/LocalWallet.xcodeproj/project.pbxproj"
cp \
  "${REPO_ROOT}/wallet-macos/App/Info.plist" \
  "${REPO_ROOT}/wallet-macos/App/LocalWallet.entitlements" \
  "${SCRATCH_ROOT}/snapshot/wallet-macos/App/"
mkdir -p \
  "${SCRATCH_ROOT}/local-llm" \
  "${SCRATCH_ROOT}/swift-bridge" \
  "${SCRATCH_ROOT}/wallet-macos/Sources" \
  "${SCRATCH_ROOT}/wallet-macos/App"
cp -R \
  "${REPO_ROOT}/wallet-macos/Sources/WalletMacOSApp" \
  "${SCRATCH_ROOT}/wallet-macos/Sources/WalletMacOSApp"
cp -R \
  "${REPO_ROOT}/wallet-macos/App/Assets.xcassets" \
  "${SCRATCH_ROOT}/wallet-macos/App/Assets.xcassets"
cp \
  "${REPO_ROOT}/wallet-macos/App/Info.plist" \
  "${REPO_ROOT}/wallet-macos/App/LocalWallet.entitlements" \
  "${SCRATCH_ROOT}/wallet-macos/App/"

set +e
(
  cd "${SCRATCH_ROOT}"
  env -i \
    HOME="${SCRATCH_ROOT}/home" \
    LANG=C \
    LOGNAME="${CURRENT_USER}" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    TMPDIR="${SCRATCH_ROOT}/tmp" \
    USER="${CURRENT_USER}" \
    "${XCODEGEN_BIN}" \
      --spec "${SCRATCH_ROOT}/project.yml" \
      --project-root "${SCRATCH_ROOT}" \
      --project "${SCRATCH_ROOT}" \
      --quiet
)
xcodegen_status=$?
set -e

assert_unchanged() {
  local current_path="$1"
  local snapshot_path="$2"
  if ! cmp -s "${current_path}" "${snapshot_path}"; then
    echo "XcodeGen verification modified canonical input: ${current_path}" >&2
    exit 1
  fi
}

assert_unchanged "${SPEC_PATH}" "${SCRATCH_ROOT}/snapshot/project.yml"
assert_unchanged "${CHECKED_PROJECT}" "${SCRATCH_ROOT}/snapshot/LocalWallet.xcodeproj/project.pbxproj"
assert_unchanged \
  "${REPO_ROOT}/wallet-macos/App/Info.plist" \
  "${SCRATCH_ROOT}/snapshot/wallet-macos/App/Info.plist"
assert_unchanged \
  "${REPO_ROOT}/wallet-macos/App/LocalWallet.entitlements" \
  "${SCRATCH_ROOT}/snapshot/wallet-macos/App/LocalWallet.entitlements"

if [[ ${xcodegen_status} -ne 0 ]]; then
  echo "xcodegen failed while generating the temporary verification project." >&2
  exit "${xcodegen_status}"
fi

GENERATED_PROJECT="${SCRATCH_ROOT}/LocalWallet.xcodeproj/project.pbxproj"
if [[ ! -f "${GENERATED_PROJECT}" ]]; then
  echo "xcodegen did not produce the expected project: ${GENERATED_PROJECT}" >&2
  exit 1
fi

CHECKED_PROJECT_SNAPSHOT="${SCRATCH_ROOT}/snapshot/LocalWallet.xcodeproj/project.pbxproj"
if ! cmp -s "${CHECKED_PROJECT_SNAPSHOT}" "${GENERATED_PROJECT}"; then
  echo "LocalWallet.xcodeproj has drifted from canonical project.yml." >&2
  echo "Run 'xcodegen generate', review the project diff, and commit both files together." >&2
  echo "First 200 lines of the generated-project diff:" >&2
  diff -u "${CHECKED_PROJECT_SNAPSHOT}" "${GENERATED_PROJECT}" | sed -n '1,200p' >&2 || true
  exit 1
fi

echo "Xcode project matches canonical project.yml."
