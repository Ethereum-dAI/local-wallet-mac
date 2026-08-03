//! RAILGUN wiring: build the provider, register the account, and expose the sidecar
//! operations — `balance_split`, `prepare_shield_native`, and `submit_exit`.
//!
//! POI is intentionally left OFF (no `.with_poi()`): on an anvil fork a freshly-shielded
//! note can never be POI-`Valid` (the aggregator validates against real chain state), and
//! without POI a note is spendable immediately after `sync()`. See the design doc §6.

use std::path::Path;
use std::sync::Arc;

use alloy::primitives::{Address, U256};
use alloy::providers::DynProvider;
use eip_1193_provider::tx_data::TxData;
use railgun::account::signer::{PrivateKeySigner, RailgunSigner};
use railgun::builder::RailgunBuilder;
use railgun::caip::AssetId;
use railgun::chain_config::ChainConfig;
use railgun::indexer::syncer::{ChainedSyncer, RpcSyncer, SubsquidSyncer};
use railgun::poi::PoiStatus;
use railgun::provider::{BalanceEntry, RailgunProvider, RailgunProviderError};
use railgun::transact::TransactionBuilder;
use serde::Serialize;
use userop_kit::bundler::{pimlico::PimlicoBundler, Bundler};
use userop_kit::smart_account::simple_smart_account::{self, SimpleSmartAccount};

use crate::exit::{self, ExitError, ExitSubmission};
use crate::{exit_index, keys};

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
            None | Some(PoiStatus::Valid) => valid = valid.saturating_add(e.amount),
            Some(_) => pending = pending.saturating_add(e.amount),
        }
    }
    BalanceSplit {
        valid: hexwei(valid),
        pending: hexwei(pending),
        total: hexwei(valid.saturating_add(pending)),
    }
}

pub struct RailgunHelper {
    railgun: RailgunProvider,
    signer: Arc<PrivateKeySigner>,
    weth: AssetId,
    /// Kept for the exit path: chain id, WETH address, and the unshield fee bps.
    chain: ChainConfig,
    /// Kept for the exit path: SimpleSmartAccount and the paymaster gas estimate need it.
    provider: DynProvider,
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
        // `RailgunBuilder::new` consumes the provider, so keep our own handle first; `chain` is
        // already passed by clone, so it survives the call and can move into `Self`.
        let provider_for_self = provider.clone();
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
            chain,
            provider: provider_for_self,
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

    /// Unshield `value` wei of WETH and deliver NATIVE ETH to `recipient`, sponsored by
    /// RAILGUN's privacy paymaster and submitted by a PUBLIC bundler.
    ///
    /// The unshield targets an ephemeral EIP-7702 account derived at
    /// `m/44'/60'/0'/0/{index}`; the UserOp's `callData` unwraps and forwards, so the whole
    /// exit is ONE atomic transaction from a single-use, never-funded address.
    ///
    /// **Generates one Groth16 proof per fee-loop iteration** (two is the floor: the SDK's
    /// seed `fee_value` is ~7 orders of magnitude below a real sponsored fee, so iteration 1
    /// can never converge). On a convergence failure we retry ONCE, and only if a fresh gas
    /// sample shows gas is not still climbing.
    ///
    /// **The exit index is NOT 1:1 with a user-visible exit.** A gas-gated retry derives a
    /// SECOND sender at a SECOND index — deliberately, because reusing a sender across attempts
    /// would link them — so the on-disk counter can advance by 2 for one exit, and the
    /// first attempt's address may have been logged without ever being used. Recovery tooling
    /// must scan indices rather than assume one index per exit.
    ///
    /// Returns as soon as the bundler accepts the op. Receipt polling is `exit::await_exit`,
    /// a free function the caller runs WITHOUT holding this helper's mutex.
    pub async fn submit_exit(
        &mut self,
        recipient: Address,
        value: u128,
        state_dir: &Path,
        entropy_hex: &str,
    ) -> Result<ExitSubmission, ExitError> {
        self.sync().await.map_err(ExitError::Other)?;

        let bundler_url = exit::resolve_bundler_url(self.chain.id);
        let baseline = exit::fetch_max_fee_per_gas(&bundler_url)
            .await
            .map_err(ExitError::Other)?;

        match self
            .try_submit(recipient, value, state_dir, entropy_hex, &bundler_url)
            .await
        {
            Err(ExitError::FeeDidNotConverge) => {
                let fresh = exit::fetch_max_fee_per_gas(&bundler_url)
                    .await
                    .map_err(ExitError::Other)?;
                if !exit::should_retry_after_convergence_failure(baseline, fresh) {
                    tracing::warn!("gas climbed {baseline} -> {fresh}; not retrying the exit");
                    return Err(ExitError::FeeDidNotConverge);
                }
                tracing::info!("gas flat/falling ({baseline} -> {fresh}); retrying the exit once");
                self.try_submit(recipient, value, state_dir, entropy_hex, &bundler_url)
                    .await
            }
            other => other,
        }
    }

    /// One attempt: derive a fresh sender, prove, sign, submit. Called at most twice by
    /// `submit_exit`; each attempt burns its own exit index so no sender is ever reused.
    async fn try_submit(
        &mut self,
        recipient: Address,
        value: u128,
        state_dir: &Path,
        entropy_hex: &str,
        bundler_url: &str,
    ) -> Result<ExitSubmission, ExitError> {
        let weth_addr = self.chain.wrapped_base_token;
        let fee_bps = self.chain.unshield_fee_bps;

        // Checked before burning an index or a proof: a request this small can never produce a
        // forwardable amount, and `withdraw(0)` followed by a 0-wei send is pointless.
        let forward = exit::forward_amount(value, fee_bps);
        if forward == 0 {
            return Err(ExitError::Other(format!(
                "amount {value} wei is too small to cover the {fee_bps} bps fee plus the \
                 delivery guard"
            )));
        }

        let index = exit_index::next_index(state_dir)
            .map_err(|e| ExitError::Other(format!("exit index: {e}")))?;
        let key = keys::derive_exit_key(entropy_hex, index)
            .map_err(|e| ExitError::Other(format!("derive exit key: {e}")))?;
        // `key` is secret: it is parsed into a signer and never logged, formatted, or returned.
        let eoa: alloy::signers::local::PrivateKeySigner = key
            .parse()
            .map_err(|_| ExitError::Other("exit key is not a valid secp256k1 key".to_string()))?;
        let sender = eoa.address();
        tracing::info!("exit {index} sender {sender:?}");

        let account = SimpleSmartAccount::new(sender, self.chain.id, self.provider.clone());
        let bundler = PimlicoBundler::new(
            bundler_url
                .parse()
                .map_err(|e| ExitError::Other(format!("bad bundler url: {e}")))?,
        );

        // Unshield to the ephemeral sender; callData unwraps and forwards from there.
        let tb = TransactionBuilder::new()
            .unshield(self.signer.clone(), sender, self.weth, value)
            .map_err(|e| ExitError::Other(format!("unshield builder: {e}")))?;

        let weth = exit::WETH::new(weth_addr, self.provider.clone());
        let calls = vec![
            simple_smart_account::Call {
                target: weth_addr,
                value: U256::ZERO,
                data: weth.withdraw(U256::from(forward)).calldata().clone(),
            },
            simple_smart_account::Call {
                target: recipient,
                value: U256::from(forward),
                data: Default::default(),
            },
        ];

        let mut rng = rand::rng();
        let signable = self
            .railgun
            .prepare_userop(
                tb,
                &bundler,
                &account,
                self.signer.clone(),
                weth_addr,
                calls,
                &mut rng,
            )
            .await
            .map_err(|e| classify_prepare_error(&e))?;

        let signed = signable
            .sign(&eoa)
            .await
            .map_err(|e| ExitError::Other(format!("sign userop: {e}")))?;
        let hash = bundler
            .send_user_operation(&signed)
            .await
            .map_err(|e| ExitError::BundlerRejected(e.to_string()))?;
        let hash_hex = exit::format_op_hash(hash.0);
        tracing::info!("exit {index} submitted op {hash_hex}");

        // Return here: receipt polling is `exit::await_exit`, called by the handler WITHOUT
        // holding this mutex, so balance reads stay responsive during a slow inclusion.
        Ok(ExitSubmission {
            user_op_hash: hash_hex,
            sender: format!("{sender:?}"),
            delivered_wei: forward,
            exit_index: index,
        })
    }

    /// Build + prove the unshield (withdraw) tx sending `amount` WETH to `to`.
    /// **Generates a Groth16 proof** (downloads artifacts on first call). The returned tx
    /// is submitted by the LOCAL BROADCASTER's EOA.
    // Removed in Task 6 with the broadcaster itself; kept so every commit builds.
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

/// Map `prepare_userop`'s errors onto our stable codes.
///
/// The missing-paymaster case is a real enum variant, so match it structurally. Do NOT
/// substring-match it: the `Display` text is `"Privacy Paymaster not configured for chain: {id}"`
/// — capital `P` — so a lowercase `"paymaster"` probe silently misses and the failure would be
/// reported as a generic error.
///
/// The convergence failure has no variant of its own: the SDK returns
/// `RailgunProviderError::Other(io::Error("Failed to converge on fee estimate"))`
/// (`railgun/src/provider.rs:328-331`), so on this pin a string match is the only discriminator.
/// Getting it wrong means the gas-gated retry never fires.
fn classify_prepare_error(e: &RailgunProviderError) -> ExitError {
    if matches!(e, RailgunProviderError::PrivacyPaymasterNotConfigured(_)) {
        return ExitError::PaymasterNotConfigured;
    }
    let msg = e.to_string();
    if msg.contains("converge") {
        ExitError::FeeDidNotConverge
    } else {
        ExitError::Other(format!("prove/prepare exit: {msg}"))
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

    #[test]
    fn convergence_failure_is_classified_from_the_sdk_error_string() {
        // Reproduces the exact error the SDK returns after 5 non-converging proof rounds
        // (railgun/src/provider.rs:328-331). If this stops matching, the gas-gated retry
        // never fires and every busy-gas exit reports a generic error instead.
        let e = RailgunProviderError::Other(Box::new(std::io::Error::other(
            "Failed to converge on fee estimate",
        )));
        assert!(e.to_string().contains("converge"), "sdk text: {e}");
        assert_eq!(classify_prepare_error(&e).code(), "feeDidNotConverge");
    }

    #[test]
    fn missing_paymaster_is_classified_by_variant_not_substring() {
        let e = RailgunProviderError::PrivacyPaymasterNotConfigured(11155111);
        assert_eq!(classify_prepare_error(&e).code(), "paymasterNotConfigured");
        // Why we match the variant: the Display text capitalises "Paymaster", so a lowercase
        // substring probe would miss it entirely.
        assert!(
            !e.to_string().contains("paymaster"),
            "sdk text is capitalised, do not substring-match it: {e}"
        );
        assert!(e.to_string().contains("Paymaster"), "sdk text: {e}");
    }

    #[test]
    fn unrelated_sdk_errors_stay_generic() {
        let e = RailgunProviderError::FeeNoteNotFound;
        assert_eq!(classify_prepare_error(&e).code(), "error");
    }
}
