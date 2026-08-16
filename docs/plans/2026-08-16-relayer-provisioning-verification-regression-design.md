# Relayer Provisioning Verification Regression Design

## Problem

Commit `9199007` added a post-registration call to
`BundlerKeyStore.verifiedIdentity(forKeyRef:)`. That shared helper creates a
new noninteractive `LAContext` and attaches it to an attributes-only Keychain
query for a user-presence-protected item. In the signed macOS app, the
authentication context causes Keychain to hide the item even though an
authenticated read of the same secret succeeds.

The result is a false `localRelayerKeyMissing` failure after both relayer
registration probes have already succeeded. The relayer secret and the
wallet-node public mapping still match; onboarding refuses to advance. The
same helper also gates dashboard identity and funding state, so bypassing only
the onboarding check would move the failure to the dashboard.

## Required behavior

- Fresh key creation must not add a Touch ID or password prompt.
- Reading an existing or legacy key may authenticate once as part of the
  explicit Create Keys action.
- The app must continue to fail closed on a secret, key reference, chain,
  address, lifecycle, or compromise-state mismatch.
- Daemon launches outside an explicit privileged action remain secret-free and
  prompt-free.
- A missing relayer secret must never be silently replaced while wallet-node
  still has a public mapping for the old secret.

## Design

Repair the shared prompt-free identity lookup rather than bypassing it.
`verifiedIdentity(forKeyRef:)` will continue to request
`kSecReturnAttributes`, but it will not attach `kSecUseAuthenticationContext`
and will never request `kSecReturnData`.

Apple's Security SDK defines returned Keychain attributes as non-encrypted and
states that item data is the secret material that can require authentication.
Attaching an unauthenticated context with `interactionNotAllowed` to this
attributes-only query is therefore both unnecessary and the source of the
false negative.

Onboarding publishes the ready state only after all existing proofs succeed:

1. Provisioning selects the canonical Keychain secret.
   - A fresh process wins an atomic, immutable `SecItemAdd` and retains the
     exact inserted secret in memory for the duration of the action.
   - A process that finds an existing or legacy item authenticates once and
     reads the canonical secret from Keychain.
2. The app derives `VerifiedRelayerIdentity` from that secret.
3. wallet-node launches with the secret through the trusted inherited pipe,
   derives the address independently, and must report the exact expected
   identity with `keyLoaded == true`.
4. wallet-node terminates and restarts without the secret. It must report the
   same active identity with `keyLoaded == false`.
5. The corrected prompt-free Keychain attribute lookup must return the exact
   registered identity.
6. Only then does onboarding expose the funding address and advance.

The same corrected helper remains the authority for passive dashboard identity
binding. Atomic insertion continues to close the concurrent-provisioning
overwrite race, while subsequent privileged operations still read the secret
from Keychain and fail closed if it is unavailable.

## Rejected approaches

### Remove only the onboarding persistence check

This merely moves the false-negative failure to the dashboard, which uses the
same prompt-free helper for funding and top-up gating.

### Re-read the secret after registration

This can trigger an unnecessary authentication on fresh setup and loads secret
material when an attributes-only verification is sufficient.

### Store a second prompt-free public identity record

This creates another authority that must be kept synchronized and
cryptographically bound to the protected secret. It increases attack surface
without improving the current proof.

### Trust cached settings or the daemon mapping

Neither proves possession of the private key and would reopen the split-brain
failure that the relayer hardening is intended to prevent.

## Verification

- Add a signed Keychain regression test proving the attributes-only lookup
  returns the exact stored identity without authentication or secret data.
- Add an onboarding regression test proving successful loaded and locked
  registration probes advance to ready through the corrected persistence
  check.
- Preserve dashboard source and behavior tests proving passive identity checks
  never request the protected value or trigger authentication.
- Preserve tests for fresh atomic insertion, concurrent loser canonicalization,
  existing and legacy authenticated reads, and every identity-binding failure.
- Run the full Swift package suite.
- Run signed Xcode tests for the Keychain-backed provisioning path so unsigned
  SwiftPM skips cannot hide this class of regression.
- Re-run the wallet-node inherited-FD lifecycle test proving the second launch
  retains the exact public mapping while `keyLoaded == false`.
