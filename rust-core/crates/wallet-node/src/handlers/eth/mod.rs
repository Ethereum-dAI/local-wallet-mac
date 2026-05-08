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
                "heliosHead": helios_head,
                "execHead": exec_head,
            })),
        },
        ChainError::StateOverrideUnsupported => JsonRpcError {
            code: wallet_node_api::HELIOS_STATE_OVERRIDE_UNSUPPORTED,
            message: "Helios stateOverride support not detected; bundler refuses ready transition"
                .into(),
            data: None,
        },
        ChainError::BlockNotFound => JsonRpcError::internal(),
        _ => JsonRpcError::internal(),
    }
}
