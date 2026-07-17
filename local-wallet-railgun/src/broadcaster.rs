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

/// Whether `to` may be relayed to. Empty allowlist ⇒ permit any (tests/standalone only).
fn target_allowed(allowed: &[Address], to: &Address) -> bool {
    allowed.is_empty() || allowed.contains(to)
}

pub struct LocalBroadcaster {
    provider: alloy::providers::DynProvider,
    address: Address,
    /// Contracts `relay()` is allowed to submit to (the RAILGUN targets for this chain).
    /// Guards the funded EOA: without this, anything holding the bearer token could make
    /// the broadcaster sign an arbitrary tx (e.g. sweep its ETH). Empty ⇒ allow any (only
    /// for tests/standalone).
    allowed_targets: Vec<Address>,
}

impl LocalBroadcaster {
    /// Create a broadcaster bound to `rpc_url`, signing with its own `eoa_key` (0x-hex),
    /// restricted to submitting to `allowed_targets` (RAILGUN contracts). Pass an empty
    /// vec to allow any target (tests only).
    pub async fn new(
        rpc_url: &str,
        eoa_key: &str,
        allowed_targets: Vec<Address>,
    ) -> Result<Self, String> {
        let signer: PrivateKeySigner = eoa_key
            .parse()
            .map_err(|e| format!("bad broadcaster key: {e}"))?;
        let address = signer.address();
        let provider = connect_provider(rpc_url, Some(signer)).await?;
        Ok(Self {
            provider,
            address,
            allowed_targets,
        })
    }

    /// The broadcaster EOA address (so the wallet can fund it / display it).
    pub fn address(&self) -> Address {
        self.address
    }

    /// Submit the proved unshield tx with the broadcaster's own EOA and wait for the
    /// receipt. The `from` of the resulting tx is this broadcaster's address.
    ///
    /// Rejects any tx whose `to` is not a configured RAILGUN target — the broadcaster's
    /// EOA holds gas funds, so it must never be a general-purpose signer for whoever holds
    /// the token.
    pub async fn relay(&self, tx: TxData) -> Result<RelayReceipt, String> {
        if !target_allowed(&self.allowed_targets, &tx.to) {
            return Err(format!(
                "refusing to relay: target {:?} is not a known RAILGUN contract",
                tx.to
            ));
        }
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
    use alloy::primitives::address;

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

    #[test]
    fn target_allowlist_guards_the_eoa() {
        let railgun = address!("0xeCFCf3b4eC647c4Ca6D49108b311b7a7C9543fea");
        let relay_adapt = address!("0x7e3d929EbD5bDC84d02Bd3205c777578f33A214D");
        let evil = Address::ZERO;
        let allowed = vec![railgun, relay_adapt];
        assert!(target_allowed(&allowed, &railgun));
        assert!(target_allowed(&allowed, &relay_adapt));
        assert!(
            !target_allowed(&allowed, &evil),
            "must reject non-RAILGUN target"
        );
        // Empty allowlist permits any (tests/standalone).
        assert!(target_allowed(&[], &evil));
    }
}
