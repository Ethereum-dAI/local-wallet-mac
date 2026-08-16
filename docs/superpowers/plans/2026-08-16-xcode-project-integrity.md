# Xcode Project Integrity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent security and release builds from consuming an Xcode project that has drifted from canonical `project.yml`, without modifying contributors' local project files.

**Architecture:** A single Bash verifier generates the project inside a temporary repository-shaped mirror and compares the generated `project.pbxproj` with the committed one. The mirror copies the enumerated app sources and generated plist inputs instead of symlinking writable paths back into the checkout. The hardening gate and packaging script reuse that verifier before invoking `xcodebuild`.

**Tech Stack:** Bash, XcodeGen 2.45.4+, Ruby/Psych, `cmp`, `diff`, macOS `mktemp`.

## Global Constraints

- Do not regenerate or edit the real `LocalWallet.xcodeproj` during verification.
- Keep `project.yml` as the canonical configuration.
- Reuse one verifier from both release-facing scripts.
- Preserve local signing overrides in the developer's original checkout.

---

### Task 1: Add and integrate deterministic project verification

**Files:**
- Create: `scripts/verify-xcode-project.sh`
- Create: `scripts/test-verify-xcode-project.sh`
- Modify: `scripts/run-bundler-key-hardening-gate.sh`
- Modify: `scripts/package-macos-demo.sh`
- Modify: `scripts/README.md`

**Interfaces:**
- Consumes: `project.yml`, `LocalWallet.xcodeproj/project.pbxproj`, `local-llm/`, `swift-bridge/`, and `wallet-macos/`.
- Produces: `scripts/verify-xcode-project.sh`, exiting zero only when temporary XcodeGen output byte-matches the committed project. `--repo-root PATH` is an explicit test-only root override; production callers use the script's own repository root.

- [x] **Step 1: Write the failing regression test**

Create `scripts/test-verify-xcode-project.sh` so it copies the canonical spec and project into a disposable root, verifies the canonical pair, proves direct and included generation hooks are rejected before execution, changes `CODE_SIGN_ENTITLEMENTS` in the copied spec, then requires the verifier to fail without changing the copied canonical inputs.

- [x] **Step 2: Run the regression test and confirm the verifier is missing**

Run: `bash scripts/test-verify-xcode-project.sh`

Expected: FAIL because `scripts/verify-xcode-project.sh` does not exist.

- [x] **Step 3: Implement the shared verifier**

Create `scripts/verify-xcode-project.sh` with strict Bash mode, dependency/input checks, pre-execution YAML hook/include rejection, immutable input snapshots, a `mktemp` mirror, cleanup trap, copied source/plist inputs, sanitized temporary `xcodegen`, byte comparison, post-run mutation checks, and a bounded mismatch diff.

- [x] **Step 4: Wire both build paths to the verifier**

Invoke `scripts/verify-xcode-project.sh` before `xcodebuild` in both `scripts/run-bundler-key-hardening-gate.sh` and `scripts/package-macos-demo.sh`. Update `scripts/README.md` to describe non-mutating verification instead of in-place generation.

- [x] **Step 5: Run focused verification**

Run:

```bash
bash -n scripts/verify-xcode-project.sh scripts/test-verify-xcode-project.sh scripts/run-bundler-key-hardening-gate.sh scripts/package-macos-demo.sh
bash scripts/test-verify-xcode-project.sh
scripts/verify-xcode-project.sh
git diff --check
```

Expected: all commands PASS; the negative fixture is rejected by the test harness.

- [x] **Step 6: Commit with the audited merge**

Stage the verifier, regression test, call sites, documentation, design, and plan. Commit them as part of the already-resolved audited merge so the final merge commit remains the single history-preserving synchronization point.
