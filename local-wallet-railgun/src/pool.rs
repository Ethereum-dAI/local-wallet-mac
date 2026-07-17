//! RAILGUN wiring: build the provider, register the account, and expose the three
//! sidecar operations — `balance_split`, `prepare_shield_native`, `prepare_unshield`.
//!
//! POI is intentionally left OFF (no `.with_poi()`): on an anvil fork a freshly-shielded
//! note can never be POI-`Valid` (the aggregator validates against real chain state), and
//! without POI a note is spendable immediately after `sync()`. See the design doc §6.

use std::sync::Arc;

use alloy::primitives::Address;
use alloy::providers::DynProvider;
use eip_1193_provider::tx_data::TxData;
use railgun::account::signer::{PrivateKeySigner, RailgunSigner};
use railgun::builder::RailgunBuilder;
use railgun::caip::AssetId;
use railgun::chain_config::ChainConfig;
use railgun::indexer::syncer::{ChainedSyncer, RpcSyncer, SubsquidSyncer};
use railgun::poi::PoiStatus;
use railgun::provider::{BalanceEntry, RailgunProvider};
use railgun::transact::TransactionBuilder;
use serde::Serialize;

/// Shielded balance for the base asset (WETH), split by POI spendability. Hex-wei strings.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct BalanceSplit {
    /// Spendable now (POI off ⇒ all notes; POI on ⇒ only `Valid`).
    pub valid: String,
    /// Not-yet-spendable (POI on and status != Valid).
    pub pending: String,
    /// valid + pending.
    pub total: String,
}

fn hexwei(v: u128) -> String {
    format!("0x{v:x}")
}

/// Pure balance-split: sum WETH notes into valid/pending by POI status.
pub fn split_balance(entries: &[BalanceEntry], asset: AssetId) -> BalanceSplit {
    let mut valid: u128 = 0;
    let mut pending: u128 = 0;
    for e in entries.iter().filter(|e| e.asset == asset) {
        match e.poi_status {
            None | Some(PoiStatus::Valid) => valid += e.amount,
            Some(_) => pending += e.amount,
        }
    }
    BalanceSplit {
        valid: hexwei(valid),
        pending: hexwei(pending),
        total: hexwei(valid + pending),
    }
}

pub struct RailgunHelper {
    railgun: RailgunProvider,
    signer: Arc<PrivateKeySigner>,
    weth: AssetId,
}

impl RailgunHelper {
    /// Build a RAILGUN provider (Subsquid+RPC sync, POI OFF) for `chain`, over `provider`,
    /// and register the account `signer`.
    pub async fn new(
        chain: ChainConfig,
        provider: DynProvider,
        fork_block: u64,
        signer: Arc<PrivateKeySigner>,
    ) -> Result<Self, String> {
        // Subsquid indexes live Sepolia; on a fork we must cap it at the fork block so it
        // doesn't return commitments the fork contract doesn't have. `with_latest_block`
        // is gated behind railgun's `testing` feature (our `fork-sync`). For a live
        // deployment (no fork), build without the feature and sync to head.
        let subsquid = SubsquidSyncer::new(&chain.subsquid_endpoint);
        #[cfg(feature = "fork-sync")]
        let subsquid = subsquid.with_latest_block(fork_block);
        #[cfg(not(feature = "fork-sync"))]
        let _ = fork_block;
        let syncer = Arc::new(
            ChainedSyncer::new()
                .then(subsquid)
                .then(RpcSyncer::new(chain.clone(), provider.clone()).with_batch_size(1000)),
        );
        let mut railgun = RailgunBuilder::new(chain.clone(), provider)
            .with_utxo_syncer(syncer)
            .build()
            .await
            .map_err(|e| format!("railgun build: {e}"))?;
        railgun
            .register(signer.clone())
            .await
            .map_err(|e| format!("register: {e}"))?;
        Ok(Self {
            railgun,
            signer,
            weth: AssetId::Erc20(chain.wrapped_base_token),
        })
    }

    pub async fn sync(&mut self) -> Result<(), String> {
        self.railgun.sync().await.map_err(|e| format!("sync: {e}"))
    }

    /// Shielded WETH balance, split by POI status. Syncs first.
    pub async fn balance_split(&mut self) -> Result<BalanceSplit, String> {
        self.sync().await?;
        let entries = self.railgun.balance(self.signer.address()).await;
        Ok(split_balance(&entries, self.weth))
    }

    /// Build the shield (deposit) tx(s) for `amount` wei of native ETH (wraps to WETH via
    /// RelayAdapt). No proof. The OWNER account self-submits these.
    pub async fn prepare_shield_native(&mut self, amount: u128) -> Result<Vec<TxData>, String> {
        self.sync().await?;
        let mut rng = rand::rng();
        self.railgun
            .shield()
            .shield_native(self.signer.address(), amount)
            .build(&mut rng)
            .map_err(|e| format!("shield build: {e}"))
    }

    /// Build + prove the unshield (withdraw) tx sending `amount` WETH to `to`.
    /// **Generates a Groth16 proof** (downloads artifacts on first call). The returned tx
    /// is submitted by the LOCAL BROADCASTER's EOA.
    pub async fn prepare_unshield(&mut self, to: Address, amount: u128) -> Result<TxData, String> {
        self.sync().await?;
        let tb = TransactionBuilder::new()
            .unshield(self.signer.clone(), to, self.weth, amount)
            .map_err(|e| format!("unshield builder: {e}"))?;
        let mut rng = rand::rng();
        let proved = self
            .railgun
            .build(tb, &mut rng)
            .await
            .map_err(|e| format!("prove unshield: {e}"))?;
        Ok(proved.tx_data)
    }

    /// The RAILGUN account address (0zk…), for logging/UX. Not a secret.
    pub fn account_address(&self) -> String {
        format!("{:?}", self.signer.address())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn weth() -> AssetId {
        AssetId::Erc20(ChainConfig::sepolia().wrapped_base_token)
    }

    fn entry(asset: AssetId, poi: Option<PoiStatus>, amount: u128) -> BalanceEntry {
        BalanceEntry {
            asset,
            poi_status: poi,
            amount,
        }
    }

    #[test]
    fn poi_off_counts_all_as_valid() {
        let e = [entry(weth(), None, 1_000), entry(weth(), None, 250)];
        let s = split_balance(&e, weth());
        assert_eq!(s.valid, "0x4e2"); // 1250
        assert_eq!(s.pending, "0x0");
        assert_eq!(s.total, "0x4e2");
    }

    #[test]
    fn poi_on_splits_valid_and_pending() {
        let e = [
            entry(weth(), Some(PoiStatus::Valid), 1_000),
            entry(weth(), Some(PoiStatus::Missing), 500),
            entry(weth(), Some(PoiStatus::ShieldBlocked), 7),
        ];
        let s = split_balance(&e, weth());
        assert_eq!(s.valid, "0x3e8"); // 1000
        assert_eq!(s.pending, "0x1fb"); // 507
        assert_eq!(s.total, "0x5e3"); // 1507
    }

    #[test]
    fn ignores_other_assets() {
        let other = AssetId::Erc20(Address::ZERO);
        let e = [entry(weth(), None, 100), entry(other, None, 999)];
        let s = split_balance(&e, weth());
        assert_eq!(s.total, "0x64"); // 100 only
    }
}
