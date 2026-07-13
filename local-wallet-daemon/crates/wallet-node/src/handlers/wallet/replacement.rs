use serde_json::Value;
use wallet_bundler::BundlerTxFees;
use wallet_node_store::SubmittedTransaction;

use crate::state::DaemonState;

pub(crate) const GAS_RELAY_STUCK_REASON: &str = "gas_relay_stuck";

pub(crate) async fn live_cancel_replacement_fees(
    state: &DaemonState,
    previous_fees: BundlerTxFees,
) -> Result<BundlerTxFees, wallet_node_api::JsonRpcError> {
    live_replacement_fees(state, previous_fees).await
}

pub(crate) async fn live_speed_up_replacement_fees(
    state: &DaemonState,
    previous_fees: BundlerTxFees,
) -> Result<BundlerTxFees, wallet_node_api::JsonRpcError> {
    live_replacement_fees(state, previous_fees).await
}

async fn live_replacement_fees(
    state: &DaemonState,
    previous_fees: BundlerTxFees,
) -> Result<BundlerTxFees, wallet_node_api::JsonRpcError> {
    let bumped = wallet_bundler::bumped_transaction_fees(
        previous_fees,
        state.config.policy.min_replacement_bump_pct,
    )
    .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    let chain_max_fee = state
        .chain
        .current_gas_price()
        .await
        .map_err(crate::handlers::eth::map_chain_error)?;
    let chain_priority = state
        .chain
        .current_max_priority_fee_per_gas()
        .await
        .map_err(crate::handlers::eth::map_chain_error)?;
    let (_, _, fast_max_fee) = wallet_bundler::derive_fee_tiers(chain_max_fee);
    let (_, _, fast_priority) = wallet_bundler::derive_fee_tiers(chain_priority);
    let max_priority_fee_per_gas = bumped.max_priority_fee_per_gas.max(fast_priority);
    let max_fee_per_gas = bumped
        .max_fee_per_gas
        .max(fast_max_fee)
        .max(max_priority_fee_per_gas);

    Ok(BundlerTxFees {
        max_fee_per_gas,
        max_priority_fee_per_gas,
    })
}

pub(crate) async fn blocked_reason(
    state: &DaemonState,
    candidate: &SubmittedTransaction,
) -> Option<Value> {
    let previous_fees = BundlerTxFees {
        max_fee_per_gas: parse_stored_u256(&candidate.max_fee_per_gas)?,
        max_priority_fee_per_gas: parse_stored_u256(&candidate.max_priority_fee_per_gas)?,
    };

    match live_speed_up_replacement_fees(state, previous_fees).await {
        Ok(_) => None,
        Err(error) if error.code == wallet_node_api::REPLACEMENT_NOT_POSSIBLE => error.data,
        Err(_) => None,
    }
}

pub(crate) fn parse_stored_u256(value: &str) -> Option<alloy_primitives::U256> {
    alloy_primitives::U256::from_str_radix(value.trim_start_matches("0x"), 16).ok()
}
