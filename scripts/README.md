# scripts

Repository helper scripts for local builds, packaging, fork checks, and signing diagnostics.

Run scripts from the repository root unless the script says otherwise.

## Scripts

### `build-ffi.sh`

Builds the Rust FFI bridge for Apple Silicon macOS, generates the C header with `cbindgen`, copies the `wallet-node-api` version header, and stages the static library for Swift. The default deployment target is macOS 14.0.

```bash
./scripts/build-ffi.sh
```

Outputs:

```text
swift-bridge/Sources/WalletFFI/wallet_ffi.h
swift-bridge/Sources/WalletFFI/wallet_node_api_version.h
swift-bridge/lib/libwallet_ffi.a
```

Prerequisites:

- Rust target `aarch64-apple-darwin`
- `cbindgen`
- The script locates the Cargo `OUT_DIR` via `find`, first under `target/aarch64-apple-darwin/release/build` and then `target/release/build`; no `jq` is required.

### Kernel mainnet-fork fixture (moved)

The Kernel/EntryPoint mainnet-fork check does not live here. It ships with the daemon, at `local-wallet-daemon/scripts/run-kernel-mainnet-fork-check.sh`. Run it from that directory; see the daemon's docs for its `ETH_RPC_URL` / `WALLET_FORK_BLOCK_NUMBER` env contract.

### `run-bundler-key-hardening-gate.sh`

The automated gate for the bundler key hardening work. It runs the daemon-side Rust checks against the in-repo `local-wallet-daemon` directory (format, workspace tests, clippy with `-D warnings`, a `wallet-node` release build, and the fd / Unix-transport / HTTP `--include-ignored` integration suites), then the Swift bridge and macOS app `swift test` suites, generates the Xcode project with `xcodegen` and builds the signed `LocalWalletApp` target, and finishes with a `git diff --check` whitespace check.

```bash
./scripts/run-bundler-key-hardening-gate.sh
```

Override the daemon location with `LW_DAEMON_DIR=/path/to/local-wallet-daemon`. Requires `xcodegen` for the signed app-target build.

### `package-macos-demo.sh`

Builds the Swift/Rust bridge, builds the `LocalWalletApp` Xcode scheme for Apple Silicon, embeds the `wallet-node` daemon, optionally embeds the recommended GGUF model, copies llama.cpp/ggml dynamic libraries into the app bundle, optionally injects the hosted Sepolia bundler URL, signs the copied app, verifies the application identifier entitlement needed by Secure Enclave, optionally notarizes and staples it, and produces a zip under `dist/`.

```bash
LOCAL_WALLET_SEPOLIA_BUNDLER_URL=https://your-bundler.example \
./scripts/package-macos-demo.sh
```

By default the script builds `wallet-node` from the in-repo `local-wallet-daemon` directory, targets macOS 14.0, and does not embed the recommended model, so the v0.1 alpha zip stays smaller and onboarding installs the model during setup. Set `LOCAL_WALLET_EMBED_MODEL=1` to embed the model, downloading it if it is not already present in `~/Library/Application Support/LocalWallet/Models/`. Override with `LOCAL_WALLET_ZIP_NAME`, `LOCAL_WALLET_DAEMON_REPO`, `LOCAL_WALLET_NODE_BIN`, `LOCAL_MODEL_PATH`, `LOCAL_LLAMA_PREFIX`, `LOCAL_LLAMA_LIB_DIR`, `LOCAL_WALLET_DEPLOYMENT_TARGET`, or `LOCAL_WALLET_MODEL_CACHE_DIR` as needed.

For a macOS 14-compatible package, make sure any external llama.cpp/ggml dylibs were compiled with `CMAKE_OSX_DEPLOYMENT_TARGET=14.0` and `CMAKE_OSX_ARCHITECTURES=arm64`, then pass their install prefix:

```bash
LOCAL_LLAMA_PREFIX="$PWD/build/llama-macos14-prefix" \
LOCAL_WALLET_DEPLOYMENT_TARGET=14.0 \
./scripts/package-macos-demo.sh
```

The package step verifies every embedded Mach-O in `Contents/MacOS`, `Contents/Frameworks`, and `Contents/Resources/bin` has `minos <= LOCAL_WALLET_DEPLOYMENT_TARGET`. It also verifies that the final app signature includes an application identifier entitlement; without that entitlement the Secure Enclave key creation path returns `errSecMissingEntitlement` and onboarding cannot create a wallet.

For external alpha distribution, sign with a Developer ID Application certificate and notarize the build:

```bash
xcrun notarytool store-credentials local-wallet-notary \
  --apple-id "developer@example.com" \
  --team-id YOURTEAMID \
  --password "app-specific-password"

CODESIGN_IDENTITY="Developer ID Application: Your Name (YOURTEAMID)" \
LOCAL_WALLET_NOTARIZE=1 \
LOCAL_WALLET_NOTARY_PROFILE=local-wallet-notary \
LOCAL_WALLET_SEPOLIA_BUNDLER_URL=https://your-bundler.example \
./scripts/package-macos-demo.sh
```

When `LOCAL_WALLET_NOTARIZE=1` is set, the script requires a Developer ID Application identity, submits a temporary zip with `xcrun notarytool`, staples the ticket to the `.app`, runs `spctl --assess`, then creates the final zip. This is the build path to use for testers outside your own Macs; it avoids per-user ad-hoc re-signing and preserves the app's signing identity for Keychain continuity.

If `LOCAL_WALLET_NOTARIZE` is omitted, the zip is for local/private testing only and may be blocked by Gatekeeper on other Macs. Testers can remove quarantine from a trusted copy, but they should not ad-hoc re-sign this app; ad-hoc signing changes the code identity and breaks the Secure Enclave/Keychain entitlement chain needed for wallet creation.

### `run-keychain-spike.sh`

Builds and signs the Keychain entitlement spike app/helper, then runs the helper from inside the `.app` bundle.

```bash
export DEVELOPER_TEAM_ID=YOURTEAMID
export CODESIGN_IDENTITY='Apple Development: you@example.com (YOURTEAMID)'
./scripts/run-keychain-spike.sh
```

This is for validating the paid-account `keychain-access-groups` entitlement/provisioning chain. The daemon's current development path uses the non-access-group Keychain fallback.

### `generate-app-icon.swift`

Generates the local app icon assets used by the macOS demo.

```bash
swift ./scripts/generate-app-icon.swift
```

## Secrets

Do not commit live RPC URLs, bundler URLs, signing identities, or Apple account details. Use ignored env files such as `.env` or shell environment variables.
