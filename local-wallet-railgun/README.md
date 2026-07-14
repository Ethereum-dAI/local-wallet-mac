# Local Wallet Railgun

> **Status:** pre-implementation (design only). Experimental, unaudited, testnet-only.
> Not production custody software.

`local-wallet-railgun` is a small Rust **sidecar** (`railgun-helper`) that adds
[Railgun](https://railgun.org) shielded-pool support to the
[Local Wallet](https://github.com/Ethereum-dAI/local-wallet-mac) macOS app. It is a
sibling to [`local-wallet-daemon`](../local-wallet-daemon) and follows the same
spawn/transport contract: the macOS app spawns it as a child process and talks to it
over a Unix-socket JSON-RPC API authenticated by a per-launch bearer token.

It wraps the Ethereum Foundation Kohaku project's [`railgun` Rust
crate](https://github.com/ethereum/kohaku/tree/master/crates/railgun) (used with
`default-features = false`, i.e. **no WASM**) and forwards all chain reads to the
`wallet-node` daemon, reusing the daemon as its Ethereum provider.

```
   macOS app ──spawn──► railgun-helper (this repo)
       │                    │  JSON-RPC over Unix socket (Bearer token, fd-3 ready)
       │                    ▼
       │              crates/railgun (Kohaku, no-WASM)
       │                    │  chain reads forwarded as JSON-RPC
       └──spawn──► wallet-node (local-wallet-daemon) ──► Ethereum (Sepolia)
```

## Scope (v1)

Shield (deposit) + balance only, on **Sepolia**. Mirrors the Privacy Pools reference
(`privacy-helper` in `local-wallet-mac`). See
[`docs/design/2026-07-02-railgun-helper-v1.md`](docs/design/2026-07-02-railgun-helper-v1.md)
for the full design, roadmap (unshield/transfer), and security notes.

## License

Dual-licensed under MIT OR Apache-2.0.
