# scripts

Repository helper scripts for local builds, packaging, fork checks, and signing diagnostics.

Run scripts from the repository root unless the script says otherwise.

## Scripts

### `provision-llama.sh`

Assembles the pinned llama.cpp prefix declared in `local-llm/LLAMA_CPP_PIN`. Downloads the pinned upstream release asset (~11 MB), verifies it against the committed sha256, and stages the dylibs into `.llama/<release>/lib`. The release ships no headers, so it then fetches them from the pinned commit — a sparse, blob-filtered `git fetch` of just the header directories, ~1 MB — into `.llama/<release>/include` (public API) and `.llama/<release>/include-common` (llama.cpp `common/`, plus `jinja/` and `nlohmann/`). Finally it links `.llama/current`.

```bash
./scripts/provision-llama.sh
```

You rarely call this directly — `build-ffi.sh` calls it, and it is idempotent, so a prefix that already matches the pin is a no-op. Call it directly to re-provision after editing the pin:

```bash
rm -rf .llama && ./scripts/provision-llama.sh
```

It fails closed when:

- the download's sha256 does not match `LLAMA_CPP_SHA256`
- `LLAMA_CPP_ASSET` does not correspond to `LLAMA_CPP_RELEASE`
- **`LLAMA_CPP_COMMIT` is not the commit that `LLAMA_CPP_RELEASE`'s tag points at** — checked with `git ls-remote` against upstream, so the headers cannot describe a different ABI than the dylibs
- a staged dylib's `@rpath` closure is incomplete or reaches outside the prefix and the OS
- a dylib's `minos` exceeds `LOCAL_WALLET_DEPLOYMENT_TARGET` (default 15.0)
- an expected header is missing after staging

Header integrity itself needs no checksum: git verifies fetched objects against the commit SHA.

**Failure leaves the previous prefix intact.** Everything is staged into `.llama/.staging-<release>` and swapped in only after every check passes, so an interrupted or failed run — a dropped download, an unreachable remote, a rejected tag — cannot leave a half-built prefix for the build to compile against. With the headers no longer vendored there is no in-tree copy to fall back on, so this matters more than it used to.

It also repoints `.llama/current` — the path `Package.swift` actually consumes — on the fast path, not just after a full provision. The stamp is per-release, so bumping the pin and then reverting it would otherwise leave `current` on the newer release while the older one was still stamped, and the script would report success while the build used a release the repo does not declare. A stamped-but-incomplete prefix is re-provisioned rather than trusted.

After a successful install it prunes superseded release prefixes and cached assets, so `.llama/` does not grow by ~25 MB per pin bump per worktree.

Setting `LOCAL_LLAMA_PREFIX` skips provisioning entirely, matching `local-llm/Package.swift`'s resolution order.

`.llama/` is gitignored. The release asset and a shallow header checkout are cached under `.llama/cache`, so re-provisioning re-downloads neither — but it is **not** offline: the tag check and the header fetch both contact GitHub every time the prefix is actually rebuilt. Only the no-op path (a prefix already matching the pin) touches the network at all. Requires `git` new enough for partial clone (2.19+); the git shipped with Xcode Command Line Tools is fine.

### `build-ffi.sh`

Provisions the pinned llama.cpp prefix (see above), builds the Rust FFI bridge for Apple Silicon macOS, generates the C header with `cbindgen`, copies the `wallet-node-api` version header, and stages the static library for Swift. The default deployment target is macOS 15.0.

Set `LOCAL_WALLET_SKIP_LLAMA_PROVISION=1` to skip the provisioning step. Useful for Rust-only or `swift-bridge`-only work, which needs `libwallet_ffi.a` from this script but has nothing to do with llama.cpp, and which would otherwise be blocked whenever the prefix needs rebuilding and GitHub is unreachable.

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

By default the script builds `wallet-node` from the in-repo `local-wallet-daemon` directory, targets macOS 15.0, and does not embed the recommended model, so the v0.1 alpha zip stays smaller and onboarding installs the model during setup. Set `LOCAL_WALLET_EMBED_MODEL=1` to embed the model, downloading it if it is not already present in `~/Library/Application Support/LocalWallet/Models/`. Override with `LOCAL_WALLET_ZIP_NAME`, `LOCAL_WALLET_DAEMON_REPO`, `LOCAL_WALLET_NODE_BIN`, `LOCAL_MODEL_PATH`, `LOCAL_LLAMA_PREFIX`, `LOCAL_LLAMA_LIB_DIR`, `LOCAL_WALLET_DEPLOYMENT_TARGET`, or `LOCAL_WALLET_MODEL_CACHE_DIR` as needed.

llama.cpp/ggml come from the pinned prefix at `.llama/current`, which `provision-llama.sh` assembles from the upstream release named in `local-llm/LLAMA_CPP_PIN`. Those dylibs are built `minos 13.3` and depend on nothing outside the prefix and the OS, so a **hand-built macOS 15 prefix is no longer needed** to get a packageable build. This used to be a required step, because Homebrew's bottles are built for whatever macOS the bottle targeted (`minos 26.0` on Tahoe) and tripped the deployment-target gate.

If you do override with `LOCAL_LLAMA_PREFIX`, you own its compatibility — compile it with `CMAKE_OSX_DEPLOYMENT_TARGET=15.0` and `CMAKE_OSX_ARCHITECTURES=arm64`, and make sure its ggml ships the compute backends as ordinary linked dylibs under `lib/` (`-DGGML_BACKEND_DL=OFF`). It must also provide `include-common/` (llama.cpp's `common/` headers, with `jinja/` and `nlohmann/` nested inside) next to `include/` and `lib/`, or you must point `LOCAL_LLAMA_COMMON_INCLUDE_DIR` at them — the build reads those through `local-llm/Package.swift`, which no longer has an in-tree copy to fall back on. Homebrew cannot satisfy this: it ships no `common/` headers.

There is no Homebrew entry in the dylib search path either. If a dependency cannot be found in the override or pinned prefix, packaging fails rather than embedding a Homebrew-built ggml into an app compiled against pinned headers — a mismatch that both embed gates would otherwise accept, since the backend would be present and the reference would be `@rpath/...` from inside the bundle. A prefix whose backends are `dlopen`'d plugins under `libexec/` — which is how Homebrew builds ggml — produces an app that packages cleanly and then fails every model load at runtime, because nothing in the Mach-O dependency graph reveals the backends and none get embedded:

```bash
LOCAL_LLAMA_PREFIX="$PWD/build/llama-macos15-prefix" \
LOCAL_WALLET_DEPLOYMENT_TARGET=15.0 \
./scripts/package-macos-demo.sh
```

The package step verifies every embedded Mach-O in `Contents/MacOS`, `Contents/Frameworks`, and `Contents/Resources/bin` has `minos <= LOCAL_WALLET_DEPLOYMENT_TARGET`. It also asserts that `libggml-base`, `libggml-cpu`, and `libggml-metal` actually landed in `Contents/Frameworks`, and that no embedded binary still references a llama/ggml/omp/ssl/crypto dylib outside the bundle. It also verifies that the final app signature includes an application identifier entitlement; without that entitlement the Secure Enclave key creation path returns `errSecMissingEntitlement` and onboarding cannot create a wallet.

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
