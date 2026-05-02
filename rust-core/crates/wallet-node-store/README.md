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
- daemon metadata

This allows the daemon to recover pending operations and submitted transactions after restart.

## Main Modules

| Module | Purpose |
|---|---|
| `schema` | SQL schema definitions. |
| `migrations` | SQLite migrations. |
| `db` | database opening and connection setup. |
| `repos` | typed repository operations. |
| `actor` / `handle` / `command` | async actor wrapper around SQLite operations. |
| `read` | read-only helpers for status/pending operation views. |
| `types` | persisted domain types. |

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
