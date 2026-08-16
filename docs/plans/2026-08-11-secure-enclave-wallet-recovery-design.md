# Secure Enclave Wallet Recovery Design

## Context

The app currently stores wallet metadata at a shared, bundle-independent path:
`~/Library/Application Support/LocalWallet/wallet-record.json`. That record contains a
static Secure Enclave key tag and the wallet public key.

Secure Enclave keychain items are scoped to the app's signing identity and keychain
access group. If the development team or bundle identifier changes, the metadata can
remain readable while the private key is no longer accessible. Because bootstrap only
compares the stored key tag with the configured tag, it can accept stale metadata and
enter the dashboard. The failure is then discovered much later when a signing operation
throws `missingKeyReference`.

This is a broken state: the UI presents a wallet whose private signing key the current
app cannot use.

## Goals

- Detect an inaccessible or mismatched wallet key before entering the dashboard or
  performing wallet operations.
- Validate the actual accessible Secure Enclave key, not just its configured tag.
- Never silently create a replacement key behind existing wallet metadata.
- Preserve existing metadata until the user explicitly chooses recovery.
- Give the user an actionable, honest recovery path.
- Reuse the existing wallet-reset pipeline rather than creating a second cleanup path.

## Non-goals

- Recovering a Secure Enclave private key that is no longer accessible to the current
  signing identity.
- Moving a Secure Enclave key between keychain access groups.
- Preserving this unreleased development wallet after the user explicitly resets it.
- Weakening authentication or signing protections to avoid the recovery state.

## Design

### Central key validation

Add one reusable validation operation at the key-store boundary. Given the stored wallet
record, it loads the configured key reference without creating a key, derives the public
key coordinates, and returns one of three states:

- `available`: the key exists and its public key matches the wallet record.
- `missing`: no accessible key exists for the current signing identity.
- `mismatch`: a key exists at the tag but its public key does not match the record.

The validator must remain read-only. In particular, it must not call the provisioning
operation that creates a key when none exists.

### Bootstrap gate

During application bootstrap, after reading wallet metadata and checking its key tag,
validate the actual key. If it is missing or mismatched, stop bootstrap before account
inspection, daemon startup, funding, or dashboard presentation. Store a structured
recovery state that the root UI can route on.

Matching metadata and key material continue through the existing bootstrap path.

### Provisioning gate

The onboarding provisioning service must use the same validator. Existing wallet
metadata is reusable only when the accessible key matches its stored public key. Missing
or mismatched key material produces a recovery-required error; it must not create a new
key while keeping the old wallet record.

### Recovery UI

Present a dedicated pre-dashboard recovery screen with:

- Title: `Wallet key unavailable`
- A concise explanation that the signing key was removed or is unavailable to the
  current app identity, so the existing wallet cannot safely be used.
- A destructive `Reset local wallet` action.
- A warning that resetting removes the local wallet identity and local wallet data and
  returns to onboarding.

The screen must not claim that the old key can be recovered. It must not reset
automatically. Dismissing or quitting leaves the metadata untouched.

### Reset behavior

The recovery action delegates to the existing wallet reset coordinator. It clears the
current wallet metadata, onboarding state, daemon/runtime state, and any key material
accessible to the current signing identity. An old key belonging to a previous keychain
access group may remain as an inaccessible orphan because the current app cannot delete
it.

After reset, route to onboarding. Provisioning then creates a fresh wallet under the
current signing identity.

### Error model

Represent recovery as a structured application state or error with a reason (`missing`
or `mismatch`) rather than parsing strings. User-facing copy is produced in one place so
bootstrap, onboarding, and recovery UI stay consistent.

## Security properties

- Fail closed when the private key is unavailable or does not match metadata.
- Never mint a replacement key without explicit user consent to reset.
- Never sign with a key that differs from the wallet record.
- Keep the existing rule that ordinary signing failures do not provision keys.
- Avoid authentication prompts merely to discover key availability when Keychain permits
  public-key inspection without user presence; signing remains authenticated separately.

## Tests

- A matching key and wallet record allow bootstrap.
- A missing key blocks bootstrap and exposes recovery state.
- A mismatched public key blocks bootstrap and exposes recovery state.
- Validation never creates a key.
- Provisioning refuses stale metadata instead of creating a replacement key.
- Reset from recovery returns the app to onboarding.
- Recovery error copy is actionable and does not promise key recovery.
- Existing fail-closed signing tests continue to pass.
