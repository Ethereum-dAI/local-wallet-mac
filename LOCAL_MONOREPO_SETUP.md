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

- macOS 15.0 or newer on Apple Silicon.
- 16 GB RAM minimum for the local model setup (a wallet fine-tune of Gemma 4 E4B).
- Xcode 16 or newer, with Command Line Tools installed. Use the latest stable Xcode when possible; the app target is built with Swift 6.
- An Apple Development team selected in Xcode for local app signing.
- Homebrew, for `cbindgen` and `xcodegen`. (Not for llama.cpp — see below.)
- Rust 1.91 or newer, preferably installed with `rustup`. Latest stable Rust is recommended.
- `cbindgen`; current known-good local version is 0.29.2.
- Access to the `local-wallet-mac` GitHub repository.

```bash
xcode-select --install
brew install cbindgen xcodegen
rustup target add aarch64-apple-darwin
```

Do **not** `brew install llama.cpp`. It is pinned and downloaded by the repo — see [llama.cpp is pinned, not installed](#llamacpp-is-pinned-not-installed) below.

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

### llama.cpp is pinned, not installed

`llama.cpp` provides the local inference libraries the app links (`libllama`, `libllama-common`, `libggml`, `libggml-base`) plus the ggml compute backends. **You do not install it.** `scripts/provision-llama.sh` assembles a repo-local prefix at `.llama/current` from two pinned sources:

- the upstream release asset (~11 MB), verified against a committed sha256, for the dylibs;
- the pinned commit's headers (~1 MB), via a sparse `git fetch` — the release asset ships none.

`scripts/build-ffi.sh` calls it for you, so the normal build sequence already does the right thing, and repeat builds are a no-op. The first provision needs network access and a `git` new enough for partial clone (2.19+, which the Xcode Command Line Tools git satisfies).

The version is recorded in [`local-llm/LLAMA_CPP_PIN`](local-llm/LLAMA_CPP_PIN), which also documents how to bump it.

This exists because Homebrew **cannot** install a specific `llama.cpp` version: there is no versioned formula, the core tap is API-only so there is no local formula history to check out, `brew pin` only freezes whatever you already have, and `ggml` is a separate formula that has to move in lockstep. An unpinned `brew install llama.cpp` therefore gave you "whatever was current the day you ran it", and two contributors cloning the same commit weeks apart got different ABIs. The symptom was a compile error in `CLlamaBridge.cpp` on an unmodified tree, such as:

```text
error: no member named 'use_mmap' in 'llama_model_params'
error: no matching function for call to 'llama_sampler_init_penalties'
```

Nothing `brew upgrade` does can move the build off the pin now. Homebrew is still used for `cbindgen` and `xcodegen`, which are code generators rather than linked libraries — a version drift there regenerates a file instead of corrupting an ABI.

`.llama/` is gitignored. To force a clean re-provision:

```bash
rm -rf .llama && ./scripts/provision-llama.sh
```

There is no implicit fallback to Homebrew: an unprovisioned tree fails fast with `'llama.h' file not found` rather than silently building against whatever version happens to be installed.

**`LOCAL_LLAMA_PREFIX=/opt/homebrew` is not an escape hatch.** Homebrew ships llama.cpp's public headers but none of the `common/` layer that `CLlamaBridge.cpp` needs, so it fails on `'chat.h' file not found`. An override prefix has to provide `lib/`, `include/` **and** `include-common/` — in practice, a hand-built llama.cpp at the pinned commit. If GitHub is unreachable, the previously provisioned prefix is left untouched and an existing checkout keeps building; there is no offline path to a *first* provision.

If you are doing Rust-only or `swift-bridge`-only work and do not want `build-ffi.sh` fetching llama.cpp at all:

```bash
LOCAL_WALLET_SKIP_LLAMA_PROVISION=1 ./scripts/build-ffi.sh
```

That still produces `libwallet_ffi.a` and the headers `swift-bridge` needs; anything that builds `local-llm` will then need the prefix provisioned separately.

The packaged v0.1 alpha app is built for macOS 15+. The pinned release dylibs are built `minos 13.3`, so they satisfy that floor on any host and release packaging no longer needs a hand-built prefix to get past the deployment-target gate in `scripts/package-macos-demo.sh`.

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

The default model — `gemma-4-E4B-it-Q4_K_M.gguf`, the untuned Gemma 4 E4B — is a 5.34 GB download, and 16 GB of RAM is the practical floor for it.

The `local-llm` bench and the model-backed Swift tests default to `gemma-4-E4B-it-Q4_0.gguf` — the same model as the app's default but a **different quantization**, kept because that is what those tests were calibrated on. They self-skip when it is absent; point them at another GGUF with `--model` if you would rather not keep a second copy.

If you onboarded onto the wallet fine-tune, nothing migrates: `gemma-4-E4B-wallet-ft` stays curated and your stored selection keeps resolving. Switch to the default in Settings › Models when you want the 21.7-point improvement, and delete the fine-tune afterwards to reclaim 5.34 GB.

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

Do **not** reach for `brew install llama.cpp` — that is what these errors used to mean, but llama.cpp is now pinned and Homebrew is not involved. Re-provision the pinned prefix instead:

```bash
rm -rf .llama && ./scripts/provision-llama.sh
cd local-llm && swift test    # 21 tests; exercises real inference
```

Read the error before assuming it is the prefix, though:

- **`no member named …` / `no matching function for call to …` in `CLlamaBridge.cpp`** — an API mismatch between the pinned headers and the code. If you just bumped `LLAMA_CPP_PIN`, this is expected upstream churn and the bridge needs updating for the new API. If you did **not** touch the pin, check that `LOCAL_LLAMA_PREFIX` is not set in your environment or Xcode scheme, which would silently take you off-pin.
- **`ld: library 'llama' not found`**, usually preceded by `ld: warning: search path '…/.llama/current/lib' not found` — the headers resolved but `lib/` is missing or incomplete. A wholly unprovisioned tree fails earlier, at compile time, with `'llama.h' file not found`, so this points at a half-populated prefix or a `LOCAL_LLAMA_PREFIX` with headers but no dylibs. `rm -rf .llama && ./scripts/provision-llama.sh` rebuilds it.
- **`Failed to load llama.cpp model` at runtime, with the build succeeding** — no ggml compute backend registered. `provision-llama.sh` verifies the backend closure, so this should be impossible on-pin; it is the signature of an off-pin Homebrew prefix, whose backends are `dlopen`'d plugins under `libexec/` that nothing copies or links.
- **`LLAMA_CPP_COMMIT is not the commit release b… was built from`** — the two halves of the pin disagree, so the headers would describe a different ABI than the dylibs. Provisioning refuses rather than build a mismatched pair. Re-derive the commit from the release tag: `gh api repos/ggml-org/llama.cpp/git/refs/tags/b<release> --jq '.object.sha'`.
- **`Could not fetch llama.cpp commit …`** / **`Could not resolve tag …`** — provisioning could not reach GitHub. A commit that does not exist upstream is caught earlier, by the tag check above, so treat this as a connectivity problem.
- **`'llama.h' file not found`** — the prefix has no `include/`: either it was never assembled (run `./scripts/build-ffi.sh`), or `LOCAL_LLAMA_PREFIX` points somewhere without it.
- **`'chat.h' file not found`** — the prefix has no `include-common/`. If you set `LOCAL_LLAMA_PREFIX`, it must supply that directory too, or set `LOCAL_LLAMA_COMMON_INCLUDE_DIR`; see `local-llm/README.md`. On an existing checkout, see the next entry first.
- **`'chat.h' file not found` right after pulling** — a stale SwiftPM build directory, not a broken prefix. The `common/` headers used to be committed under `local-llm/Sources/CLlamaBridge/third_party/`; they are now fetched into the pinned prefix, and an incremental build planned before that change keeps looking for the deleted directory. Clean builds are unaffected:

```bash
rm -rf local-llm/.build wallet-macos/.build
```

For release packaging, the pinned dylibs are `minos 13.3` and carry no external dependencies, so they clear the deployment-target and external-dependency gates in `scripts/package-macos-demo.sh` without a hand-built prefix.

### Xcode project is out of date

The checked-in Xcode project is generated from `project.yml`. If `project.yml` changes, regenerate the project from the macOS repo root:

```bash
xcodegen generate
```
