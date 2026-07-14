//! The local broadcaster: a per-wallet process that owns its OWN EOA and submits the
//! proved unshield tx on-chain. This is the wallet's self-run relayer — it never
//! delegates to a third-party/Waku broadcaster.
//!
//! Privacy note (see design §2.2): a per-wallet broadcaster is an anonymity-set-of-one —
//! its EOA submits only this user's unshields and is funded by this user, so it is
//! linkable to them. That is a deliberate self-sufficiency tradeoff, not a bug. The one
//! property retained: the broadcaster EOA is distinct from the user's Kernel/main account,
//! so the unshield is not submitted by the shielding account itself.

use alloy::primitives::Address;
use alloy::providers::Provider;
use alloy::signers::local::PrivateKeySigner;
use eip_1193_provider::tx_data::TxData;
use serde::Serialize;

use crate::provider::connect_provider;

#[derive(Debug, Clone, Serialize)]
pub struct RelayReceipt {
    #[serde(rename = "txHash")]
    pub tx_hash: String,
    #[serde(rename = "blockNumber")]
    pub block_number: Option<u64>,
    pub status: bool,
}

pub struct LocalBroadcaster {
    provider: alloy::providers::DynProvider,
    address: Address,
}

impl LocalBroadcaster {
    /// Create a broadcaster bound to `rpc_url`, signing with its own `eoa_key` (0x-hex).
    pub async fn new(rpc_url: &str, eoa_key: &str) -> Result<Self, String> {
        let signer: PrivateKeySigner = eoa_key
            .parse()
            .map_err(|e| format!("bad broadcaster key: {e}"))?;
        let address = signer.address();
        let provider = connect_provider(rpc_url, Some(signer)).await?;
        Ok(Self { provider, address })
    }

    /// The broadcaster EOA address (so the wallet can fund it / display it).
    pub fn address(&self) -> Address {
        self.address
    }

    /// Submit the proved unshield tx with the broadcaster's own EOA and wait for the
    /// receipt. The `from` of the resulting tx is this broadcaster's address.
    pub async fn relay(&self, tx: TxData) -> Result<RelayReceipt, String> {
        let pending = self
            .provider
            .send_transaction(tx.into())
            .await
            .map_err(|e| format!("send unshield: {e}"))?;
        let receipt = pending
            .get_receipt()
            .await
            .map_err(|e| format!("unshield receipt: {e}"))?;
        Ok(RelayReceipt {
            tx_hash: format!("{:#x}", receipt.transaction_hash),
            block_number: receipt.block_number,
            status: receipt.status(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // anvil test key #1 (well-known; testnet only).
    const KEY: &str = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d";
    const ADDR: &str = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";

    #[test]
    fn address_is_derived_from_key() {
        let signer: PrivateKeySigner = KEY.parse().unwrap();
        assert_eq!(
            format!("{:?}", signer.address()).to_lowercase(),
            ADDR.to_lowercase()
        );
    }
}
