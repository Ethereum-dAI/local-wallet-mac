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
ZIP_NAME="LocalWallet-Demo-macOS-AppleSilicon.zip"
BUNDLER_URL="${LOCAL_WALLET_SEPOLIA_BUNDLER_URL:-}"
DAEMON_REPO="${LOCAL_WALLET_DAEMON_REPO:-$REPO_ROOT/../local-wallet-daemon}"
EMBED_MODEL="${LOCAL_WALLET_EMBED_MODEL:-1}"
MODEL_FILE_NAME="gemma-4-E4B-it-Q4_K_M.gguf"
MODEL_SHA256="90ce98129eb3e8cc57e62433d500c97c624b1e3af1fcc85dd3b55ad7e0313e9f"
MODEL_URL="${LOCAL_WALLET_MODEL_URL:-https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF/resolve/main/$MODEL_FILE_NAME?download=true}"
APP_SUPPORT_MODEL="$HOME/Library/Application Support/LocalWallet/Models/$MODEL_FILE_NAME"
MODEL_CACHE_DIR="${LOCAL_WALLET_MODEL_CACHE_DIR:-$REPO_ROOT/build/model-cache}"
LLAMA_SEARCH_DIRS=(
  "${LOCAL_LLAMA_LIB_DIR:-}"
  "/opt/homebrew/opt/llama.cpp/lib"
  "/opt/homebrew/opt/ggml/lib"
  "/opt/homebrew/lib"
)

if [[ ! -d "$PROJECT" ]]; then
  echo "Missing LocalWallet.xcodeproj. Generate it from project.yml before packaging."
  exit 1
fi

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
  echo "Downloading $MODEL_FILE_NAME from Hugging Face. This is about 5.34 GB."
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
    /opt/homebrew/*/lib/libllama*.dylib|/opt/homebrew/*/lib/libggml*.dylib|/opt/homebrew/lib/libllama*.dylib|/opt/homebrew/lib/libggml*.dylib|@rpath/libllama*.dylib|@rpath/libggml*.dylib)
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

  verify_no_external_llama_dependencies "$app_path"
}

verify_no_external_llama_dependencies() {
  local app_path="$1"
  local failures=0
  local binary_path

  while IFS= read -r -d '' binary_path; do
    if ! is_mach_o_file "$binary_path"; then
      continue
    fi

    local external_refs
    external_refs="$(otool -L "$binary_path" | awk 'NR > 1 && $1 ~ /^\/opt\/homebrew\/.*\/lib\/lib(llama|ggml).*\.dylib$/ { print $1 }')"
    if [[ -n "$external_refs" ]]; then
      echo "External llama.cpp dependencies remain in $binary_path:" >&2
      printf '%s\n' "$external_refs" >&2
      failures=1
    fi
  done < <(find "$app_path/Contents/MacOS" "$app_path/Contents/Frameworks" -type f -print0)

  return $failures
}

sign_packaged_app() {
  local source_app="$1"
  local packaged_app="$2"
  local signing_identity="${CODESIGN_IDENTITY:-}"
  local entitlements_plist="$BUILD_DIR/packaged-entitlements.plist"

  if [[ -z "$signing_identity" ]]; then
    local codesign_details
    codesign_details="$(codesign -d -vv "$source_app" 2>&1 || true)"
    signing_identity="$(printf '%s\n' "$codesign_details" | awk -F= '/Authority=/ && !found { print $2; found = 1 }')"
  fi
  if [[ -z "$signing_identity" ]]; then
    echo "Could not determine signing identity from built app. Falling back to ad-hoc signing."
    signing_identity="-"
  fi

  rm -f "$entitlements_plist"
  if codesign -d --entitlements :- "$source_app" >"$entitlements_plist" 2>/dev/null && plutil -lint "$entitlements_plist" >/dev/null 2>&1; then
    true
  else
    rm -f "$entitlements_plist"
  fi

  while IFS= read -r -d '' mach_o_file; do
    if is_mach_o_file "$mach_o_file"; then
      codesign --force --sign "$signing_identity" "$mach_o_file"
    fi
  done < <(find "$packaged_app/Contents/Frameworks" "$packaged_app/Contents/Resources/bin" -type f -print0 2>/dev/null || true)

  if [[ -f "$entitlements_plist" ]]; then
    codesign --force --deep --options runtime --sign "$signing_identity" --entitlements "$entitlements_plist" "$packaged_app"
  else
    codesign --force --deep --options runtime --sign "$signing_identity" "$packaged_app"
  fi
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

echo "=== Creating zip ==="
rm -f "$RELEASE_DIR/$ZIP_NAME"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --keepParent "$PACKAGED_APP" "$RELEASE_DIR/$ZIP_NAME"

echo "=== Package complete ==="
echo "App: $PACKAGED_APP"
echo "Zip: $RELEASE_DIR/$ZIP_NAME"
echo
echo "This demo build is not notarized. Testers may need to right-click Open or use System Settings > Privacy & Security > Open Anyway."
