# Xcode Project Integrity Design

## Problem

`project.yml` is the repository's canonical Xcode configuration, while
`LocalWallet.xcodeproj` is committed generated output. The hardening gate and
packaging script currently build the committed project without proving it still
matches the canonical spec. Regenerating in place would close that gap, but it
would also overwrite contributors' local signing overrides.

## Decision

Add one shared, non-mutating verifier. It creates a temporary repository-shaped
mirror, copies `project.yml` and the app inputs XcodeGen enumerates, creates
placeholder local-package roots, generates `LocalWallet.xcodeproj` in that
mirror, and byte-compares the generated `project.pbxproj` with the committed
file. It never symlinks a generated output path back into the checkout, so
XcodeGen cannot write through the mirror into the real project or plist files.

Both `run-bundler-key-hardening-gate.sh` and `package-macos-demo.sh` invoke the
same verifier before `xcodebuild`. A mismatch fails with an explicit instruction
to run `xcodegen generate` and review the resulting project diff.

The verifier derives the production repository root from its own location. Its
only override is an explicit `--repo-root PATH` argument used by the disposable
regression fixture, so an ambient environment variable cannot redirect a real
release check to another checkout.

Before invoking XcodeGen, the verifier parses the full YAML document stream and
rejects `include`, `preGenCommand`, `postGenCommand`, aliases, and complex keys.
This prevents generation-time code from mutating the checkout or changing the
comparison target. XcodeGen then runs from the scratch directory with a minimal
environment. Immutable pre-run copies are used for comparison, and the verifier
also confirms the live spec, project, plist, and entitlements are unchanged.

## Failure handling

- Missing `xcodegen`, `project.yml`, the committed project, or a required source
  root fails before any build.
- Missing Ruby, unsupported YAML features, includes, or generation hooks fail
  before XcodeGen can execute.
- A generation failure propagates unchanged.
- A byte mismatch prints a bounded unified diff and exits nonzero.
- Temporary files are removed on every exit path.

## Verification

- The current canonical spec/project pair passes.
- A disposable fixture with a changed entitlement path fails.
- Direct and included generation hooks are rejected without execution.
- The verifier leaves the committed project checksum unchanged.
- Both release-facing scripts call the verifier before `xcodebuild`.
