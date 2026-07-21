//! Build the alloy provider the sidecar/broadcaster use.
//!
//! For the fork/standalone path this connects directly to an HTTP RPC (the anvil fork).
//! The daemon-socket backend (Helios-verified reads) is the app-integration path, added
//! later; the rest of the code only needs a `DynProvider`, so either backend plugs in.
//!
//! A read-only provider (no wallet) is enough for RAILGUN reads/sync/proving. A wallet is
//! supplied only for the process that actually submits txs (owner for shield, broadcaster
//! for unshield).
//!
//! All providers carry a transport-level retry/backoff layer: a transient RPC error or a
//! 429 rate-limit on ANY call (RAILGUN UTXO sync, the broadcaster's `balanceOf`/receipt
//! polling, tx submission) is retried rather than aborting the whole shield/unshield. Public
//! and free-tier RPCs rate-limit readily, so without this a single blip kills a privacy op.

use alloy::network::Ethereum;
// `Provider` brings the `.erased()` method into scope.
use alloy::providers::{DynProvider, Provider, ProviderBuilder};
use alloy::rpc::client::ClientBuilder;
use alloy::signers::local::PrivateKeySigner;
use alloy::transports::http::reqwest::Url;
use alloy::transports::layers::RetryBackoffLayer;

/// Max retries on a 429/rate-limit before giving up.
const MAX_RATE_LIMIT_RETRIES: u32 = 8;
/// Initial backoff (ms) between retries; grows exponentially.
const INITIAL_BACKOFF_MS: u64 = 500;
/// Compute-units-per-second budget the backoff uses to pace retries.
const COMPUTE_UNITS_PER_SECOND: u64 = 100;

/// Connect an erased alloy provider to `url`. If `signer` is given, txs sent through the
/// returned provider are signed by it. The client retries transient/429 RPC errors.
pub async fn connect_provider(
    url: &str,
    signer: Option<PrivateKeySigner>,
) -> Result<DynProvider, String> {
    let rpc_url: Url = url.parse().map_err(|e| format!("bad rpc url {url}: {e}"))?;
    let client = ClientBuilder::default()
        .layer(RetryBackoffLayer::new(
            MAX_RATE_LIMIT_RETRIES,
            INITIAL_BACKOFF_MS,
            COMPUTE_UNITS_PER_SECOND,
        ))
        .http(rpc_url);

    let provider = match signer {
        Some(s) => ProviderBuilder::new()
            .network::<Ethereum>()
            .wallet(s)
            .connect_client(client)
            .erased(),
        None => ProviderBuilder::new()
            .network::<Ethereum>()
            .connect_client(client)
            .erased(),
    };
    Ok(provider)
}
