use serde_json::{json, Value};
use wallet_bundler::BundlerTxFees;
use wallet_node_store::SubmittedTransaction;

use crate::state::DaemonState;

pub(crate) const GAS_RELAY_STUCK_REASON: &str = "gas_relay_stuck";

pub(crate) async fn blocked_reason(
    state: &DaemonState,
    candidate: &SubmittedTransaction,
) -> Option<Value> {
    let stored_op = state
        .store
        .user_op_get(&candidate.user_op_hash)
        .await
        .ok()
        .flatten()?;
    let raw = serde_json::from_str(&stored_op.user_op_json).ok()?;
    let op = wallet_bundler::UserOperation::parse(raw).ok()?;
    let previous_fees = BundlerTxFees {
        max_fee_per_gas: parse_stored_u256(&candidate.max_fee_per_gas)?,
        max_priority_fee_per_gas: parse_stored_u256(&candidate.max_priority_fee_per_gas)?,
    };

    match wallet_bundler::bumped_replacement_fees(
        previous_fees,
        &op,
        state.config.policy.min_replacement_bump_pct,
    ) {
        Ok(_) => None,
        Err(wallet_bundler::PolicyError::CapExceeded(field)) => Some(json!({
            "reason": GAS_RELAY_STUCK_REASON,
            "field": field
        })),
        Err(wallet_bundler::PolicyError::ReplacementNotPossible(reason)) => Some(json!({
            "reason": reason
        })),
        Err(_) => None,
    }
}

pub(crate) fn parse_stored_u256(value: &str) -> Option<alloy_primitives::U256> {
    alloy_primitives::U256::from_str_radix(value.trim_start_matches("0x"), 16).ok()
}
