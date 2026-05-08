use alloy_primitives::{Address, Bytes, U256};
use alloy_sol_types::{sol, SolCall};
use serde_json::Value;
use wallet_chain::{BlockTag, CallRequest};

use crate::state::DaemonState;

sol! {
    function balanceOf(address account) view returns (uint256);
}

pub async fn handle(
    state: &DaemonState,
    params: Value,
) -> Result<Value, wallet_node_api::JsonRpcError> {
    let params = params
        .as_array()
        .ok_or_else(|| wallet_node_api::JsonRpcError {
            code: wallet_node_api::INVALID_REQUEST,
            message: "Invalid request".to_string(),
            data: Some(serde_json::json!({ "reason": "params must be an array" })),
        })?;
    let smart_account: Address = params
        .first()
        .and_then(Value::as_str)
        .ok_or_else(|| wallet_node_api::JsonRpcError {
            code: wallet_node_api::INVALID_REQUEST,
            message: "Invalid request".to_string(),
            data: Some(serde_json::json!({ "reason": "smartAccount parameter is required" })),
        })?
        .parse()
        .map_err(|_| wallet_node_api::JsonRpcError {
            code: wallet_node_api::INVALID_REQUEST,
            message: "Invalid request".to_string(),
            data: Some(serde_json::json!({ "reason": "smartAccount must be an address" })),
        })?;
    let head = state
        .chain
        .current_head()
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    let block = BlockTag::Hash(head.hash);
    let account_balance = state
        .chain
        .eth_get_balance(smart_account, block)
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    let entry_point: Address = state
        .config
        .bundler
        .entry_points
        .first()
        .ok_or_else(wallet_node_api::JsonRpcError::internal)?
        .parse()
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    let call = balanceOfCall {
        account: smart_account,
    };
    let bytes = state
        .chain
        .eth_call(
            CallRequest {
                to: Some(entry_point),
                data: Some(Bytes::from(call.abi_encode())),
                ..Default::default()
            },
            block,
            None,
        )
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    let entry_point_deposit = if bytes.len() >= 32 {
        U256::from_be_slice(&bytes[bytes.len() - 32..])
    } else {
        U256::ZERO
    };
    let receipt_state = receipt_state_for_sender(state, smart_account).await?;
    Ok(serde_json::json!({
        "smartAccount": format!("{smart_account:#x}"),
        "accountBalance": wallet_bundler::gas::u256_hex(account_balance),
        "entryPointDeposit": wallet_bundler::gas::u256_hex(entry_point_deposit),
        "transferableEth": wallet_bundler::gas::u256_hex(account_balance),
        "gasReserve": wallet_bundler::gas::u256_hex(entry_point_deposit),
        "readyToSend": account_balance > U256::ZERO,
        "readyToSendReason": if account_balance > U256::ZERO { Value::Null } else { Value::String("insufficient_smart_account_balance".to_string()) },
        "receiptState": receipt_state,
        "blockNumber": head.number,
        "blockHash": format!("{:#x}", head.hash)
    }))
}

async fn receipt_state_for_sender(
    state: &DaemonState,
    smart_account: Address,
) -> Result<Value, wallet_node_api::JsonRpcError> {
    let pending = state
        .store
        .user_ops_list_pending()
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    let sender = format!("{smart_account:#x}");
    let mut tentative = Vec::new();
    let mut invalidated = Vec::new();
    for op in pending
        .into_iter()
        .filter(|op| op.sender.eq_ignore_ascii_case(&sender))
    {
        let Some(receipt) = state
            .store
            .receipt_get(&op.user_op_hash)
            .await
            .map_err(|_| wallet_node_api::JsonRpcError::internal())?
        else {
            continue;
        };
        if receipt.tentative {
            tentative.push(op.user_op_hash.clone());
        }
        if receipt.invalidated {
            invalidated.push(op.user_op_hash);
        }
    }
    Ok(serde_json::json!({
        "tentativeUserOps": tentative,
        "invalidatedUserOps": invalidated
    }))
}
