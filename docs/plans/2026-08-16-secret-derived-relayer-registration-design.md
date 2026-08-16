# Secret-Derived Relayer Registration Design

## Problem

Fresh onboarding and the in-app wallet reset both create a valid relayer key in Keychain and cache its public address, but neither registers that identity in wallet-node's durable `bundler_accounts` table. The next read-only daemon therefore reports `bundler_eoa_missing`, so the dashboard cannot bind daemon status to the Keychain-derived identity and renders the bundler as unavailable.

This is not a display-only problem. Falling back to the cached address would let the UI fund an identity that wallet-node has not accepted, recreating the split-brain condition that the relayer hardening was designed to prevent.

## Security Requirements

- wallet-node must derive the registered address from the 32-byte relayer secret. It must not accept a bare public address as proof of identity.
- The secret must travel only through the existing authenticated inherited file descriptor after the helper executable has passed `TrustedHelperLaunchGate` verification.
- A fresh setup must not add another biometric prompt. The newly generated secret is already in app memory.
- Existing or interrupted setup may authenticate once when the user explicitly resumes key setup. Passive launch, focus, and status refresh paths must remain prompt-free.
- After registration, the helper that received the secret must be terminated and reaped. A second read-only launch must prove that the durable public mapping survived while the private key is absent from daemon memory.
- Onboarding may complete, and dashboard reset may bootstrap, only after both the secret-backed registration and the read-only verification succeed.
- Registration must be idempotent. Retrying the same key reference and derived address is safe; wallet-node's existing reconciliation policy remains authoritative for conflicts and live local work.

## Chosen Flow

Add a shared `RelayerBootstrapRegistrationService` beside `WalletNodeDaemon`.

For a supplied `BundlerSecretRecord`, the service:

1. Derives a `VerifiedRelayerIdentity` locally and rejects a chain mismatch before launching anything.
2. Launches wallet-node through the existing trusted helper gate with exactly that secret in the fd 5 payload.
3. Reads `wallet_bundlerStatus` and verifies the exact chain, key reference, address, active lifecycle, coherent funding state, no compromise flag, and `keyLoaded == true`.
4. Terminates and reaps that daemon.
5. Launches wallet-node again with `{"keys":[]}`.
6. Reads status and verifies the same identity, `keyLoaded == false`, and the normal locked state.
7. Terminates and reaps the read-only daemon before returning success.

The service disables Helios only for these two short registration probes. Registration needs the local store and the public execution RPC balance surface, not a consensus sync. The normal onboarding readiness and dashboard launch immediately rewrite the daemon configuration with the user's actual verification setting.

## Integration Points

### Fresh onboarding

`OnboardingProvisioningService` returns the relayer secret record together with the two public addresses. A newly generated key needs no read or prompt. If setup resumes with an existing Keychain item, the explicit **Create Keys** action performs one authenticated read.

`OnboardingState.provisionKeys()` runs the shared registration service before publishing `keyState = .ready`. Funding and completion are therefore impossible until wallet-node has accepted the exact identity and a read-only restart has verified it.

### Dashboard reset

The reset flow already owns one device-owner authentication session and creates the replacement relayer inside it. It passes that in-memory record to the same registration service before clearing in-memory UI state or starting dashboard bootstrap. The fresh address is cached only after exact registration succeeds.

If registration fails after destructive cleanup, reset remains failed instead of presenting a wallet with an unusable bundler. Retrying reset creates and registers a coherent fresh identity through the same path.

### Normal launches and money actions

No change is made to normal `ensureWalletNodeClient()` behavior: it launches read-only with no secrets and never reads Keychain. The registered row supplies public address and balance status, while `keyLoaded == false` keeps the relayer locked. The first actual signed action continues to authenticate and call `wallet_installBundlerEOA` on demand.

## Rejected Alternatives

### Register a bare public identity at startup

This is convenient but weaker. It adds a daemon mutation path that can direct funding without proving possession of the corresponding private key. A cryptographic public registration protocol could solve that, but it would require a new signature format, recovery verification, replay protection, FFI, and RPC surface for no current product benefit.

### Render the Keychain or UserDefaults address when daemon status is missing

This is a UI patch, not a lifecycle fix. It creates two authorities, can send funds to an identity the daemon will not use, and leaves top-up preflight deadlocked.

### Keep the secret-loaded daemon alive

This would make onboarding appear to work but violate on-demand authentication. The registration daemon is deliberately short-lived; the verified restart proves the normal locked state before setup succeeds.

## Verification

- Pure tests for exact registration-state validation, including wrong chain, key reference, address, lifecycle, compromise flag, unexpected loaded state, and unlocked read-only restart.
- Service orchestration tests proving the first probe receives one secret, the second receives none, failures stop the sequence, and retry uses the same identity.
- Source/integration tests proving onboarding cannot publish ready before registration and reset cannot bootstrap before registration.
- Existing authentication audits proving passive startup and focus changes still contain no relayer Keychain read.
- Existing wallet-node fd lifecycle tests proving secret-fd registration persists an active account, plus focused Rust tests for reconciliation conflict and idempotency behavior.
- Full Swift and Rust test suites, followed by an Xcode Debug build using an isolated DerivedData directory so the developer's runnable signed product is not overwritten by an unsigned verification build.
