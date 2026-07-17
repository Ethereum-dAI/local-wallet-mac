//! `railgun-helper` — a Rust sidecar that shields ETH into RAILGUN on Sepolia and
//! unshields it, with the unshield relayed by a per-wallet **local broadcaster**.
//!
//! See `docs/design/2026-07-13-railgun-shield-unshield-v2-design.md`.
//!
//! Two runnable processes share this library:
//! - `railgun-helper`      — sidecar: `balance` / `prepareShield` / `prepareUnshield`.
//! - `railgun-broadcaster` — local broadcaster: `relay` / `address` (its own EOA).

pub mod broadcaster;
pub mod keys;
// NOTE: module is `pool`, not `railgun` — a module named `railgun` would shadow the
// extern `railgun` crate in path resolution and break every `railgun::…` import.
pub mod pool;
pub mod provider;
pub mod rpc;
pub mod secret;
pub mod spawn;

// Build-gate smoke: confirm the pinned Kohaku API surface resolves.
#[doc(hidden)]
pub fn _kohaku_api_smoke() -> u64 {
    use railgun::chain_config::ChainConfig;
    ChainConfig::sepolia().id
}
