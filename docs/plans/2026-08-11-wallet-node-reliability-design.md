# Wallet-node Reliability Design

## Scope

This patch fixes three failures found while exercising a freshly rebuilt development app:

1. `wallet_installBundlerEOA` rejects a replacement Keychain secret when the daemon still has an idle address recorded for the same key reference.
2. An early daemon exit is flattened into `wallet-node ready pipe closed before ready event`, hiding the real startup failure recorded in the daemon log.
3. The committed Sepolia execution RPC default, `https://sepolia.drpc.org`, currently rejects `eth_chainId` with HTTP 400.

The larger clone-to-Xcode-Run bootstrap and native-artifact embedding work remains a separate follow-up. Keeping it separate avoids mixing build-system changes with relayer-state safety changes.

## Relayer key reconciliation

The key reference is the app's Keychain slot identifier. The daemon may rebind an existing slot to newly supplied key material only when the old address has no live local work. Secret-FD startup already implements that recovery policy, but runtime `wallet_installBundlerEOA` duplicates a stricter subset and rejects every address mismatch.

Extract one shared reconciliation path and use it from both startup secret loading and the runtime install handler:

- If the supplied address and key reference already match an account, preserve its lifecycle and load the key.
- If the same key reference resolves to a different address and the recorded account has no pending nonce reservation or live submitted transaction, atomically replace the stale active metadata with the supplied address.
- If the recorded account has live work, fail closed and leave both durable metadata and the in-memory key store unchanged.
- If the supplied address is already registered under a different key reference, continue rejecting it as a data-integrity violation.

The recovery must emit a warning and relayer audit event containing the old and new public addresses, key reference, chain ID, and the no-live-work reason. Private key material must never enter logs or durable daemon storage.

The current local state qualifies for safe recovery: its only nonce reservation, submitted transaction, and UserOperation are all `included`.

## Startup error propagation

The app owns the daemon log file and waits for a newline-delimited ready event on fd 3. When the child closes fd 3 before sending that event, the app currently reports only the pipe symptom.

Keep the fd contract unchanged, but enrich the failure at the process boundary:

- Capture the child termination status when the ready pipe closes or times out.
- Read a bounded tail of the managed wallet-node log.
- Extract the latest structured log message when possible, falling back to a short raw tail.
- Throw a launch error that includes the process exit status and concrete daemon message, for example: `wallet-node exited before ready: execution RPC chain id validation failed — eth_chainId HTTP status 400 Bad Request`.
- Keep the log tail bounded and exclude configuration secrets, authorization tokens, and private key payloads.

This error must flow through onboarding readiness, funding, and later managed-daemon restarts without being replaced by the generic ready-pipe wording.

## Sepolia RPC default

Replace `https://sepolia.drpc.org` with `https://ethereum-sepolia-rpc.publicnode.com` everywhere the Sepolia execution RPC default is defined, documented, or asserted. The replacement was verified on 2026-08-11 to return HTTP 200 and chain ID `0xaa36a7` (11155111) for `eth_chainId`.

Onboarding and Settings must continue validating the configured endpoint rather than trusting the default. A wrong chain ID or failed JSON-RPC request must prevent the setting from being accepted and surface the concrete validation failure.

## Verification

Add or update tests for:

- Runtime install safely rebinding an idle mismatched key reference.
- Runtime install rejecting the same mismatch when a nonce or submitted transaction is live.
- Startup and runtime install sharing the same reconciliation behavior.
- Ready-pipe EOF and timeout errors containing the daemon's latest structured startup failure and exit status without unbounded log output.
- Sepolia defaults and generated daemon configuration using the new endpoint.
- Onboarding/settings RPC validation still rejecting HTTP failure and wrong-chain responses.

Run the focused Rust and Swift test suites, then build the Xcode app and exercise a managed daemon launch against the new default endpoint.
