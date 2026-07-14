//! The local broadcaster: a per-wallet process that owns its OWN EOA and submits the
//! proved unshield tx on-chain. This is the wallet's self-run relayer — it never
//! delegates to a third-party/Waku broadcaster.
//!
//! Privacy note (see design §2.2): a per-wallet broadcaster is an anonymity-set-of-one —
//! its EOA submits only this user's unshields and is funded by this user, so it is
//! linkable to them. That is a deliberate self-sufficiency tradeoff, not a bug. The one
//! property retained: the broadcaster EOA is distinct from the user's Kernel/main account,
//! so the unshield is not submitted by the shielding account itself.
//!
//! Native-ETH delivery: the Kohaku crate's unshield only delivers the wrapped base token
//! (WETH). To land NATIVE ETH at a recipient we unshield WETH to the broadcaster's own
//! address, then the broadcaster `WETH.withdraw()`s (unwrap) and forwards native ETH to
//! the recipient. The broadcaster transiently custodies the amount — acceptable because it
//! is the user's own local infra (and testnet only).

use std::time::Duration;

use alloy::primitives::{Address, U256};
use alloy::providers::{DynProvider, Provider};
use alloy::rpc::types::TransactionRequest;
use alloy::signers::local::PrivateKeySigner;
use alloy::sol;
use eip_1193_provider::tx_data::TxData;
use serde::Serialize;

use crate::provider::connect_provider;

sol! {
    #[sol(rpc)]
    contract WETH {
        function balanceOf(address) external view returns (uint256);
        function withdraw(uint256 wad) external;
    }
}

/// Default bound on waiting for a submitted tx's receipt, so a stuck live tx can't hang
/// the (sequential) broadcaster socket forever.
pub const DEFAULT_RECEIPT_TIMEOUT: Duration = Duration::from_secs(120);

#[derive(Debug, Clone, Serialize)]
pub struct RelayReceipt {
    #[serde(rename = "txHash")]
    pub tx_hash: String,
    #[serde(rename = "blockNumber")]
    pub block_number: Option<u64>,
    pub status: bool,
}

/// Result of an unshield-to-native relay: the three on-chain steps + the delivered amount.
#[derive(Debug, Clone, Serialize)]
pub struct NativeRelayReceipt {
    #[serde(rename = "unshieldTxHash")]
    pub unshield_tx_hash: String,
    #[serde(rename = "unwrapTxHash")]
    pub unwrap_tx_hash: String,
    #[serde(rename = "forwardTxHash")]
    pub forward_tx_hash: String,
    /// Native wei delivered to the recipient (unshielded amount minus the pool's fee).
    #[serde(rename = "amountWei")]
    pub amount_wei: String,
    pub recipient: String,
    #[serde(rename = "blockNumber")]
    pub block_number: Option<u64>,
    pub status: bool,
}

/// Whether `to` may be relayed to. Empty allowlist ⇒ permit any (tests/standalone only).
fn target_allowed(allowed: &[Address], to: &Address) -> bool {
    allowed.is_empty() || allowed.contains(to)
}

/// A relayed unshield tx must carry a function selector (>=4 bytes) and target a known
/// RAILGUN contract — a cheap guard so the funded EOA can't be coerced into a bare ETH
/// transfer or a call to an arbitrary contract by whoever holds the token.
fn looks_like_railgun_call(allowed: &[Address], tx: &TxData) -> Result<(), String> {
    if !target_allowed(allowed, &tx.to) {
        return Err(format!(
            "refusing to relay: target {:?} is not a known RAILGUN contract",
            tx.to
        ));
    }
    if tx.data.len() < 4 {
        return Err("refusing to relay: tx has no function selector (not a contract call)".into());
    }
    // Unshield txs carry no ETH value; refuse a value-bearing tx so the funded EOA can't be
    // coerced into moving its own ETH to a RAILGUN contract.
    if tx.value != U256::ZERO {
        return Err("refusing to relay: unshield tx must have zero value".into());
    }
    Ok(())
}

pub struct LocalBroadcaster {
    provider: DynProvider,
    address: Address,
    allowed_targets: Vec<Address>,
    weth: Address,
    receipt_timeout: Duration,
}

impl LocalBroadcaster {
    /// Create a broadcaster bound to `rpc_url`, signing with its own `eoa_key` (0x-hex),
    /// restricted to submitting to `allowed_targets` (RAILGUN contracts; empty ⇒ any, tests
    /// only). `weth` is the wrapped-base-token used for the unwrap step.
    pub async fn new(
        rpc_url: &str,
        eoa_key: &str,
        allowed_targets: Vec<Address>,
        weth: Address,
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
            weth,
            receipt_timeout: DEFAULT_RECEIPT_TIMEOUT,
        })
    }

    pub fn with_receipt_timeout(mut self, timeout: Duration) -> Self {
        self.receipt_timeout = timeout;
        self
    }

    /// The broadcaster EOA address (so the wallet can fund it / display it).
    pub fn address(&self) -> Address {
        self.address
    }

    /// Send a tx from the broadcaster EOA and wait (bounded) for its receipt.
    async fn send_and_await(&self, req: TransactionRequest) -> Result<RelayReceipt, String> {
        let pending = self
            .provider
            .send_transaction(req)
            .await
            .map_err(|e| format!("send tx: {e}"))?;
        let receipt = tokio::time::timeout(self.receipt_timeout, pending.get_receipt())
            .await
            .map_err(|_| "timed out waiting for receipt".to_string())?
            .map_err(|e| format!("receipt: {e}"))?;
        Ok(RelayReceipt {
            tx_hash: format!("{:#x}", receipt.transaction_hash),
            block_number: receipt.block_number,
            status: receipt.status(),
        })
    }

    /// Submit the proved unshield tx with the broadcaster's own EOA (delivers WETH to the
    /// note recipient encoded in the proof). The `from` of the resulting tx is this
    /// broadcaster's address. Used for WETH delivery / diagnostics.
    pub async fn relay(&self, tx: TxData) -> Result<RelayReceipt, String> {
        looks_like_railgun_call(&self.allowed_targets, &tx)?;
        self.send_and_await(tx.into()).await
    }

    /// Relay an unshield whose note recipient is THIS broadcaster, then unwrap the received
    /// WETH and forward native ETH to `recipient`. Yields native ETH at `recipient`.
    pub async fn relay_unshield_native(
        &self,
        tx: TxData,
        recipient: Address,
    ) -> Result<NativeRelayReceipt, String> {
        looks_like_railgun_call(&self.allowed_targets, &tx)?;
        let weth = WETH::new(self.weth, &self.provider);

        let before = weth
            .balanceOf(self.address)
            .call()
            .await
            .map_err(|e| format!("weth balanceOf(before): {e}"))?;

        // 1) submit the unshield (WETH -> this broadcaster)
        let unshield = self.send_and_await(tx.into()).await?;
        if !unshield.status {
            return Err("unshield tx reverted".into());
        }

        let after = weth
            .balanceOf(self.address)
            .call()
            .await
            .map_err(|e| format!("weth balanceOf(after): {e}"))?;
        let received = after.saturating_sub(before);
        if received.is_zero() {
            return Err("unshield delivered no WETH to the broadcaster".into());
        }

        // 2) unwrap WETH -> native ETH in the broadcaster's account
        let unwrap = self
            .send_and_await(weth.withdraw(received).into_transaction_request())
            .await?;
        if !unwrap.status {
            return Err("WETH.withdraw (unwrap) reverted".into());
        }

        // 3) forward native ETH to the final recipient
        let forward = self
            .send_and_await(TransactionRequest::default().to(recipient).value(received))
            .await?;
        if !forward.status {
            return Err("forward of native ETH reverted".into());
        }

        Ok(NativeRelayReceipt {
            unshield_tx_hash: unshield.tx_hash,
            unwrap_tx_hash: unwrap.tx_hash,
            forward_tx_hash: forward.tx_hash,
            amount_wei: format!("0x{received:x}"),
            recipient: format!("{recipient:?}"),
            block_number: forward.block_number,
            status: true,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::{address, bytes, U256};

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

    fn tx_to(to: Address, data: &[u8]) -> TxData {
        TxData {
            to,
            data: data.to_vec().into(),
            value: U256::ZERO,
        }
    }

    #[test]
    fn guard_accepts_known_target_with_selector() {
        let railgun = address!("0xeCFCf3b4eC647c4Ca6D49108b311b7a7C9543fea");
        let allowed = vec![railgun];
        assert!(looks_like_railgun_call(&allowed, &tx_to(railgun, &bytes!("aabbccdd"))).is_ok());
    }

    #[test]
    fn guard_rejects_unknown_target() {
        let railgun = address!("0xeCFCf3b4eC647c4Ca6D49108b311b7a7C9543fea");
        let allowed = vec![railgun];
        let err = looks_like_railgun_call(&allowed, &tx_to(Address::ZERO, &bytes!("aabbccdd")));
        assert!(err.unwrap_err().contains("not a known RAILGUN contract"));
    }

    #[test]
    fn guard_rejects_bare_transfer_no_selector() {
        let railgun = address!("0xeCFCf3b4eC647c4Ca6D49108b311b7a7C9543fea");
        let allowed = vec![railgun];
        let err = looks_like_railgun_call(&allowed, &tx_to(railgun, &[]));
        assert!(err.unwrap_err().contains("no function selector"));
    }

    #[test]
    fn empty_allowlist_permits_any_target_but_still_needs_selector() {
        assert!(looks_like_railgun_call(&[], &tx_to(Address::ZERO, &bytes!("aabbccdd"))).is_ok());
        assert!(looks_like_railgun_call(&[], &tx_to(Address::ZERO, &[])).is_err());
    }

    #[test]
    fn guard_rejects_value_bearing_tx() {
        let railgun = address!("0xeCFCf3b4eC647c4Ca6D49108b311b7a7C9543fea");
        let mut tx = tx_to(railgun, &bytes!("aabbccdd"));
        tx.value = U256::from(1);
        assert!(looks_like_railgun_call(&[railgun], &tx)
            .unwrap_err()
            .contains("zero value"));
    }
}
