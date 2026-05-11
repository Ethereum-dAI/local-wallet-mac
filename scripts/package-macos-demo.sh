#!/bin/bash
set -euo pipefail

# TODO(post-split): This script does NOT embed the wallet-node daemon binary.
#
# Pre-split (monorepo era), the daemon was built in-tree at
# rust-core/target/<profile>/wallet-node and the running app fell back to
# that path. After the 2026-05-11 multi-repo split, the daemon lives at
# https://github.com/Ethereum-dAI/local-wallet-daemon and this script does
# NOT yet fetch or embed it into the .app bundle.
#
# A signed/notarized .app produced by this script today will fail at
# launch with AppError.localDaemonLaunchFailed unless the end user has
# set WALLET_NODE_BIN (or LOCAL_WALLET_NODE_BIN) to an external
# wallet-node binary on their machine.
#
# See OPEN-POINTS.md for the planned fix.

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

if [[ ! -d "$PROJECT" ]]; then
  echo "Missing LocalWallet.xcodeproj. Generate it from project.yml before packaging."
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

APP_PATH="$(find "$ARCHIVE_DIR/Build/Products/$CONFIGURATION" -maxdepth 1 -name "$APP_NAME" -type d | head -n 1)"
if [[ -z "$APP_PATH" ]]; then
  echo "Could not find built app at $ARCHIVE_DIR/Build/Products/$CONFIGURATION/$APP_NAME"
  exit 1
fi

echo "=== Copying app ==="
cp -R "$APP_PATH" "$PRODUCTS_DIR/"

if [[ -n "$BUNDLER_URL" ]]; then
  echo "=== Injecting Sepolia bundler URL into packaged app ==="
  /usr/libexec/PlistBuddy \
    -c "Delete :LocalWalletSepoliaBundlerURL" \
    "$PRODUCTS_DIR/$APP_NAME/Contents/Info.plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy \
    -c "Add :LocalWalletSepoliaBundlerURL string $BUNDLER_URL" \
    "$PRODUCTS_DIR/$APP_NAME/Contents/Info.plist"

  echo "=== Re-signing packaged app after Info.plist update ==="
  CODESIGN_DETAILS="$(codesign -d -vv "$APP_PATH" 2>&1)"
  SIGNING_IDENTITY="$(printf '%s\n' "$CODESIGN_DETAILS" | awk -F= '/Authority=/ { print $2; exit }')"
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "Could not determine signing identity from built app."
    exit 1
  fi

  ENTITLEMENTS_PLIST="$BUILD_DIR/packaged-entitlements.plist"
  codesign -d --entitlements :- "$APP_PATH" >"$ENTITLEMENTS_PLIST"
  plutil -lint "$ENTITLEMENTS_PLIST" >/dev/null
  codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS_PLIST" "$PRODUCTS_DIR/$APP_NAME"
else
  echo "=== No Sepolia bundler URL configured ==="
  echo "Set LOCAL_WALLET_SEPOLIA_BUNDLER_URL before packaging to enable hosted bundler submission in the release app."
fi

echo "=== Creating zip ==="
rm -f "$RELEASE_DIR/$ZIP_NAME"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --keepParent "$PRODUCTS_DIR/$APP_NAME" "$RELEASE_DIR/$ZIP_NAME"

echo "=== Package complete ==="
echo "App: $PRODUCTS_DIR/$APP_NAME"
echo "Zip: $RELEASE_DIR/$ZIP_NAME"
echo
echo "This demo build is not notarized. Testers may need to right-click Open or use System Settings > Privacy & Security > Open Anyway."
