# Local Monorepo Setup

This guide explains how to clone the Local Wallet monorepo and run the macOS app locally from Xcode.

The macOS app, the protocol SDK, and the daemon all live in one repository, `local-wallet-mac`. The protocol crates live at `local-wallet-protocol/` and the daemon crates live at `local-wallet-daemon/`, both checked in as ordinary directories in this repo and consumed via relative `path` dependencies in Cargo.toml — no sibling checkouts and no separate clones are needed.

## Layout

| Directory | Purpose |
| --- | --- |
| `local-wallet-mac` (repo root) | macOS app, Xcode project, Swift packages, Rust FFI bridge, build scripts |
| `local-wallet-protocol` | Protocol SDK crates used by the FFI bridge |
| `local-wallet-daemon` | `wallet-node` daemon binary and supporting daemon crates |

## Prerequisites

Install these before opening the app in Xcode:

- macOS 14.0 or newer on Apple Silicon.
- 16 GB RAM minimum for the local Gemma 4 E4B model setup.
- Xcode 16 or newer, with Command Line Tools installed. Use the latest stable Xcode when possible; the app target is built with Swift 6.
- An Apple Development team selected in Xcode for local app signing.
- Homebrew.
- Rust 1.91 or newer, preferably installed with `rustup`. Latest stable Rust is recommended.
- `cbindgen`; current known-good local version is 0.29.2.
- Access to the `local-wallet-mac` GitHub repository.

```bash
xcode-select --install
brew install cbindgen xcodegen llama.cpp
rustup target add aarch64-apple-darwin
```

If `rustup` is not installed yet, install it from `https://rustup.rs/`, open a new shell, and rerun the `rustup target add` command.

Check toolchain versions before debugging build issues:

```bash
xcodebuild -version
swift --version
xcode-select -p
rustc --version
cargo --version
rustup show active-toolchain
cbindgen --version
```

Expected Rust baseline:

```text
rustc >= 1.91
cargo >= 1.91
```

The current known-good local Rust toolchain is:

```text
rustc 1.95.0
cargo 1.95.0
stable-aarch64-apple-darwin
cbindgen 0.29.2
```

`llama.cpp` provides the local inference libraries used by the app. If Homebrew does not install `ggml` as a dependency on your machine, install or reinstall it with:

```bash
brew install ggml
```

The packaged v0.1 alpha app is built for macOS 14+. For release packaging, do not assume the Homebrew `llama.cpp`/`ggml` bottles on your current machine are macOS 14-compatible; use `LOCAL_LLAMA_PREFIX` with dylibs compiled for `CMAKE_OSX_DEPLOYMENT_TARGET=14.0` as described in `scripts/README.md`.

## Clone The Local Monorepo

Clone the one repository:

```bash
mkdir -p ~/Developer/local-wallet
cd ~/Developer/local-wallet

git clone https://github.com/Ethereum-dAI/local-wallet-mac.git
```

If GitHub rejects the clone because the repository is private, authenticate first:

```bash
gh auth login
```

You can also use the SSH remote if your GitHub SSH key is configured:

```bash
git clone git@github.com:Ethereum-dAI/local-wallet-mac.git
```

The protocol and daemon crates come along with this clone — they now live at `local-wallet-mac/local-wallet-protocol` and `local-wallet-mac/local-wallet-daemon`:

```text
~/Developer/local-wallet/
  local-wallet-mac/
    local-wallet-protocol/
    local-wallet-daemon/
```

`cd` into the repo before continuing with the rest of this guide:

```bash
cd local-wallet-mac
```

Quick verification:

```bash
ls -l local-wallet-daemon/target/release/wallet-node   # present only after you build the daemon below
cargo metadata --manifest-path rust-core/Cargo.toml --format-version 1 >/dev/null
```

## Build The Swift/Rust FFI Bridge

Run the FFI build script from the macOS repo root:

```bash
./scripts/build-ffi.sh
```

This script builds `wallet-ffi` for `aarch64-apple-darwin`, runs `cbindgen`, and stages the generated static library and headers into `swift-bridge/`. These generated outputs are local build artifacts and are not committed.

## Build The Daemon

Build `wallet-node` from the in-repo daemon directory:

```bash
cd local-wallet-daemon
cargo build -p wallet-node --release
cd ..
```

The checked-in Xcode scheme points at the release daemon by default:

```text
local-wallet-daemon/target/release/wallet-node
```

The app can also fall back to `local-wallet-daemon/target/debug/wallet-node`, but release is the recommended local path because it matches the Xcode scheme and packaged app behavior.

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

The recommended Gemma 4 E4B Q4_0 GGUF is a 4.59 GB download and local setup is blocked on Macs with less than 16 GB RAM. It is installed as `gemma-4-E4B-it-Q4_0.gguf`, which is the path every bench/test default expects. If you onboarded before the Q4_K_M pin broke, the app will download the Q4_0 file rather than reuse the old `gemma-4-E4B-it-Q4_K_M.gguf`; delete the stale file to reclaim the disk.

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

### Cargo can't find the protocol or daemon crates

`rust-core/Cargo.toml` depends on the protocol and daemon crates via in-repo relative `path` entries, not a sibling checkout or a Cargo path override. Verify the directories exist at the repo root and that Cargo can resolve them:

```bash
ls local-wallet-protocol local-wallet-daemon
cargo metadata --manifest-path rust-core/Cargo.toml --format-version 1 >/dev/null
```

If either directory is missing, restore it with `git checkout` or re-clone the repository — they're tracked as ordinary directories in `local-wallet-mac`, not separate checkouts.

### Xcode cannot find or start `wallet-node`

Build the daemon first:

```bash
cd local-wallet-daemon
cargo build -p wallet-node --release
cd ..
```

If you use a custom daemon location, launch Xcode with:

```bash
export WALLET_NODE_BIN="/absolute/path/to/wallet-node"
open LocalWallet.xcodeproj
```

### Keychain or Secure Enclave errors when running from Terminal

Open and run `LocalWallet.xcodeproj` in Xcode. The GUI app needs a signed macOS app bundle for those flows.

### llama.cpp or ggml linker errors

For local Xcode development, install or reinstall the Homebrew libraries:

```bash
brew install llama.cpp ggml
brew reinstall llama.cpp
```

Then rebuild the FFI bridge and app.

For release packaging, verify the embedded `llama.cpp`/`ggml` dylibs are built for macOS 14.0 or older. Recent Homebrew bottles can be built with a newer deployment target on newer macOS versions; in that case, build a local macOS 14-compatible prefix and pass it with `LOCAL_LLAMA_PREFIX`.

### Xcode project is out of date

The checked-in Xcode project is generated from `project.yml`. If `project.yml` changes, regenerate the project from the macOS repo root:

```bash
xcodegen generate
```
