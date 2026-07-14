//! `railgun-helper` — a Rust sidecar that shields ETH into RAILGUN on Sepolia and
//! unshields it, with the unshield relayed by a per-wallet **local broadcaster**.
//!
//! See `docs/design/2026-07-13-railgun-shield-unshield-v2-design.md`.
//!
//! Two runnable processes share this library:
//! - `railgun-helper`      — sidecar: `balance` / `prepareShield` / `prepareUnshield`.
//! - `railgun-broadcaster` — local broadcaster: `relay` / `address` (its own EOA).

// Build-gate smoke: confirm the pinned Kohaku API surface resolves.
#[doc(hidden)]
pub fn _kohaku_api_smoke() -> u64 {
    use railgun::chain_config::ChainConfig;
    ChainConfig::sepolia().id
}
