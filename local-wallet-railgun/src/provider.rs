//! Build the alloy provider the sidecar/broadcaster use.
//!
//! For the fork/standalone path this connects directly to an HTTP RPC (the anvil fork).
//! The daemon-socket backend (Helios-verified reads) is the app-integration path, added
//! later; the rest of the code only needs a `DynProvider`, so either backend plugs in.
//!
//! A read-only provider (no wallet) is enough for RAILGUN reads/sync/proving. A wallet is
//! supplied only for the process that actually submits txs (owner for shield, broadcaster
//! for unshield).

use alloy::network::Ethereum;
// `Provider` brings the `.erased()` method into scope.
use alloy::providers::{DynProvider, Provider, ProviderBuilder};
use alloy::signers::local::PrivateKeySigner;

/// Connect an erased alloy provider to `url`. If `signer` is given, txs sent through the
/// returned provider are signed by it.
pub async fn connect_provider(
    url: &str,
    signer: Option<PrivateKeySigner>,
) -> Result<DynProvider, String> {
    let provider = match signer {
        Some(s) => ProviderBuilder::new()
            .network::<Ethereum>()
            .wallet(s)
            .connect(url)
            .await
            .map_err(|e| format!("connect {url}: {e}"))?
            .erased(),
        None => ProviderBuilder::new()
            .network::<Ethereum>()
            .connect(url)
            .await
            .map_err(|e| format!("connect {url}: {e}"))?
            .erased(),
    };
    Ok(provider)
}
