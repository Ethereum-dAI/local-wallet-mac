pub mod call;
pub mod chain_id;
pub mod estimate_gas;
pub mod gas_price;
pub mod get_balance;
pub mod get_block_by_number;
pub mod get_code;
pub mod get_transaction_count;
pub mod get_transaction_receipt;
pub mod max_priority_fee_per_gas;

use wallet_chain::ChainError;
use wallet_node_api::JsonRpcError;

pub(crate) fn map_chain_error(err: ChainError) -> JsonRpcError {
    match err {
        ChainError::Stale {
            helios_head,
            exec_head,
        } => JsonRpcError {
            code: wallet_node_api::HELIOS_STALE,
            message: format!(
                "Helios head {helios_head} is more than 8 blocks behind execution RPC head {exec_head}"
            ),
            data: Some(serde_json::json!({
                "reason": "verified_reads_stale",
                "heliosHead": helios_head,
                "execHead": exec_head,
            })),
        },
        ChainError::StateOverrideUnsupported => JsonRpcError {
            code: wallet_node_api::HELIOS_STATE_OVERRIDE_UNSUPPORTED,
            message: "Helios stateOverride support not detected; bundler refuses ready transition"
                .into(),
            data: Some(serde_json::json!({ "reason": "state_override_unsupported" })),
        },
        ChainError::CallReverted(bytes) => {
            JsonRpcError::simulation_failed("chain_call_reverted", Some(bytes.as_ref()))
        }
        ChainError::BlockNotFound => not_ready("block_not_found", None),
        ChainError::RpcError(error) => not_ready("rpc_error", Some(error)),
        ChainError::Helios(error) => not_ready("helios_error", Some(error)),
        ChainError::CheckpointTooOld { reason } => not_ready("checkpoint_too_old", Some(reason)),
        ChainError::Internal(error) => not_ready("chain_internal_error", Some(error.to_string())),
    }
}

fn not_ready(reason: &'static str, detail: Option<String>) -> JsonRpcError {
    let mut data = serde_json::json!({ "reason": reason });
    if let Some(detail) = detail {
        data["detail"] = serde_json::json!(detail);
    }
    JsonRpcError {
        code: wallet_node_api::NOT_READY,
        message: format!("Not ready: {reason}"),
        data: Some(data),
    }
}

#[cfg(test)]
mod tests {
    use wallet_chain::ChainError;

    use super::map_chain_error;

    #[test]
    fn maps_helios_startup_errors_to_not_ready_with_reason() {
        let err = map_chain_error(ChainError::Helios(
            "out of sync: 1780564590 seconds behind".to_string(),
        ));

        assert_eq!(err.code, wallet_node_api::NOT_READY);
        let data = err.data.expect("error data");
        assert_eq!(data["reason"], "helios_error");
        assert_eq!(data["detail"], "out of sync: 1780564590 seconds behind");
    }

    #[test]
    fn maps_rpc_errors_to_not_ready_with_reason() {
        let err = map_chain_error(ChainError::RpcError("provider warming up".to_string()));

        assert_eq!(err.code, wallet_node_api::NOT_READY);
        let data = err.data.expect("error data");
        assert_eq!(data["reason"], "rpc_error");
        assert_eq!(data["detail"], "provider warming up");
    }
}
