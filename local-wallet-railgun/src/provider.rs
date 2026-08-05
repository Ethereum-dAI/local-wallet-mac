//! Build the alloy provider the sidecar uses.
//!
//! For the fork/standalone path this connects directly to an HTTP RPC (the anvil fork).
//! The daemon-socket backend (Helios-verified reads) is the app-integration path, added
//! later; the rest of the code only needs a `DynProvider`, so either backend plugs in.
//!
//! The provider is read-only, with NO wallet, and that is the whole story now: RAILGUN
//! reads/sync/proving need none, the exit's UserOperation is signed by its ephemeral sender and
//! broadcast by a public bundler, and the owner's shield txs are built here but submitted by the
//! app (as a Kernel UserOp), not through this provider. Nothing this crate does self-submits a
//! transaction, so there is no signer parameter to supply.
//!
//! All providers carry a transport-level retry/backoff layer: a transient RPC error or a
//! 429 rate-limit on ANY call (RAILGUN UTXO sync, the exit's `unshieldFee`/gas reads) is
//! retried rather than aborting the whole shield/unshield. Public and free-tier RPCs
//! rate-limit readily, so without this a single blip kills a privacy op.

use alloy::network::Ethereum;
// `Provider` brings the `.erased()` method into scope.
use alloy::providers::{DynProvider, Provider, ProviderBuilder};
use alloy::rpc::client::ClientBuilder;
use alloy::transports::http::reqwest::Url;
use alloy::transports::layers::RetryBackoffLayer;

/// Max retries on a 429/rate-limit before giving up.
const MAX_RATE_LIMIT_RETRIES: u32 = 8;
/// Initial backoff (ms) between retries; grows exponentially.
const INITIAL_BACKOFF_MS: u64 = 500;
/// Compute-units-per-second budget the backoff uses to pace retries.
const COMPUTE_UNITS_PER_SECOND: u64 = 100;

/// Connect an erased, wallet-less alloy provider to `url`. The client retries transient/429 RPC
/// errors.
pub async fn connect_provider(url: &str) -> Result<DynProvider, String> {
    let rpc_url: Url = url.parse().map_err(|e| format!("bad rpc url {url}: {e}"))?;
    let client = ClientBuilder::default()
        .layer(RetryBackoffLayer::new(
            MAX_RATE_LIMIT_RETRIES,
            INITIAL_BACKOFF_MS,
            COMPUTE_UNITS_PER_SECOND,
        ))
        .http(rpc_url);

    Ok(ProviderBuilder::new()
        .network::<Ethereum>()
        .connect_client(client)
        .erased())
}
