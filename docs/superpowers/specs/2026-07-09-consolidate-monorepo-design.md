# Consolidate the three Local Wallet repos into `local-wallet-mac`

**Date:** 2026-07-09
**Branch:** `consolidate-monorepo` (worktree off `origin/main`)
**Status:** Approved design

## Goal

Bring the two sibling repositories — `local-wallet-protocol` and `local-wallet-daemon`
— into `local-wallet-mac` so the whole product lives in one repository. Eliminate the
sibling-checkout requirement and the git-pin ↔ path-override dependency dance, and add a
CI/CD GitHub Action. Do this on a new branch off `main`, leaving the existing
`kohaku-shield-v1-impl` work untouched.

## Decisions (locked with the user)

| Decision | Choice |
| --- | --- |
| Commit history | **Flat copy** — copy working trees, no history import. Original repos retain their own history. |
| Layout | **Option A — nested sub-workspaces.** Each repo becomes a top-level dir inside `local-wallet-mac`, keeping its own Cargo workspace + `Cargo.lock`. |
| Dependency wiring | Replace git-pinned revs with **in-repo path deps**; remove the `.cargo/config.toml` override machinery. |
| CI scope | **Rust-only on `ubuntu-latest`** (protocol, daemon, ffi). macOS/Xcode job deferred. |
| Isolation | Git **worktree** off `origin/main` at `.worktrees/consolidate-monorepo`. |

## Non-goals (out of scope)

- Touching the original GitHub repos (archiving/deleting/redirecting). They are left alone.
- A macOS/Xcode CI job (Swift build/test, `build-ffi.sh`, `xcodegen`).
- Any behavioral code change beyond dependency rewiring and path fixes.
- A single unified Cargo workspace (Option C) — reachable later from Option A if desired.
- Exhaustive de-duplication of copied top-level files (LICENSE/SECURITY/etc.) — optional cleanup only.

## Target layout

```
local-wallet-mac/
  rust-core/                 # wallet-ffi workspace (unchanged location)
  local-wallet-protocol/     # copied in: crates/{signature,kernel,wallet-addresses}, tooling/, Cargo.toml, Cargo.lock
  local-wallet-daemon/       # copied in: crates/{wallet-node,wallet-bundler,wallet-chain,wallet-node-api,wallet-node-store}, scripts/, documentation/, Cargo.toml, Cargo.lock
  wallet-macos/ swift-bridge/ local-llm/ privacy-helper/ swift-probe/
  scripts/ tools/ docs/ documentation/
  LocalWallet.xcodeproj project.yml
  .github/workflows/ci.yml   # new
```

There is **no root `Cargo.toml`** — the three workspaces stay independent (verified: the
mac repo root has no `Cargo.toml`, so nothing auto-absorbs the nested workspaces as members).

## Work breakdown

### 1. Copy the two repos in (flat)

Copy each sibling's working tree into `local-wallet-mac/`, **excluding**:

- `.git/` (do not import history or nested git dirs)
- `target/` (build artifacts; the daemon has a large one)
- any gitignored `.cargo/config.toml` (local override, if present)
- `.DS_Store`

Keep everything else, including each repo's `Cargo.toml`, `Cargo.lock`, `crates/`,
`README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `LICENSE-*`, `wallet-architecture.md`,
`.gitignore`, protocol's `tooling/golden-vectors`, and the daemon's `scripts/` and
`documentation/`. The copied-in `.gitignore` files continue to apply to their own subtree.

### 2. Rewire dependencies (git-pins → path deps)

**`rust-core/Cargo.toml`** `[workspace.dependencies]`:

```toml
wallet-signature = { path = "../local-wallet-protocol/crates/signature" }
wallet-kernel    = { path = "../local-wallet-protocol/crates/kernel" }
wallet-addresses = { path = "../local-wallet-protocol/crates/wallet-addresses" }
wallet-node-api  = { path = "../local-wallet-daemon/crates/wallet-node-api" }
```

**`local-wallet-daemon/Cargo.toml`** `[workspace.dependencies]`:

```toml
wallet-signature = { path = "../local-wallet-protocol/crates/signature" }
wallet-kernel    = { path = "../local-wallet-protocol/crates/kernel" }
wallet-addresses = { path = "../local-wallet-protocol/crates/wallet-addresses" }
```

Crate **directory** names differ from crate names: `wallet-signature` lives in
`crates/signature`, `wallet-kernel` in `crates/kernel`, `wallet-addresses` in
`crates/wallet-addresses`. Paths above reflect that.

Then regenerate the two affected lockfiles (`cargo update -w` / a build) so the git
sources drop out of `rust-core/Cargo.lock` and `local-wallet-daemon/Cargo.lock`.

### 3. Remove the override machinery

- Delete `rust-core/.cargo/config.toml.example` and `local-wallet-daemon/.cargo/config.toml.example`.
- Remove the `rust-core/.cargo/config.toml` line from `local-wallet-mac/.gitignore`.
- Remove the daemon's `.cargo/` override example (and `.cargo/` dir if it only held the example).

### 4. Fix path references

- **`project.yml`** scheme `environmentVariables`:
  `$(SRCROOT)/../local-wallet-daemon/target/release/wallet-node` →
  `$(SRCROOT)/local-wallet-daemon/target/release/wallet-node` (both `LOCAL_WALLET_NODE_BIN`
  and `WALLET_NODE_BIN`). Then run `xcodegen generate` to refresh `LocalWallet.xcodeproj`
  (do not hand-edit the project).
- **`scripts/package-macos-demo.sh`**: default `DAEMON_REPO` `$REPO_ROOT/../local-wallet-daemon`
  → `$REPO_ROOT/local-wallet-daemon` (keep the `LOCAL_WALLET_DAEMON_REPO` env override).
- **`scripts/run-bundler-key-hardening-gate.sh`**: default `${ROOT_DIR}/../local-wallet-daemon`
  → `${ROOT_DIR}/local-wallet-daemon` (keep the `LW_DAEMON_DIR` env override).

### 5. CI/CD

Add `.github/workflows/ci.yml` with three ubuntu jobs, each running
`cargo fmt --check` → `cargo clippy --workspace -- -D warnings` → `cargo test`:

- `protocol` — `working-directory: local-wallet-protocol`, `cargo test --workspace`
- `daemon` — `working-directory: local-wallet-daemon`, `cargo test --workspace`.
  **No `LW_CI_REPO_READ_TOKEN` / git credential step** — protocol is now an in-repo path
  dep, so there is no private git fetch.
- `ffi` — `working-directory: rust-core`, `cargo test -p wallet-ffi`.

Delete the two per-repo `.github/workflows/ci.yml` copies that were flat-copied in (their
logic is folded into the single workflow above).

### 6. Docs

Targeted updates only (not a full rewrite):

- `LOCAL_MONOREPO_SETUP.md`: replace the "Clone The Local Monorepo (siblings)" and
  "Enable Local Rust Path Overrides" sections with single-repo instructions.
- `CLAUDE.md`: update the "local monorepo (sibling checkouts + the local↔remote dependency
  swap)" section and the pin-bump workflow to describe in-repo path deps.

Duplicate `LICENSE-*`, `SECURITY.md`, `CONTRIBUTING.md`, `wallet-architecture.md` landing
inside the sub-dirs are left as-is (harmless); de-duplication is optional follow-up.

## Verification

Run from the worktree root after the changes:

- `cd local-wallet-protocol && cargo fmt --check && cargo clippy --workspace -- -D warnings && cargo test --workspace`
- `cd local-wallet-daemon && cargo fmt --check && cargo clippy --workspace -- -D warnings && cargo test --workspace`
- `cd rust-core && cargo test -p wallet-ffi`
- `cargo metadata --manifest-path rust-core/Cargo.toml --format-version 1 >/dev/null` resolves
  path deps with **no network fetch**; same for the daemon manifest.
- `grep -rn "local-wallet-protocol.git\|local-wallet-daemon.git" .` returns no Cargo git deps.
- `xcodegen generate` succeeds and the scheme points at the in-repo daemon path.

The macOS Xcode/Swift build stays a manual local check for this pass (CI scope is Rust-only).

## Assumptions

- The daemon workspace builds green on `ubuntu-latest` today (its existing CI already
  compiles `helios` from git and `rusqlite` bundled there).
- `wallet-ffi` and `wallet-node-api` are cross-platform Rust (no macOS-only deps), so the
  `ffi` job builds on ubuntu without `build-ffi.sh`/`cbindgen`.
- The original repos are reachable for the flat copy from the local sibling checkouts at
  `../local-wallet-protocol` and `../local-wallet-daemon`.
