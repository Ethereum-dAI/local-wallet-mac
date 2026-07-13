# Consolidate Local Wallet Monorepo — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring `local-wallet-protocol` and `local-wallet-daemon` into `local-wallet-mac` as nested sub-workspaces with in-repo path deps, and add a Rust-only CI workflow.

**Architecture:** Flat-copy each sibling's tracked tree into a top-level dir inside `local-wallet-mac`. Keep three independent Cargo workspaces (no root `Cargo.toml`). Replace git-pinned protocol/daemon deps with in-repo relative path deps and delete the `.cargo/config.toml` override machinery. One GitHub Actions workflow runs fmt/clippy/test for all three on ubuntu.

**Tech Stack:** Rust (Cargo workspaces), Swift/Xcode (xcodegen), GitHub Actions, `git archive` for the flat copy.

## Global Constraints

- Rust baseline: `edition = "2021"`, `rust-version = "1.91"` (do not change).
- License: all crates `MIT OR Apache-2.0` (unchanged).
- Never commit to `main` in any repo; all work stays on branch `consolidate-monorepo`.
- Work happens in the worktree: `/Users/gabrielfior/code/ef/local-wallet-mac/.worktrees/consolidate-monorepo` (this is `$WT` below).
- Copy sources are the local sibling checkouts:
  - Protocol: `/Users/gabrielfior/code/ef/local-wallet-protocol`
  - Daemon: `/Users/gabrielfior/code/ef/local-wallet-daemon`
- No root `Cargo.toml` may be created in `local-wallet-mac/` (keeps the three workspaces independent).
- Crate dir names ≠ crate names: `wallet-signature`→`crates/signature`, `wallet-kernel`→`crates/kernel`, `wallet-addresses`→`crates/wallet-addresses`.
- Commit message trailer for every commit:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

### Task 1: Flat-copy `local-wallet-protocol` into the worktree

**Files:**
- Create: `$WT/local-wallet-protocol/**` (entire tracked tree at protocol `main`)

**Interfaces:**
- Produces: an in-repo protocol workspace with crates `crates/signature`, `crates/kernel`, `crates/wallet-addresses`, its own `Cargo.toml`/`Cargo.lock`, `tooling/`, and (temporarily) `.github/workflows/ci.yml` + `.cargo/config.toml.example` (removed in later tasks).

- [ ] **Step 1: Confirm the copy source is clean and on a known ref**

Run:
```bash
git -C /Users/gabrielfior/code/ef/local-wallet-protocol log --oneline -1 main
git -C /Users/gabrielfior/code/ef/local-wallet-protocol ls-files | grep -E '^crates/(signature|kernel|wallet-addresses)/Cargo.toml$'
```
Expected: prints protocol main tip (`8e7d8f9 …`) and the three crate manifests.

- [ ] **Step 2: Export protocol `main` tree into the worktree**

Run:
```bash
mkdir -p "$WT/local-wallet-protocol"
git -C /Users/gabrielfior/code/ef/local-wallet-protocol archive main | tar -x -C "$WT/local-wallet-protocol"
```
`git archive` includes only tracked files — no `.git/`, no `target/`, no untracked local `.cargo/config.toml`.

- [ ] **Step 3: Verify the copied tree**

Run:
```bash
ls "$WT/local-wallet-protocol/crates"
test -f "$WT/local-wallet-protocol/Cargo.toml" && test -f "$WT/local-wallet-protocol/Cargo.lock" && echo OK
test ! -d "$WT/local-wallet-protocol/.git" && test ! -d "$WT/local-wallet-protocol/target" && echo "no-git-no-target OK"
```
Expected: `kernel signature wallet-addresses`, `OK`, `no-git-no-target OK`.

- [ ] **Step 4: Confirm protocol still builds in place (baseline for the copy)**

Run:
```bash
(cd "$WT/local-wallet-protocol" && cargo build --workspace 2>&1 | tail -5)
```
Expected: `Finished` (protocol has no sibling deps, so it builds standalone).

- [ ] **Step 5: Commit**

```bash
cd "$WT"
git add local-wallet-protocol
git commit -m "chore: vendor local-wallet-protocol into the monorepo (flat copy of main)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Flat-copy `local-wallet-daemon` into the worktree

**Files:**
- Create: `$WT/local-wallet-daemon/**` (entire tracked tree at daemon `main`)

**Interfaces:**
- Consumes: nothing yet (deps rewired in Task 3).
- Produces: an in-repo daemon workspace with crates `wallet-node`, `wallet-bundler`, `wallet-chain`, `wallet-node-api`, `wallet-node-store`, its own `Cargo.toml`/`Cargo.lock`, `scripts/`, `documentation/`, and (temporarily) `.github/workflows/ci.yml` + `.cargo/config.toml.example`.

- [ ] **Step 1: Confirm the copy source**

Run:
```bash
git -C /Users/gabrielfior/code/ef/local-wallet-daemon log --oneline -1 main
git -C /Users/gabrielfior/code/ef/local-wallet-daemon ls-files crates | grep -c Cargo.toml
```
Expected: prints daemon main tip; count of crate manifests ≥ 5.

- [ ] **Step 2: Export daemon `main` tree into the worktree**

Run:
```bash
mkdir -p "$WT/local-wallet-daemon"
git -C /Users/gabrielfior/code/ef/local-wallet-daemon archive main | tar -x -C "$WT/local-wallet-daemon"
```

- [ ] **Step 3: Verify the copied tree**

Run:
```bash
ls "$WT/local-wallet-daemon/crates"
test -f "$WT/local-wallet-daemon/Cargo.toml" && test -f "$WT/local-wallet-daemon/Cargo.lock" && echo OK
test ! -d "$WT/local-wallet-daemon/.git" && test ! -d "$WT/local-wallet-daemon/target" && echo "no-git-no-target OK"
```
Expected: the five crate dirs, `OK`, `no-git-no-target OK`.

- [ ] **Step 4: Commit** (build deferred to Task 3, since deps are still git-pinned)

```bash
cd "$WT"
git add local-wallet-daemon
git commit -m "chore: vendor local-wallet-daemon into the monorepo (flat copy of main)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Rewire the daemon to in-repo path deps

**Files:**
- Modify: `$WT/local-wallet-daemon/Cargo.toml` (`[workspace.dependencies]` protocol entries)
- Delete: `$WT/local-wallet-daemon/.cargo/config.toml.example` (and `.cargo/` if now empty)
- Modify: `$WT/local-wallet-daemon/Cargo.lock` (regenerated by cargo)

**Interfaces:**
- Consumes: protocol crates from Task 1 at `../local-wallet-protocol/crates/{signature,kernel,wallet-addresses}`.
- Produces: a daemon workspace that resolves protocol via path, with no git source and no `.cargo` override.

- [ ] **Step 1: Replace the three protocol git deps with path deps**

In `$WT/local-wallet-daemon/Cargo.toml`, replace the three `wallet-*` git lines under `[workspace.dependencies]` with:
```toml
wallet-signature = { path = "../local-wallet-protocol/crates/signature" }
wallet-kernel    = { path = "../local-wallet-protocol/crates/kernel" }
wallet-addresses = { path = "../local-wallet-protocol/crates/wallet-addresses" }
```
Leave all other dependency lines (alloy, helios, tokio, rusqlite, …) unchanged.

- [ ] **Step 2: Remove the override machinery**

Run:
```bash
rm -f "$WT/local-wallet-daemon/.cargo/config.toml.example"
rmdir "$WT/local-wallet-daemon/.cargo" 2>/dev/null || true
```

- [ ] **Step 3: Verify no git source for protocol remains, then refresh the lockfile**

Run:
```bash
grep -n "local-wallet-protocol.git" "$WT/local-wallet-daemon/Cargo.toml" || echo "no-git-dep OK"
(cd "$WT/local-wallet-daemon" && cargo metadata --format-version 1 >/dev/null && echo "metadata OK")
```
Expected: `no-git-dep OK`, then `metadata OK` (resolves path deps with no network fetch for protocol).

- [ ] **Step 4: Build and test the daemon workspace**

Run (slow — compiles helios + rusqlite):
```bash
(cd "$WT/local-wallet-daemon" && cargo build --workspace 2>&1 | tail -5)
(cd "$WT/local-wallet-daemon" && cargo fmt --check && cargo clippy --workspace -- -D warnings && cargo test --workspace 2>&1 | tail -15)
```
Expected: build `Finished`; fmt clean; clippy no warnings; tests pass.
If protocol API drift breaks the build, fall back to copying protocol at rev `ea28622aabcc4b0256d86fef8e0fee4d9cd37858` (redo Task 1 Step 2 with that rev) — see the spec's fallback note.

- [ ] **Step 5: Commit**

```bash
cd "$WT"
git add local-wallet-daemon
git commit -m "refactor(daemon): consume protocol via in-repo path deps; drop .cargo override

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Rewire `rust-core` (wallet-ffi) to in-repo path deps

**Files:**
- Modify: `$WT/rust-core/Cargo.toml` (`[workspace.dependencies]` protocol + wallet-node-api)
- Delete: `$WT/rust-core/.cargo/config.toml.example` (and `.cargo/` if now empty)
- Modify: `$WT/.gitignore` (remove the `rust-core/.cargo/config.toml` line)
- Modify: `$WT/rust-core/Cargo.lock` (regenerated by cargo)

**Interfaces:**
- Consumes: protocol crates (Task 1) and `wallet-node-api` (Task 2) via path.
- Produces: a `wallet-ffi` workspace with no git deps and no `.cargo` override.

- [ ] **Step 1: Replace git deps with path deps**

In `$WT/rust-core/Cargo.toml` `[workspace.dependencies]`, replace the four git-pinned lines with:
```toml
wallet-signature = { path = "../local-wallet-protocol/crates/signature" }
wallet-kernel    = { path = "../local-wallet-protocol/crates/kernel" }
wallet-addresses = { path = "../local-wallet-protocol/crates/wallet-addresses" }
wallet-node-api  = { path = "../local-wallet-daemon/crates/wallet-node-api" }
```
Leave the remaining deps (alloy-primitives, sha2, zeroize, hex-literal, p256, serde, serde_json) unchanged.

- [ ] **Step 2: Remove the override machinery and gitignore line**

Run:
```bash
rm -f "$WT/rust-core/.cargo/config.toml.example"
rmdir "$WT/rust-core/.cargo" 2>/dev/null || true
```
Then edit `$WT/.gitignore` and delete the line `rust-core/.cargo/config.toml`.

- [ ] **Step 3: Verify no git deps remain and metadata resolves**

Run:
```bash
grep -nE "local-wallet-(protocol|daemon)\.git" "$WT/rust-core/Cargo.toml" || echo "no-git-dep OK"
(cd "$WT/rust-core" && cargo metadata --format-version 1 >/dev/null && echo "metadata OK")
```
Expected: `no-git-dep OK`, `metadata OK`.

- [ ] **Step 4: Build and test wallet-ffi**

Run:
```bash
(cd "$WT/rust-core" && cargo build -p wallet-ffi 2>&1 | tail -5)
(cd "$WT/rust-core" && cargo fmt --check && cargo clippy -p wallet-ffi -- -D warnings && cargo test -p wallet-ffi 2>&1 | tail -15)
```
Expected: build `Finished`; fmt clean; clippy no warnings; tests pass.

- [ ] **Step 5: Commit**

```bash
cd "$WT"
git add rust-core .gitignore
git commit -m "refactor(ffi): consume protocol + wallet-node-api via in-repo path deps

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Fix hardcoded sibling path references

**Files:**
- Modify: `$WT/project.yml:73-74` (scheme env vars)
- Modify: `$WT/scripts/package-macos-demo.sh:21` (DAEMON_REPO default)
- Modify: `$WT/scripts/run-bundler-key-hardening-gate.sh:11,14,17,20,23,26,29` (LW_DAEMON_DIR default)
- Modify: `$WT/LocalWallet.xcodeproj/**` (regenerated by xcodegen, if available)

**Interfaces:**
- Produces: build/scheme/scripts that resolve the daemon at the in-repo `local-wallet-daemon/` instead of `../local-wallet-daemon`.

- [ ] **Step 1: Update the Xcode scheme env vars in project.yml**

In `$WT/project.yml`, under `schemes.LocalWalletApp.run.environmentVariables`, change both values from
`$(SRCROOT)/../local-wallet-daemon/target/release/wallet-node` to
`$(SRCROOT)/local-wallet-daemon/target/release/wallet-node`.

- [ ] **Step 2: Update the two scripts' default daemon dir**

In `$WT/scripts/package-macos-demo.sh`, change the `DAEMON_REPO` default from
`$REPO_ROOT/../local-wallet-daemon` to `$REPO_ROOT/local-wallet-daemon`.

In `$WT/scripts/run-bundler-key-hardening-gate.sh`, change the default in every
`${LW_DAEMON_DIR:-${ROOT_DIR}/../local-wallet-daemon}` to
`${LW_DAEMON_DIR:-${ROOT_DIR}/local-wallet-daemon}`.

- [ ] **Step 3: Verify no stale `../local-wallet-daemon` defaults remain**

Run:
```bash
grep -rn "\.\./local-wallet-daemon" "$WT/project.yml" "$WT/scripts" || echo "no-stale-refs OK"
```
Expected: `no-stale-refs OK`.

- [ ] **Step 4: Regenerate the Xcode project if xcodegen is available**

Run:
```bash
if command -v xcodegen >/dev/null; then (cd "$WT" && xcodegen generate) && echo "xcodegen OK"; else echo "xcodegen not installed — skipping (regenerate before an Xcode build)"; fi
grep -rn "\.\./local-wallet-daemon" "$WT/LocalWallet.xcodeproj" || echo "project has no stale daemon ref"
```
Expected: either `xcodegen OK` + `project has no stale daemon ref`, or the skip message (noted for manual follow-up).

- [ ] **Step 5: Commit**

```bash
cd "$WT"
git add project.yml scripts LocalWallet.xcodeproj
git commit -m "chore: point scheme + scripts at the in-repo local-wallet-daemon

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Add the consolidated CI workflow

**Files:**
- Create: `$WT/.github/workflows/ci.yml`
- Delete: `$WT/local-wallet-protocol/.github/workflows/ci.yml`
- Delete: `$WT/local-wallet-daemon/.github/workflows/ci.yml`

**Interfaces:**
- Produces: one workflow with three ubuntu jobs (`protocol`, `daemon`, `ffi`), each fmt→clippy→test. No repo-read token (protocol is an in-repo path dep).

- [ ] **Step 1: Write the workflow**

Create `$WT/.github/workflows/ci.yml`:
```yaml
name: CI
on: [push, pull_request]
jobs:
  protocol:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: local-wallet-protocol
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - run: cargo fmt --check
      - run: cargo clippy --workspace -- -D warnings
      - run: cargo test --workspace
  daemon:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: local-wallet-daemon
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - run: cargo fmt --check
      - run: cargo clippy --workspace -- -D warnings
      - run: cargo test --workspace
  ffi:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: rust-core
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - run: cargo fmt --check
      - run: cargo clippy -p wallet-ffi -- -D warnings
      - run: cargo test -p wallet-ffi
```

- [ ] **Step 2: Delete the two vendored per-repo workflows**

Run:
```bash
rm -f "$WT/local-wallet-protocol/.github/workflows/ci.yml"
rm -f "$WT/local-wallet-daemon/.github/workflows/ci.yml"
```

- [ ] **Step 3: Validate the workflow YAML parses**

Run:
```bash
python3 -c "import yaml,sys; yaml.safe_load(open('$WT/.github/workflows/ci.yml')); print('yaml OK')"
```
Expected: `yaml OK`.

- [ ] **Step 4: Commit**

```bash
cd "$WT"
git add .github local-wallet-protocol/.github local-wallet-daemon/.github
git commit -m "ci: add consolidated rust workflow (protocol/daemon/ffi on ubuntu)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Update the monorepo docs

**Files:**
- Modify: `$WT/LOCAL_MONOREPO_SETUP.md` (clone + path-override sections)
- Modify: `$WT/CLAUDE.md` (local-monorepo / dependency-swap / pin-bump sections)

**Interfaces:**
- Produces: docs that describe a single-repo checkout with in-repo path deps (no siblings, no override file, no pin-bump dance).

- [ ] **Step 1: Rewrite the setup guide's clone/override sections**

In `$WT/LOCAL_MONOREPO_SETUP.md`:
- Replace the "Clone The Local Monorepo" section (three `git clone` siblings) with a single
  `git clone https://github.com/Ethereum-dAI/local-wallet-mac.git` and note that protocol and
  daemon now live at `local-wallet-mac/local-wallet-protocol` and `local-wallet-mac/local-wallet-daemon`.
- Delete the "Enable Local Rust Path Overrides" section entirely (no `.cargo/config.toml` copy needed).
- Update the "Build The Daemon" section: `cd local-wallet-daemon` (not `../local-wallet-daemon`).

- [ ] **Step 2: Update CLAUDE.md's cross-repo mechanics**

In `$WT/CLAUDE.md`:
- In "The local monorepo (sibling checkouts + the local↔remote dependency swap)", replace the
  sibling-layout diagram and the pinned-rev-vs-path-override explanation with: the three components
  now live in one repo and depend on each other via in-repo `path` deps (no git pins, no
  `.cargo/config.toml` override).
- Remove/replace the "Bumping the protocol pin" subsection — protocol changes are now picked up
  directly via the path dep; no rev bump or lockfile re-pin is required.
- In "Common commands", update daemon paths from `../local-wallet-daemon` to `local-wallet-daemon`,
  and note CI now runs from `.github/workflows/ci.yml` in this repo.

- [ ] **Step 3: Verify no stale sibling/override guidance remains in the two docs**

Run:
```bash
grep -nE "config\.toml\.example|cp rust-core/\.cargo|git clone https://github.com/Ethereum-dAI/local-wallet-(protocol|daemon)" "$WT/LOCAL_MONOREPO_SETUP.md" "$WT/CLAUDE.md" || echo "docs clean OK"
```
Expected: `docs clean OK`.

- [ ] **Step 4: Commit**

```bash
cd "$WT"
git add LOCAL_MONOREPO_SETUP.md CLAUDE.md
git commit -m "docs: describe single-repo layout with in-repo path deps

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Final end-to-end verification

**Files:** none (verification only)

**Interfaces:**
- Consumes: everything from Tasks 1–7.
- Produces: a green, self-contained monorepo with no git deps and no override files.

- [ ] **Step 1: No Cargo git deps anywhere, no override files left**

Run:
```bash
cd "$WT"
grep -rn "local-wallet-\(protocol\|daemon\)\.git" rust-core/Cargo.toml local-wallet-daemon/Cargo.toml && echo "FAIL: git dep remains" || echo "no-git-deps OK"
find . -path ./.git -prune -o -name "config.toml.example" -print | grep -q . && echo "FAIL: override example remains" || echo "no-override-example OK"
```
Expected: `no-git-deps OK`, `no-override-example OK`.

- [ ] **Step 2: All three workspaces resolve offline**

Run:
```bash
cd "$WT"
CARGO_NET_OFFLINE=true cargo metadata --manifest-path local-wallet-protocol/Cargo.toml --format-version 1 >/dev/null && echo "protocol meta OK"
CARGO_NET_OFFLINE=true cargo metadata --manifest-path local-wallet-daemon/Cargo.toml   --format-version 1 >/dev/null && echo "daemon meta OK"
CARGO_NET_OFFLINE=true cargo metadata --manifest-path rust-core/Cargo.toml             --format-version 1 >/dev/null && echo "ffi meta OK"
```
Expected: three `… meta OK` lines (path deps resolve without network).

- [ ] **Step 3: fmt + clippy + test, all three workspaces**

Run:
```bash
cd "$WT"
(cd local-wallet-protocol && cargo fmt --check && cargo clippy --workspace -- -D warnings && cargo test --workspace) && echo "PROTOCOL GREEN"
(cd local-wallet-daemon   && cargo fmt --check && cargo clippy --workspace -- -D warnings && cargo test --workspace) && echo "DAEMON GREEN"
(cd rust-core             && cargo fmt --check && cargo clippy -p wallet-ffi -- -D warnings && cargo test -p wallet-ffi) && echo "FFI GREEN"
```
Expected: `PROTOCOL GREEN`, `DAEMON GREEN`, `FFI GREEN`.

- [ ] **Step 4: Confirm tree shape and clean status**

Run:
```bash
cd "$WT"
ls -d local-wallet-protocol local-wallet-daemon rust-core wallet-macos && echo "layout OK"
test ! -f Cargo.toml && echo "no-root-workspace OK"
git status --short
```
Expected: `layout OK`, `no-root-workspace OK`, and a clean (or fully-committed) status.

- [ ] **Step 5: Invoke the finishing-a-development-branch skill**

Use `superpowers:finishing-a-development-branch` to decide how to integrate (open PR against
`Ethereum-dAI/local-wallet-mac` `main`, or hand off). Do not push or open a PR without the user's go-ahead.

---

## Self-Review

**Spec coverage:**
- Flat copy (no history) → Tasks 1, 2 (`git archive`, excludes `.git`). ✓
- Nested sub-workspaces, no root Cargo.toml → layout in Tasks 1–2, asserted Task 8 Step 4. ✓
- Git-pins → path deps → Tasks 3, 4. ✓
- Remove override machinery (`.cargo/config.toml.example` ×2, gitignore line) → Tasks 3, 4; asserted Task 8 Step 1. ✓
- Fix path refs (project.yml, 2 scripts, xcodegen) → Task 5. ✓
- Rust-only ubuntu CI (protocol/daemon/ffi), no token, delete vendored workflows → Task 6. ✓
- Docs (LOCAL_MONOREPO_SETUP.md, CLAUDE.md) → Task 7. ✓
- Verification (fmt/clippy/test ×3, offline metadata, no git deps) → Task 8. ✓
- Non-goals respected: no macOS CI job; original repos untouched; no unrelated code changes. ✓

**Placeholder scan:** No TBD/TODO; every edit step names exact files, lines, and content. ✓

**Type/name consistency:** Path-dep crate dirs (`crates/signature`, `crates/kernel`, `crates/wallet-addresses`, `crates/wallet-node-api`) are identical across Tasks 3, 4, and 8. Worktree path `$WT` used consistently. ✓
