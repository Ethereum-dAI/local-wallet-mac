# Local Monorepo Setup

This guide explains how to clone the three Local Wallet repositories and run the macOS app locally from Xcode.

The macOS app is developed as a local monorepo made of three sibling Git checkouts. The repositories stay separate in GitHub, but your local filesystem should keep them under the same parent directory so Rust path overrides, Xcode builds, and daemon discovery all resolve consistently.

## Repositories

| Repository | Purpose |
| --- | --- |
| `local-wallet-mac` | macOS app, Xcode project, Swift packages, Rust FFI bridge, build scripts |
| `local-wallet-protocol` | Protocol SDK crates used by the FFI bridge |
| `local-wallet-daemon` | `wallet-node` daemon binary and supporting daemon crates |

## Prerequisites

Install these before opening the app in Xcode:

- macOS on Apple Silicon.
- Xcode, with Command Line Tools installed.
- An Apple Development team selected in Xcode for local app signing.
- Homebrew.
- Rust, preferably installed with `rustup`.
- Access to the three GitHub repositories.

```bash
xcode-select --install
brew install cbindgen xcodegen llama.cpp
rustup target add aarch64-apple-darwin
```

If `rustup` is not installed yet, install it from `https://rustup.rs/`, open a new shell, and rerun the `rustup target add` command.

`llama.cpp` provides the local inference libraries used by the app. If Homebrew does not install `ggml` as a dependency on your machine, install or reinstall it with:

```bash
brew install ggml
```

## Clone The Local Monorepo

Create one parent directory and clone all three repositories inside it:

```bash
mkdir -p ~/Developer/local-wallet
cd ~/Developer/local-wallet

git clone https://github.com/Ethereum-dAI/local-wallet-mac.git
git clone https://github.com/Ethereum-dAI/local-wallet-protocol.git
git clone https://github.com/Ethereum-dAI/local-wallet-daemon.git
```

If GitHub rejects the clone because the repositories are private, authenticate first:

```bash
gh auth login
```

You can also use SSH remotes if your GitHub SSH key is configured:

```bash
git clone git@github.com:Ethereum-dAI/local-wallet-mac.git
git clone git@github.com:Ethereum-dAI/local-wallet-protocol.git
git clone git@github.com:Ethereum-dAI/local-wallet-daemon.git
```

The final layout must look like this:

```text
~/Developer/local-wallet/
  local-wallet-mac/
  local-wallet-protocol/
  local-wallet-daemon/
```

Do not nest `local-wallet-protocol` or `local-wallet-daemon` inside `local-wallet-mac`. The macOS repo expects them to be siblings.

## Enable Local Rust Path Overrides

From the macOS repo:

```bash
cd ~/Developer/local-wallet/local-wallet-mac
cp rust-core/.cargo/config.toml.example rust-core/.cargo/config.toml
```

The copied file is gitignored and points Cargo at the sibling protocol and daemon checkouts:

```toml
paths = [
    "../../local-wallet-protocol",
    "../../local-wallet-daemon",
]
```

Those paths are resolved from `local-wallet-mac/rust-core/.cargo`, so the sibling layout above is required.

You can verify that Cargo sees the workspace dependencies with:

```bash
cargo metadata --manifest-path rust-core/Cargo.toml --format-version 1 >/dev/null
```

## Build The Swift/Rust FFI Bridge

Run the FFI build script from the macOS repo root:

```bash
./scripts/build-ffi.sh
```

This script builds `wallet-ffi` for `aarch64-apple-darwin`, runs `cbindgen`, and stages the generated static library and headers into `swift-bridge/`. These generated outputs are local build artifacts and are not committed.

## Build The Daemon

Build `wallet-node` from the sibling daemon repository:

```bash
cd ../local-wallet-daemon
cargo build -p wallet-node
cd ../local-wallet-mac
```

The Xcode app can discover the daemon at the default sibling path:

```text
../local-wallet-daemon/target/debug/wallet-node
```

For a release daemon:

```bash
cd ../local-wallet-daemon
cargo build -p wallet-node --release
cd ../local-wallet-mac
```

If your daemon is somewhere else, set an absolute path before launching Xcode from the same shell:

```bash
export WALLET_NODE_BIN="/absolute/path/to/wallet-node"
open LocalWallet.xcodeproj
```

## Open And Run In Xcode

Open the Xcode project from the macOS repo root:

```bash
open LocalWallet.xcodeproj
```

Then:

1. Select the `LocalWalletApp` scheme.
2. Select `My Mac` as the run destination.
3. Open the app target signing settings and choose your Apple Development team.
4. Build and run from Xcode.

Run the GUI app from Xcode instead of `swift run`. Secure Enclave and Keychain flows require a signed app bundle and can fail with entitlement errors when the app is launched as an unsigned command-line process.

## First Launch And Local Model

Local Xcode development does not require the GGUF model to be embedded in the app bundle. The app setup flow can install the model into:

```text
~/Library/Application Support/LocalWallet/Models/
```

If the model is already present there, the app will reuse it. Packaged demo builds may embed the model, but normal Xcode development should treat the model as a local runtime asset installed during setup.

## Optional Hosted Bundler Endpoint

The local daemon handles the app's wallet execution path. If you need to test with a hosted Sepolia bundler endpoint, set:

```bash
export LOCAL_WALLET_SEPOLIA_BUNDLER_URL="https://your-bundler.example"
open LocalWallet.xcodeproj
```

## Troubleshooting

### `cbindgen: command not found`

Install it with:

```bash
brew install cbindgen
```

Then rerun:

```bash
./scripts/build-ffi.sh
```

### Cargo does not use local protocol or daemon crates

Make sure the three repositories are siblings and that `rust-core/.cargo/config.toml` exists:

```bash
ls ../local-wallet-protocol ../local-wallet-daemon
cat rust-core/.cargo/config.toml
```

If the layout is wrong, move the repositories so they match the structure in this guide, or update the local `paths` entries to your actual sibling locations.

### Xcode cannot find or start `wallet-node`

Build the daemon first:

```bash
cd ../local-wallet-daemon
cargo build -p wallet-node
cd ../local-wallet-mac
```

If you use a custom daemon location, launch Xcode with:

```bash
export WALLET_NODE_BIN="/absolute/path/to/wallet-node"
open LocalWallet.xcodeproj
```

### Keychain or Secure Enclave errors when running from Terminal

Open and run `LocalWallet.xcodeproj` in Xcode. The GUI app needs a signed macOS app bundle for those flows.

### llama.cpp or ggml linker errors

Install or reinstall the Homebrew libraries:

```bash
brew install llama.cpp ggml
brew reinstall llama.cpp
```

Then rebuild the FFI bridge and app.

### Xcode project is out of date

The checked-in Xcode project is generated from `project.yml`. If `project.yml` changes, regenerate the project from the macOS repo root:

```bash
xcodegen generate
```
