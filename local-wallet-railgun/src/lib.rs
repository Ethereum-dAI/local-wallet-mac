//! `railgun-helper` — a Rust sidecar that shields ETH into RAILGUN on Sepolia and unshields
//! it via RAILGUN's privacy paymaster, submitted by a public ERC-4337 bundler. There is no
//! local broadcaster: nothing of ours pays gas, so nothing needs funding.
//!
//! See `docs/design/2026-07-13-railgun-shield-unshield-v2-design.md`.
//!
//! One runnable process uses this library: `railgun-helper`, serving
//! `balance` / `maxUnshieldable` / `prepareShield` / `unshield` / `unshieldStatus`.

pub mod derivation;
pub mod exit;
pub mod exit_index;
pub mod fee;
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
