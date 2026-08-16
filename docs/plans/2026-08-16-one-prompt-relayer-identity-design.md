# One-Prompt Relayer Identity Design

## Status

Approved on 2026-08-16. This design supersedes
`2026-08-16-relayer-provisioning-verification-regression-design.md`, whose
assumption that an attributes-only query bypasses a protected item's access
control was disproved by signed runtime evidence.

## Problem

The relayer secret is stored in a Keychain item protected by `.userPresence`.
The same item currently carries `VerifiedRelayerIdentity` in
`kSecAttrGeneric`. The app assumed it could read that public attribute without
authentication because it did not request `kSecValueData`.

That assumption is false on the supported macOS runtime. Security.framework
still evaluates the protected item's access control. When a query omits
`kSecUseAuthenticationContext`, it creates a new implicit `LAContext` and can
show another authentication dialog.

The affected signed run produced four authentication UI activations during one
Create Keys retry:

1. Initial public identity lookup: Touch ID.
2. Intended protected secret read: Touch ID.
3. Nested public identity lookup after the read: Touch ID.
4. Post-registration public identity verification: authentication UI and
   password fallback.

The root Secure Enclave lookup and both wallet-node registration probes did not
request authentication. The regression is entirely in relayer Keychain
identity lookup.

## Required Behavior

- Fresh relayer creation requires no authentication because the generated
  secret is already in app memory.
- Resuming setup with an existing relayer requires at most one authentication
  after the user explicitly chooses Create Keys or Retry.
- Dashboard launch, focus changes, status refresh, and funding display never
  prompt.
- Ordinary daemon launches remain secret-free.
- The app never treats UserDefaults, cached addresses, or daemon status alone
  as relayer identity authority.
- Key reference, chain, address, lifecycle, compromise state, and secret-derived
  identity mismatches fail closed.
- Concurrent provisioning cannot overwrite the canonical relayer secret or
  publish an identity derived from a losing secret.

## Considered Approaches

### Reuse one `LAContext` but keep metadata on the protected item

This reduces explicit onboarding to one prompt, but passive dashboard lookup
must either prompt or fail with interaction disabled. It does not satisfy the
product requirement.

### Trust wallet-node or cached settings for passive identity

This is simple but unsafe. A writable database or preference could redirect a
funding address without proving that the matching private key remains in
Keychain. It recreates the split-brain condition that registration hardening
was designed to prevent.

### Separate public and protected Keychain records

This is the selected design. The public identity is not secret material and is
stored in a separate, non-interactive Keychain item. The protected secret
remains under `.userPresence`. Public identity is useful only when it exactly
binds to wallet-node status, and authenticated paths independently derive the
same identity from the secret.

A cryptographic attestation signed by the relayer was also considered. It adds
canonical signing, recovery verification, domain separation, FFI, and migration
surface without protecting against the relevant threat better than the
existing app-only Keychain access group plus exact daemon binding. It is not
justified for this release.

## Storage Architecture

### Protected secret record

- Service: the existing relayer-secret Keychain service.
- Account: canonical chain-scoped key reference.
- Value: the 32-byte relayer secret.
- Accessibility: `WhenUnlockedThisDeviceOnly` with `.userPresence`.
- Read only during an explicit privileged action using a caller-supplied
  `LAContext`.
- Never queried by passive dashboard or lifecycle code.

New records no longer rely on `kSecAttrGeneric` as the passive identity store.
Legacy attributes may remain on existing items, but the app does not query them
without authentication.

### Immutable public identity records

- Separate Keychain service and the same canonical key reference as account.
- Value: versioned `VerifiedRelayerIdentity` metadata containing chain ID, key
  reference, and normalized address.
- Accessibility: `WhenUnlockedThisDeviceOnly`, without `.userPresence`.
- Restricted by the app's Keychain access group and device-only accessibility.
- Insert-only. An exact duplicate is idempotent; a mismatch fails closed.
- Every passive query explicitly forbids authentication UI. If a future storage
  mistake makes the item interactive, lookup fails instead of prompting.

The record is public metadata, not an independent signing or funding authority.
It is accepted for passive display only after
`RelayerIdentityBindingPolicy` verifies an exact match with fresh wallet-node
status.

### Append-only chain selection journal

Immutable per-key records do not identify which legitimate key is active. That
matters because rotation is shipped: trusting the daemon's selected key
reference would let a compromised daemon revive a legitimately stored retired
key.

A second public Keychain service stores an append-only state journal. Each item
uses `chainID:epoch` as its account and contains canonical, versioned state:

- chain ID and monotonically increasing epoch;
- digest of the previous state;
- optional active key reference, allowing an explicit post-deletion empty state;
- at most one pending rotation candidate key reference.

Each transition uses `SecItemAdd`, never `SecItemUpdate`. Account uniqueness is
the cross-process arbiter. Readers accept only the highest contiguous,
digest-linked sequence starting at genesis. A fork, gap, malformed state,
unknown identity, or conflicting transition fails closed.

The journal is not secret and uses the same prompt-free Data Protection
Keychain policy as public identity records. It constrains daemon status to an
identity that this app previously derived from an authenticated or freshly
generated secret.

## Provisioning Flow

### Fresh secret

1. Atomically insert the protected secret with `SecItemAdd`.
2. Only the winning process derives and inserts the public identity record.
3. Register the secret with wallet-node through the authenticated inherited
   descriptor.
4. Verify the secret-loaded daemon reports the exact identity.
5. Restart without secrets and verify the same durable identity is locked.
6. Insert or require the exact genesis chain state naming this key as active.
7. Re-read the public record and journal with authentication UI forbidden and require an
   exact match before publishing onboarding ready state.

This path shows no authentication prompt.

### Existing or interrupted secret

1. Read the public record without authentication. Its presence does not replace
   secret proof.
2. Use the single provisioning `LAContext` to read the protected secret once.
3. Derive the identity from the secret.
4. Insert the public record if missing, or require an exact match if present.
5. Run the same loaded and locked wallet-node registration probes.
6. Insert or require the exact genesis chain state naming this key as active.
7. Verify the public record and journal without authentication and publish
   ready.

All protected operations share the exact still-valid context, so this path
shows at most one authentication prompt.

## Race, Migration, and Failure Rules

- The protected secret's insertion-only Keychain item remains the cross-process
  winner selection point.
- A process that loses `SecItemAdd` discards its generated bytes and reads the
  winning secret with the one explicit authentication context.
- A crash after secret insertion but before public-record insertion is
  recoverable: the next explicit setup attempt authenticates once, derives the
  canonical identity, and inserts the missing public record.
- A missing public record for a legacy completed wallet is a migration-required
  state, not proof that the private key is missing. Migration occurs only after
  an explicit user action and one authenticated secret read.
- A malformed or mismatched public record is not overwritten automatically.
  The app reports identity verification failure and requires explicit reset or
  recovery. It never repairs identity from daemon status or settings.
- Concurrent journal writers propose the same next epoch. One `SecItemAdd`
  wins. A loser accepts an exact matching transition as idempotent success and
  rejects any different transition before installing or using its candidate.
- Deletion removes journal and public records before the protected secret. If cleanup is
  interrupted, the safe residual state is a recoverable protected secret with
  no passively trusted identity, never a public identity after secret deletion.
- Reset continues to use the existing single-instance gate and authorized reset
  context.

## Rotation Flow

Rotation retains the same one-action authorization boundary:

1. Read and validate the current journal head.
2. Create the insertion-only candidate secret and immutable public identity.
3. Append a new state with the old active key and the candidate as pending
   before asking wallet-node to install it.
4. Require wallet-node to report that exact candidate as `pending_funding`.
5. Reject another rotation while a pending candidate exists.
6. When status later reports exactly the authorized candidate as active and
   the prior active key as retiring or retired, append a promotion state with
   the candidate active and no pending key.

Promotion is prompt-free because the target was already authorized and stored
during the authenticated rotation action. The daemon controls when funding
makes the transition possible, but it cannot select an arbitrary stored key.

If the app crashes between journal and daemon mutations, passive UI blocks on
the mismatch. Explicit Retry completes the same candidate and never generates
another one. This keeps rotation recoverable without weakening identity
selection.

Deletion is also journaled. Deleting the pending candidate appends a state that
clears `pendingKeyRef`. Deleting the active key appends an empty state before
the public identity and protected secret are removed. Deleting a retired key
does not change the journal head. A replacement active key is appended from the
empty state only after the same secret-derived registration proof used by
onboarding. Interrupted deletion or replacement therefore becomes a blocked,
explicitly recoverable mismatch rather than silently selecting another stored
identity.

## Passive Dashboard and Privileged Actions

Dashboard refresh loads the journal-selected public identity, with
authentication UI forbidden, then binds it to the current daemon status. It
never reads the protected secret and never creates an `LAContext`. During
rotation it accepts only the journal's active identity or its single authorized
pending candidate under the exact lifecycle transition described above.

At the first money-moving operation, the app authenticates as already designed,
reads the secret, derives the identity, requires an exact match with both the
public record and current daemon status, and only then installs the secret in
wallet-node memory. The secret remains absent from normal launches.

## Testing and Acceptance

- Unit tests for public identity encoding, validation, insertion-only behavior,
  missing records, corruption, and mismatch failures.
- Journal tests for genesis, contiguous digest validation, forks, gaps,
  concurrent exact and conflicting transitions, one pending candidate, and
  authorized promotion.
- Provisioning tests for fresh zero-prompt flow, existing one-read flow,
  concurrent winner and loser behavior, interrupted migration, and refusal to
  publish ready before loaded and locked daemon proofs pass.
- Dashboard tests proving passive lookup uses only the public store and fails
  closed on missing, mismatched, retired, or daemon-selected unauthorized
  identity.
- Authentication audits proving public lookup forbids UI and secret reads reuse
  the caller's one provisioning context.
- Signed Keychain integration tests proving the public record remains readable
  with interaction disabled while the protected secret remains inaccessible
  without authentication.
- Manual signed runtime acceptance using unified logs:
  - Fresh Create Keys: zero Local Wallet authentication UI activations.
  - Existing-key Create Keys or Retry: exactly one activation.
  - Dashboard launch, focus change, and refresh: zero activations.
- Full Swift suite, focused signed Xcode tests, wallet-node inherited-descriptor
  lifecycle tests, and a security review of the final diff.

The test suite must assert observable authentication budgets, not merely inspect
source strings. A source-shape assertion alone did not catch this regression and
is not adequate evidence.
