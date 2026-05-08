# wallet-node-store

`wallet-node-store` is the SQLite persistence layer for `wallet-node`.

It owns schema migrations, typed repository helpers, and an async store actor used by the daemon to keep blocking SQLite work off the request path.

## Stored Data

The store persists:

- bundler EOA accounts and lifecycle state
- UserOperations
- submitted raw transactions
- nonce reservations
- UserOperation receipts
- operation diagnostics (first-submit failures and watcher retry context)
- relayer-key audit events
- store audit history (audit runs, findings, repair attempts)
- daemon metadata

This allows the daemon to recover pending operations and submitted transactions after restart.

## Main Modules

| Module | Purpose |
|---|---|
| `schema` | SQL schema definitions. |
| `migrations` | SQLite migrations. |
| `db` | database opening and connection setup. |
| `repos` | typed repository operations across bundler accounts, nonce reservations, user operations, submitted transactions, user operation receipts, operation diagnostics, relayer-key audit events, audit history, and daemon metadata. |
| `actor` / `handle` / `command` | async actor wrapper around SQLite operations. |
| `read` | read-only helpers for status/pending operation views. |
| `audit` | store audit findings, severities, run summaries, and report types consumed by `wallet_auditStore` / `wallet_auditReport`. |
| `error` | typed `StoreError` for consumers. |
| `types` | persisted domain types. |

## Audit and Repair Surface

The store backs the daemon's `wallet_auditStore` / `wallet_auditHistory` / `wallet_auditReport` / `wallet_repairStore` JSON-RPC methods. Findings carry stable string codes (e.g., `terminal_user_op_has_pending_tx`, `pending_tx_nonce_advanced_without_receipt`, `chain_receipt_status_conflicts_with_local_tx`). Repair is a closed set of five actions, each gated to specific finding codes:

- `markSubmittedTxFailed`
- `abandonNonceReservation`
- `clearTentativeReceipt`
- `markTxDropped`
- `rebuildUserOpFromReceipt`

The store assumes operators do not edit SQLite directly; reconciliation with on-chain state is meant to flow through this audit → repair surface.

## Concurrency Note

The store actor currently runs synchronous `rusqlite` calls inside a normal Tokio task. The implementation assumes each SQLite operation is brief enough that this does not materially block async runtime workers; a `TODO(perf)` in the actor flags `spawn_blocking` as the alternative if profiling shows runtime stalls.

## Tests

Default tests:

```bash
cd rust-core
cargo test -p wallet-node-store
```

Ignored file-backed tests:

```bash
cargo test -p wallet-node-store -- --include-ignored
```

The daemon also exercises store behavior through `wallet-node` handler and watcher tests.

## Relationship To wallet-node

`wallet-node-store` does not know about transports, authentication, Helios, or Keychain. It is a persistence crate. The daemon decides policy and lifecycle state, then records those decisions through this crate.
