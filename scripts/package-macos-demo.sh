#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO_ROOT/LocalWallet.xcodeproj"
SCHEME="LocalWalletApp"
CONFIGURATION="Release"
BUILD_DIR="$REPO_ROOT/build/macos-demo"
ARCHIVE_DIR="$BUILD_DIR/archive"
PRODUCTS_DIR="$BUILD_DIR/products"
RELEASE_DIR="$REPO_ROOT/dist"
APP_NAME="Local Wallet.app"
ZIP_NAME="${LOCAL_WALLET_ZIP_NAME:-LocalWallet-v0.1.0-alpha-macOS-AppleSilicon-no-LLM.zip}"
DEPLOYMENT_TARGET="${LOCAL_WALLET_DEPLOYMENT_TARGET:-15.0}"
NOTARIZE="${LOCAL_WALLET_NOTARIZE:-0}"
NOTARY_PROFILE="${LOCAL_WALLET_NOTARY_PROFILE:-}"
NOTARY_APPLE_ID="${LOCAL_WALLET_NOTARY_APPLE_ID:-}"
NOTARY_PASSWORD="${LOCAL_WALLET_NOTARY_PASSWORD:-}"
NOTARY_TEAM_ID="${LOCAL_WALLET_NOTARY_TEAM_ID:-}"
BUNDLER_URL="${LOCAL_WALLET_SEPOLIA_BUNDLER_URL:-}"
DAEMON_REPO="${LOCAL_WALLET_DAEMON_REPO:-$REPO_ROOT/local-wallet-daemon}"
EMBED_MODEL="${LOCAL_WALLET_EMBED_MODEL:-0}"
# Must stay the model `LocalAIModel.recommended` names: the app only looks in
# Contents/Resources/Models for the default model's own file name, so embedding
# any other GGUF ships a 5 GB file the app will ignore and then re-download.
MODEL_FILE_NAME="gemma-4-E4B-wallet-ft.Q4_K_M.gguf"
MODEL_SHA256="fdf5c30e86d83c0391bed5e005af85bd2af2eb1ef7455a64b9a463d4d8ced16b"
MODEL_SIZE_LABEL="5.34 GB"
MODEL_URL="${LOCAL_WALLET_MODEL_URL:-https://huggingface.co/ef-dai-team/gemma-4-E4B-wallet-ft/resolve/main/$MODEL_FILE_NAME?download=true}"
APP_SUPPORT_MODEL="$HOME/Library/Application Support/LocalWallet/Models/$MODEL_FILE_NAME"
MODEL_CACHE_DIR="${LOCAL_WALLET_MODEL_CACHE_DIR:-$REPO_ROOT/build/model-cache}"
NOTARYTOOL_AUTH_ARGS=()
LLAMA_PREFIX="${LOCAL_LLAMA_PREFIX:-}"
# Mirrors local-llm/Package.swift's resolution order, and like the manifest it has
# NO Homebrew fallback. The app is compiled against the pinned headers, so
# resolving an @rpath dependency to a Homebrew dylib would embed a different
# llama.cpp build than the code was compiled for -- and since the mangled C++
# symbol names do not change between these versions, that ships as silent runtime
# corruption rather than a load error. Neither new gate below would catch it: a
# libggml-metal*.dylib would be present, and the reference would be @rpath/... from
# inside Frameworks. Failing to find a dylib is the safer outcome.
LLAMA_SEARCH_DIRS=(
  "${LOCAL_LLAMA_LIB_DIR:-}"
  "${LLAMA_PREFIX:+$LLAMA_PREFIX/lib}"
  "$REPO_ROOT/.llama/current/lib"
)

if [[ ! -d "$PROJECT" ]]; then
  echo "Missing LocalWallet.xcodeproj. Generate it from project.yml before packaging."
  exit 1
fi

is_truthy() {
  case "$1" in
    1|true|TRUE|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

verify_model_checksum() {
  local file_path="$1"
  local actual_checksum
  actual_checksum="$(shasum -a 256 "$file_path" | awk '{ print $1 }')"
  if [[ "$actual_checksum" != "$MODEL_SHA256" ]]; then
    echo "Model checksum mismatch for $file_path"
    echo "Expected: $MODEL_SHA256"
    echo "Actual:   $actual_checksum"
    return 1
  fi
}

download_model() {
  local destination="$1"
  local tmp_file="$destination.download"
  mkdir -p "$(dirname "$destination")"
  rm -f "$tmp_file"
  echo "Downloading $MODEL_FILE_NAME from Hugging Face. This is about $MODEL_SIZE_LABEL."
  curl --fail --location --progress-bar --output "$tmp_file" "$MODEL_URL"
  mv "$tmp_file" "$destination"
}

resolve_model_file() {
  local model_path="${LOCAL_MODEL_PATH:-}"
  if [[ -n "$model_path" ]]; then
    if [[ ! -f "$model_path" ]]; then
      echo "LOCAL_MODEL_PATH does not point to a file: $model_path" >&2
      exit 1
    fi
    verify_model_checksum "$model_path" >&2
    printf '%s\n' "$model_path"
    return
  fi

  if [[ -f "$APP_SUPPORT_MODEL" ]]; then
    verify_model_checksum "$APP_SUPPORT_MODEL" >&2
    printf '%s\n' "$APP_SUPPORT_MODEL"
    return
  fi

  local cached_model="$MODEL_CACHE_DIR/$MODEL_FILE_NAME"
  if [[ -f "$cached_model" ]] && ! verify_model_checksum "$cached_model" >&2; then
    rm -f "$cached_model"
  fi
  if [[ ! -f "$cached_model" ]]; then
    download_model "$cached_model" >&2
  fi
  verify_model_checksum "$cached_model" >&2
  printf '%s\n' "$cached_model"
}

resolve_wallet_node_binary() {
  local wallet_node_bin="${LOCAL_WALLET_NODE_BIN:-${WALLET_NODE_BIN:-}}"
  if [[ -n "$wallet_node_bin" ]]; then
    if [[ ! -x "$wallet_node_bin" ]]; then
      echo "wallet-node is not executable: $wallet_node_bin" >&2
      exit 1
    fi
    printf '%s\n' "$wallet_node_bin"
    return
  fi

  if [[ ! -f "$DAEMON_REPO/Cargo.toml" ]]; then
    echo "Missing daemon checkout at $DAEMON_REPO" >&2
    echo "Set LOCAL_WALLET_DAEMON_REPO, LOCAL_WALLET_NODE_BIN, or WALLET_NODE_BIN." >&2
    exit 1
  fi

  echo "=== Building wallet-node daemon ===" >&2
  (
    cd "$DAEMON_REPO"
    export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
    cargo build -p wallet-node --release
  )

  wallet_node_bin="$DAEMON_REPO/target/release/wallet-node"
  if [[ ! -x "$wallet_node_bin" ]]; then
    echo "Could not find built wallet-node at $wallet_node_bin" >&2
    exit 1
  fi
  printf '%s\n' "$wallet_node_bin"
}

find_dylib() {
  local dylib_name="$1"
  local search_dir
  for search_dir in "${LLAMA_SEARCH_DIRS[@]}"; do
    if [[ -n "$search_dir" && -f "$search_dir/$dylib_name" ]]; then
      printf '%s\n' "$search_dir/$dylib_name"
      return
    fi
  done
  return 1
}

is_embeddable_llama_dependency() {
  local dependency="$1"
  case "$dependency" in
    @rpath/libllama*.dylib|@rpath/libggml*.dylib|/opt/homebrew/*/lib/libllama*.dylib|/opt/homebrew/*/lib/libggml*.dylib|/opt/homebrew/lib/libllama*.dylib|/opt/homebrew/lib/libggml*.dylib|*/lib/libllama*.dylib|*/lib/libggml*.dylib)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_mach_o_file() {
  local file_path="$1"
  local file_type
  file_type="$(file -b "$file_path")"
  [[ "$file_type" == *"Mach-O"* ]]
}

version_leq() {
  local left="$1"
  local right="$2"
  awk -v left="$left" -v right="$right" '
    BEGIN {
      split(left, l, ".")
      split(right, r, ".")
      for (i = 1; i <= 3; i++) {
        lv = (l[i] == "" ? 0 : l[i]) + 0
        rv = (r[i] == "" ? 0 : r[i]) + 0
        if (lv < rv) exit 0
        if (lv > rv) exit 1
      }
      exit 0
    }
  '
}

verify_mach_o_deployment_targets() {
  local app_path="$1"
  local max_target="$2"
  local failures=0
  local binary_path

  while IFS= read -r -d '' binary_path; do
    if ! is_mach_o_file "$binary_path"; then
      continue
    fi

    local min_os
    min_os="$(vtool -show-build "$binary_path" 2>/dev/null | awk '/minos / { print $2; exit }')"
    if [[ -z "$min_os" ]]; then
      continue
    fi
    if ! version_leq "$min_os" "$max_target"; then
      echo "Mach-O deployment target too new: $binary_path has minos $min_os, expected <= $max_target" >&2
      failures=1
    fi
  done < <(find "$app_path/Contents/MacOS" "$app_path/Contents/Frameworks" "$app_path/Contents/Resources/bin" -type f -print0 2>/dev/null || true)

  return $failures
}

copy_dylib_with_dependencies() {
  local source_path="$1"
  local frameworks_dir="$2"
  local dylib_name
  dylib_name="$(basename "$source_path")"
  local destination="$frameworks_dir/$dylib_name"

  if [[ ! -f "$destination" ]]; then
    cp "$source_path" "$destination"
    chmod 755 "$destination"
    install_name_tool -id "@rpath/$dylib_name" "$destination"
  fi

  while IFS= read -r dependency; do
    if ! is_embeddable_llama_dependency "$dependency"; then
      continue
    fi

    local dependency_name
    dependency_name="$(basename "$dependency")"
    if [[ -f "$frameworks_dir/$dependency_name" ]]; then
      continue
    fi

    local dependency_path="$dependency"
    if [[ "$dependency" == @rpath/* ]]; then
      dependency_path="$(find_dylib "$dependency_name" || true)"
    fi
    if [[ -z "$dependency_path" || ! -f "$dependency_path" ]]; then
      echo "Missing llama.cpp dependency: $dependency_name" >&2
      exit 1
    fi
    copy_dylib_with_dependencies "$dependency_path" "$frameworks_dir"
  done < <(otool -L "$destination" | awk 'NR > 1 { print $1 }')
}

patch_binary_llama_dependencies() {
  local binary_path="$1"
  local frameworks_dir="$2"

  if ! is_mach_o_file "$binary_path"; then
    return
  fi

  # local-llm/Package.swift links with `-rpath <repo>/.llama/current/lib` so the
  # pinned @rpath dylibs resolve during local development. That absolute path must
  # not survive into a shipped binary: it leaks the packaging machine's home
  # directory, and because -add_rpath appends, it would be searched BEFORE
  # @executable_path/../Frameworks. On the packaging machine that path exists, so a
  # dylib missing from Frameworks would still resolve locally and pass QA and both
  # embed gates -- then fail at launch on a user's Mac. Neither gate inspects
  # LC_RPATH, so strip it here.
  while IFS= read -r stale_rpath; do
    install_name_tool -delete_rpath "$stale_rpath" "$binary_path" >/dev/null 2>&1 || true
  done < <(otool -l "$binary_path" | awk '/LC_RPATH/{f=1} f && /path /{print $2; f=0}' | grep '/\.llama/' || true)

  install_name_tool -add_rpath "@executable_path/../Frameworks" "$binary_path" >/dev/null 2>&1 || true

  while IFS= read -r dependency; do
    if ! is_embeddable_llama_dependency "$dependency"; then
      continue
    fi

    local dependency_name
    dependency_name="$(basename "$dependency")"
    if [[ ! -f "$frameworks_dir/$dependency_name" ]]; then
      local dependency_path="$dependency"
      if [[ "$dependency" == @rpath/* ]]; then
        dependency_path="$(find_dylib "$dependency_name" || true)"
      fi
      if [[ -z "$dependency_path" || ! -f "$dependency_path" ]]; then
        echo "Missing llama.cpp dependency: $dependency_name" >&2
        exit 1
      fi
      copy_dylib_with_dependencies "$dependency_path" "$frameworks_dir"
    fi
    install_name_tool -change "$dependency" "@rpath/$dependency_name" "$binary_path" >/dev/null 2>&1
  done < <(otool -L "$binary_path" | awk 'NR > 1 { print $1 }')
}

embed_llama_dylibs() {
  local app_path="$1"
  local frameworks_dir="$app_path/Contents/Frameworks"
  mkdir -p "$frameworks_dir"

  local binary_path
  local pass
  for pass in 1 2; do
    while IFS= read -r -d '' binary_path; do
      patch_binary_llama_dependencies "$binary_path" "$frameworks_dir"
    done < <(find "$app_path/Contents/MacOS" "$frameworks_dir" -type f -print0)
  done

  while IFS= read -r -d '' binary_path; do
    patch_binary_llama_dependencies "$binary_path" "$frameworks_dir"
  done < <(find "$frameworks_dir" -type f -print0)

  verify_ggml_backends_embedded "$frameworks_dir"
  verify_no_developer_rpaths "$app_path"
  verify_no_external_llama_dependencies "$app_path"
}

# No shipped binary may keep an LC_RPATH into the build machine's .llama prefix.
# Such a path both leaks a developer home directory and, being searched before
# @executable_path/../Frameworks, hides a dylib missing from the bundle for as long
# as packaging happens on the machine that has the prefix.
verify_no_developer_rpaths() {
  local app_path="$1"
  local failures=0
  local binary_path

  while IFS= read -r -d '' binary_path; do
    if ! is_mach_o_file "$binary_path"; then
      continue
    fi
    local leaked
    leaked="$(otool -l "$binary_path" | awk '/LC_RPATH/{f=1} f && /path /{print $2; f=0}' | grep '/\.llama/' || true)"
    if [[ -n "$leaked" ]]; then
      echo "Build-machine rpath left in $binary_path:" >&2
      printf '%s\n' "$leaked" >&2
      failures=1
    fi
  done < <(find "$app_path/Contents/MacOS" "$app_path/Contents/Frameworks" -type f -print0)

  return $failures
}

# ggml has no built-in CPU fallback: with no compute backend registered, every
# model load fails with "Failed to load llama.cpp model" and inference has
# nothing to run on. The recursive walker above picks the backends up on its own
# because the pinned upstream release links them as ordinary @rpath dylibs, so
# this is an assertion rather than a fixup -- but it is the assertion that would
# have caught shipping an app with no backends at all, which is what a Homebrew
# ggml produces (there the backends are dlopen'd plugins under libexec/, invisible
# to the Mach-O dependency graph and never copied in).
verify_ggml_backends_embedded() {
  local frameworks_dir="$1"
  local backend
  local missing=0

  for backend in libggml-base libggml-cpu libggml-metal; do
    if ! compgen -G "$frameworks_dir/$backend*.dylib" >/dev/null; then
      echo "No $backend dylib was embedded into Contents/Frameworks." >&2
      missing=1
    fi
  done

  if [[ "$missing" -ne 0 ]]; then
    echo "The packaged app would have no ggml compute backend and could not run inference." >&2
    echo "Check that the llama.cpp prefix in use ships its backends as linked dylibs" >&2
    echo "under lib/ (the pinned upstream release does; Homebrew's ggml does not)." >&2
    exit 1
  fi
}

verify_no_external_llama_dependencies() {
  local app_path="$1"
  local failures=0
  local binary_path

  while IFS= read -r -d '' binary_path; do
    if ! is_mach_o_file "$binary_path"; then
      continue
    fi

    # Also covers the transitive libraries a Homebrew-built llama.cpp drags in
    # (libomp via libggml-base, libssl/libcrypto via libllama-common). Those are
    # absent from the pinned upstream release, but if one is ever reintroduced it
    # must fail here rather than on an end user's Mac that has no Homebrew.
    local external_refs
    external_refs="$(otool -L "$binary_path" | awk '
      NR > 1 {
        path = $1
        if (path !~ /^\//) next
        if (path ~ /^\/usr\/lib\//) next
        if (path ~ /^\/System\//) next
        if (path ~ /lib(llama|ggml|omp|ssl|crypto)/) print path
      }
    ')"
    if [[ -n "$external_refs" ]]; then
      echo "External llama.cpp dependencies remain in $binary_path:" >&2
      printf '%s\n' "$external_refs" >&2
      failures=1
    fi
  done < <(find "$app_path/Contents/MacOS" "$app_path/Contents/Frameworks" -type f -print0)

  return $failures
}

verify_secure_enclave_entitlements() {
  local app_path="$1"
  local entitlements_plist="$BUILD_DIR/final-entitlements.plist"
  local application_identifier=""
  local team_identifier=""

  rm -f "$entitlements_plist"
  if ! codesign -d --entitlements :- "$app_path" >"$entitlements_plist" 2>/dev/null || ! plutil -lint "$entitlements_plist" >/dev/null 2>&1; then
    echo "Could not read valid entitlements from packaged app." >&2
    echo "Secure Enclave key creation requires a signed app with an application identifier entitlement." >&2
    exit 1
  fi

  application_identifier="$(/usr/libexec/PlistBuddy -c "Print :com.apple.application-identifier" "$entitlements_plist" 2>/dev/null || true)"
  if [[ -z "$application_identifier" ]]; then
    application_identifier="$(/usr/libexec/PlistBuddy -c "Print :application-identifier" "$entitlements_plist" 2>/dev/null || true)"
  fi
  team_identifier="$(/usr/libexec/PlistBuddy -c "Print :com.apple.developer.team-identifier" "$entitlements_plist" 2>/dev/null || true)"

  if [[ -z "$application_identifier" ]]; then
    echo "Packaged app is missing the application identifier entitlement required by Secure Enclave/Keychain." >&2
    echo "Do not distribute an ad-hoc re-signed build for wallet testing. Build with an Apple Development or Developer ID Application identity." >&2
    exit 1
  fi

  echo "Secure Enclave entitlement check passed: $application_identifier"
  if [[ -n "$team_identifier" ]]; then
    echo "Team identifier: $team_identifier"
  fi
}

sign_packaged_app() {
  local source_app="$1"
  local packaged_app="$2"
  local signing_identity="${CODESIGN_IDENTITY:-}"
  local entitlements_plist="$BUILD_DIR/packaged-entitlements.plist"
  local codesign_args=(--force)
  local nested_codesign_args=(--force)

  if [[ -z "$signing_identity" ]]; then
    if is_truthy "$NOTARIZE"; then
      signing_identity="$(security find-identity -v -p codesigning 2>/dev/null | awk -F\" '/Developer ID Application/ { print $2; exit }' || true)"
    else
      local codesign_details
      codesign_details="$(codesign -d -vv "$source_app" 2>&1 || true)"
      signing_identity="$(printf '%s\n' "$codesign_details" | awk -F= '/Authority=/ && !found { print $2; found = 1 }')"
    fi
  fi
  if [[ -z "$signing_identity" ]]; then
    if is_truthy "$NOTARIZE"; then
      echo "LOCAL_WALLET_NOTARIZE=1 requires a Developer ID Application certificate." >&2
      echo "Install the certificate or set CODESIGN_IDENTITY explicitly." >&2
      exit 1
    else
      echo "Could not determine signing identity from built app. Falling back to ad-hoc signing."
      signing_identity="-"
    fi
  fi

  if is_truthy "$NOTARIZE" && [[ "$signing_identity" != Developer\ ID\ Application:* ]]; then
    echo "LOCAL_WALLET_NOTARIZE=1 requires CODESIGN_IDENTITY to be a Developer ID Application certificate." >&2
    echo "Resolved identity: $signing_identity" >&2
    exit 1
  fi

  if [[ "$signing_identity" == Developer\ ID\ Application:* ]]; then
    codesign_args+=(--timestamp)
    nested_codesign_args+=(--timestamp)
  fi
  codesign_args+=(--options runtime --sign "$signing_identity")
  nested_codesign_args+=(--options runtime --sign "$signing_identity")

  rm -f "$entitlements_plist"
  if codesign -d --entitlements :- "$source_app" >"$entitlements_plist" 2>/dev/null && plutil -lint "$entitlements_plist" >/dev/null 2>&1; then
    true
  else
    rm -f "$entitlements_plist"
  fi

  while IFS= read -r -d '' mach_o_file; do
    if is_mach_o_file "$mach_o_file"; then
      codesign "${nested_codesign_args[@]}" "$mach_o_file"
    fi
  done < <(find "$packaged_app/Contents/Frameworks" "$packaged_app/Contents/Resources/bin" -type f -print0 2>/dev/null || true)

  if [[ -f "$entitlements_plist" ]]; then
    codesign "${codesign_args[@]}" --entitlements "$entitlements_plist" "$packaged_app"
  else
    codesign "${codesign_args[@]}" "$packaged_app"
  fi

  codesign --verify --deep --strict --verbose=2 "$packaged_app"
  codesign -dvv "$packaged_app" 2>&1 | grep -E "Authority=|TeamIdentifier=|Runtime Version|flags=" || true
  verify_secure_enclave_entitlements "$packaged_app"
}

create_release_zip() {
  local app_path="$1"
  local zip_path="$2"

  rm -f "$zip_path"
  COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --keepParent "$app_path" "$zip_path"
}

build_notarytool_auth_args() {
  NOTARYTOOL_AUTH_ARGS=()

  if [[ -n "$NOTARY_PROFILE" ]]; then
    NOTARYTOOL_AUTH_ARGS=(--keychain-profile "$NOTARY_PROFILE")
    return
  fi

  if [[ -z "$NOTARY_APPLE_ID" || -z "$NOTARY_PASSWORD" || -z "$NOTARY_TEAM_ID" ]]; then
    echo "Notarization requires LOCAL_WALLET_NOTARY_PROFILE or all of:" >&2
    echo "LOCAL_WALLET_NOTARY_APPLE_ID, LOCAL_WALLET_NOTARY_PASSWORD, LOCAL_WALLET_NOTARY_TEAM_ID" >&2
    exit 1
  fi

  NOTARYTOOL_AUTH_ARGS=(
    --apple-id "$NOTARY_APPLE_ID"
    --password "$NOTARY_PASSWORD"
    --team-id "$NOTARY_TEAM_ID"
  )
}

notarize_packaged_app() {
  local app_path="$1"
  local notary_zip="$BUILD_DIR/notary-upload.zip"

  if ! is_truthy "$NOTARIZE"; then
    return
  fi

  echo "=== Creating notarization upload zip ==="
  create_release_zip "$app_path" "$notary_zip"

  build_notarytool_auth_args

  echo "=== Submitting app for notarization ==="
  xcrun notarytool submit "$notary_zip" "${NOTARYTOOL_AUTH_ARGS[@]}" --wait

  echo "=== Stapling notarization ticket ==="
  xcrun stapler staple "$app_path"
  xcrun stapler validate "$app_path"
  spctl --assess --type execute --verbose=2 "$app_path"
}

echo "=== Resolving embedded assets ==="
WALLET_NODE_BIN_PATH="$(resolve_wallet_node_binary)"
MODEL_PATH=""
if [[ "$EMBED_MODEL" == "1" || "$EMBED_MODEL" == "true" || "$EMBED_MODEL" == "yes" ]]; then
  MODEL_PATH="$(resolve_model_file)"
elif [[ "$EMBED_MODEL" == "0" || "$EMBED_MODEL" == "false" || "$EMBED_MODEL" == "no" ]]; then
  echo "=== Model embedding disabled; setup will install the model on first run ==="
else
  echo "LOCAL_WALLET_EMBED_MODEL must be 1/true/yes or 0/false/no."
  exit 1
fi

echo "=== Building Rust FFI bridge ==="
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
"$REPO_ROOT/scripts/build-ffi.sh"

echo "=== Cleaning package output ==="
rm -rf "$BUILD_DIR"
mkdir -p "$PRODUCTS_DIR" "$RELEASE_DIR"

echo "=== Building $APP_NAME ($CONFIGURATION) ==="
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$ARCHIVE_DIR" \
  CODE_SIGN_STYLE=Automatic \
  MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  ARCHS=arm64 \
  EXCLUDED_ARCHS=x86_64 \
  build

APP_PATH="$(find "$ARCHIVE_DIR/Build/Products/$CONFIGURATION" -maxdepth 1 -name "$APP_NAME" -type d -print -quit)"
if [[ -z "$APP_PATH" ]]; then
  echo "Could not find built app at $ARCHIVE_DIR/Build/Products/$CONFIGURATION/$APP_NAME"
  exit 1
fi

echo "=== Copying app ==="
cp -R "$APP_PATH" "$PRODUCTS_DIR/"
PACKAGED_APP="$PRODUCTS_DIR/$APP_NAME"

echo "=== Embedding wallet-node daemon ==="
mkdir -p "$PACKAGED_APP/Contents/Resources/bin"
cp "$WALLET_NODE_BIN_PATH" "$PACKAGED_APP/Contents/Resources/bin/wallet-node"
chmod 755 "$PACKAGED_APP/Contents/Resources/bin/wallet-node"

if [[ -n "$MODEL_PATH" ]]; then
  echo "=== Embedding local AI model ==="
  mkdir -p "$PACKAGED_APP/Contents/Resources/Models"
  cp "$MODEL_PATH" "$PACKAGED_APP/Contents/Resources/Models/$MODEL_FILE_NAME"
else
  echo "=== Skipping local AI model embedding ==="
fi

echo "=== Embedding llama.cpp dynamic libraries ==="
embed_llama_dylibs "$PACKAGED_APP"

if [[ -n "$BUNDLER_URL" ]]; then
  echo "=== Injecting Sepolia bundler URL into packaged app ==="
  /usr/libexec/PlistBuddy \
    -c "Delete :LocalWalletSepoliaBundlerURL" \
    "$PACKAGED_APP/Contents/Info.plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy \
    -c "Add :LocalWalletSepoliaBundlerURL string $BUNDLER_URL" \
    "$PACKAGED_APP/Contents/Info.plist"
else
  echo "=== No Sepolia bundler URL configured ==="
  echo "Set LOCAL_WALLET_SEPOLIA_BUNDLER_URL before packaging to enable hosted bundler submission in the release app."
fi

echo "=== Re-signing packaged app ==="
sign_packaged_app "$APP_PATH" "$PACKAGED_APP"

echo "=== Verifying Mach-O deployment targets (<= macOS $DEPLOYMENT_TARGET) ==="
verify_mach_o_deployment_targets "$PACKAGED_APP" "$DEPLOYMENT_TARGET"

notarize_packaged_app "$PACKAGED_APP"

echo "=== Creating zip ==="
create_release_zip "$PACKAGED_APP" "$RELEASE_DIR/$ZIP_NAME"

echo "=== Package complete ==="
echo "App: $PACKAGED_APP"
echo "Zip: $RELEASE_DIR/$ZIP_NAME"
echo
if is_truthy "$NOTARIZE"; then
  echo "This build is signed with Developer ID, notarized, and stapled."
else
  echo "This demo build is not notarized. Set LOCAL_WALLET_NOTARIZE=1 and sign with Developer ID before sharing outside your own Mac."
fi
