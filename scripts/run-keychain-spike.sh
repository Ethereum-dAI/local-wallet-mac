#!/usr/bin/env bash
set -euo pipefail

# User-provided team ID. Find via: security find-identity -v -p codesigning
# (the 10-char alphanumeric in parens at the end of the cert name).
if [[ -z "${DEVELOPER_TEAM_ID:-}" ]]; then
    echo "ERROR: set DEVELOPER_TEAM_ID env to your Apple Developer Team ID."
    echo "Find it via: security find-identity -v -p codesigning"
    exit 1
fi

# User-provided codesign identity. Either the full cert common name in quotes,
# or the SHA-1 hash from the find-identity output (the leading 40-char hex).
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    echo "ERROR: set CODESIGN_IDENTITY env to your codesigning cert."
    echo ""
    echo "Find it via: security find-identity -v -p codesigning"
    echo ""
    echo "Use either the full cert name in quotes, e.g.:"
    echo "    export CODESIGN_IDENTITY='Apple Development: your.email@example.com (${DEVELOPER_TEAM_ID})'"
    echo ""
    echo "Or the SHA-1 hash (40-char hex from the find-identity output), e.g.:"
    echo "    export CODESIGN_IDENTITY=B61E0CF310468BF3C2055353B931C8EDBBD1FA44"
    exit 1
fi

SPIKE_DIR="$(cd "$(dirname "$0")/.." && pwd)/tools/keychain-spike"
STAGE="$SPIKE_DIR/build-stage"
APP="$STAGE/Local Wallet.app"
HELPER="$APP/Contents/Helpers/wallet-keychain-spike"

echo "=== 1/5 Building wallet-keychain-spike (release) ==="
(cd "$SPIKE_DIR" && cargo build --release --bin wallet-keychain-spike)

echo "=== 2/5 Substituting AppIdentifierPrefix in entitlements ==="
rm -rf "$STAGE"
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/MacOS"
sed "s|\$(AppIdentifierPrefix)|$DEVELOPER_TEAM_ID.|g" \
    "$SPIKE_DIR/wallet-keychain-spike.entitlements" \
    > "$STAGE/resolved.entitlements"

# A minimal Info.plist for the .app bundle — without one, codesign refuses.
cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.localwallet.spike</string>
    <key>CFBundleName</key><string>Local Wallet Spike</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>0.0.1</string>
    <key>CFBundleExecutable</key><string>spike-stub</string>
</dict>
</plist>
PLIST

# The bundle needs an executable at MacOS/spike-stub for codesign to accept it.
# Symlinks to system binaries can't be re-signed; copy and re-sign instead.
cp /usr/bin/true "$APP/Contents/MacOS/spike-stub"
chmod +x "$APP/Contents/MacOS/spike-stub"

echo "=== 3/5 Copying helper into bundle ==="
cp "$SPIKE_DIR/target/release/wallet-keychain-spike" "$HELPER"

echo "=== 4/6 Codesigning the spike-stub main executable ==="
codesign --force \
         --sign "$CODESIGN_IDENTITY" \
         --options runtime \
         "$APP/Contents/MacOS/spike-stub"

echo "=== 5/6 Codesigning helper with entitlements + hardened runtime ==="
codesign --force \
         --sign "$CODESIGN_IDENTITY" \
         --options runtime \
         --entitlements "$STAGE/resolved.entitlements" \
         "$HELPER"

# Sign the entire .app bundle so its container signature is consistent with the helpers inside.
codesign --force \
         --sign "$CODESIGN_IDENTITY" \
         --options runtime \
         "$APP"

# Verify the entitlements actually got attached.
echo "Entitlements actually attached to helper:"
codesign -d --entitlements - "$HELPER" 2>&1 || true

echo "Verifying bundle signature integrity:"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 || {
    echo "WARNING: bundle verification failed; spike may not launch."
}

echo "=== 6/6 Running spike from inside the .app ==="
# Set the access group to match the resolved entitlement.
set +e
KEYCHAIN_ACCESS_GROUP="$DEVELOPER_TEAM_ID.com.localwallet" "$HELPER"
RC=$?
set -e

if [[ $RC -eq 137 || $RC -eq 9 ]]; then
    echo ""
    echo "ERROR: helper was killed at launch (signal 9 / SIGKILL)."
    echo "This is almost always macOS rejecting the codesign or bundle integrity."
    echo ""
    echo "Diagnostic: in another terminal, run:"
    echo "    log stream --predicate 'sender == \"amfid\" OR subsystem == \"com.apple.amfi\"' --info"
    echo "Then re-run this script. The amfid log lines will show why."
    echo ""
    echo "Other diagnostics to try:"
    echo "    spctl --assess --verbose=4 \"$HELPER\""
    echo "    codesign --verify --strict --deep --verbose=4 \"$HELPER\""
    exit 1
fi

exit $RC
