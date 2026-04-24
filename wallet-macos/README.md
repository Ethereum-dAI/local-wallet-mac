# Local Wallet macOS Demo App

`wallet-macos` is a signed macOS demo/reference app for the lower-level Rust and Swift layers in this repo. It is not meant to represent the final product wallet UX yet.

What this demo currently exercises:

- Secure Enclave + Keychain persistence for the device-bound P-256 signing key
- public-key derivation and local wallet metadata persistence
- precomputed Kernel smart-account address derivation
- balance/deployment inspection over public Ethereum Sepolia RPC
- local ERC-4337 UserOperation building for a simple ETH transfer intent
- Secure Enclave signing + hosted bundler submission on Ethereum Sepolia
- debug logging for bootstrap, inspection, gas estimation, signing, submission, and receipt polling

This app must be run as a signed macOS app bundle.

The direct Secure Enclave persistence model now uses permanent Keychain key items. That works in the real app target, but it will fail with `OSStatus -34018` if you try to run the app with `swift run`.

## Open And Run

1. Open `LocalWallet.xcodeproj` in Xcode.
2. Select the `LocalWalletApp` scheme.
3. In `Signing & Capabilities`, choose your Apple development team for the `LocalWalletApp` target.
4. Build and run the app from Xcode.

## Regenerate The Project

The Xcode project is generated from `project.yml` with `xcodegen`.

```bash
xcodegen generate
```

## Current Layout

- `wallet-macos/Sources/WalletMacOSApp` contains the demo app code.
- `swift-bridge` is the Swift package that calls the Rust FFI layer.
- `rust-core` contains the UserOperation, WebAuthn, and signature encoding logic.

## App Module Map

- `WalletMacOSApp.swift`
  - AppKit entrypoint and the demo dashboard UI shell.
- `AppModel.swift`
  - Main coordinator for bootstrap, account inspection, draft building, signing, submission, and debug logging.
- `KeyStore.swift`
  - Secure Enclave + Keychain key lifecycle and signing.
- `WalletMetadataStore.swift`
  - Local JSON persistence for non-secret wallet metadata.
- `SmartAccountConfiguration.swift`
  - Chain config, Kernel contract addresses, EntryPoint config, and bundled ABI references.
- `KernelAccountAddressPredictor.swift`
  - Thin app-side wrapper around shared Rust/Swift bridge logic for predicted Kernel account addresses.
- `DemoRPCClient.swift`
  - Read-only JSON-RPC client for public chain inspection and fee fallback data.
- `BundlerClient.swift`
  - Hosted ERC-4337 bundler RPC client for gas estimation, fee quoting, submission, and receipt polling.
- `UserOperationBuilder.swift`
  - Local draft construction for the current transaction intents.
- `UserOperationModels.swift`
  - Demo-side models for draft representation and bundler payload shaping.
- `DemoModels.swift`
  - View-model structs used by the current demo dashboard and transaction composer.

## Current Limits

- Sepolia-only demo mode is currently enforced in the app shell.
- The app currently focuses on ETH transfer as the first transaction type.
- The UI is intentionally a workbench/demo shell, not the final wallet interface.

## Hosted Bundler Configuration

The Sepolia hosted bundler URL is intentionally not committed in source. For local development you can provide it as an environment variable:

```bash
export LOCAL_WALLET_SEPOLIA_BUNDLER_URL="https://..."
```

For packaged demo builds, use the same variable when running the package script:

```bash
LOCAL_WALLET_SEPOLIA_BUNDLER_URL="https://..." ./scripts/package-macos-demo.sh
```

The package script injects the URL into the built app's `Info.plist` and re-signs that copied app bundle. If the variable is not set, the app still builds and can inspect the account, but bundler submission is disabled.
