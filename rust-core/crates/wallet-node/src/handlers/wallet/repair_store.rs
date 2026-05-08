use alloy_primitives::{B256, U256};
use serde::Deserialize;
use serde_json::{json, Value};
use wallet_chain::TransactionReceipt;
use wallet_node_api::JsonRpcError;
use wallet_node_store::{NonceStatus, SubmittedTransaction, SubmittedTxStatus, UserOpStatus};

use crate::state::DaemonState;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RepairRequest {
    action: RepairAction,
    #[serde(default)]
    confirm: bool,
    #[serde(default)]
    verify_after_repair: bool,
    #[serde(default)]
    tx_hash: Option<String>,
    #[serde(default)]
    user_op_hash: Option<String>,
    #[serde(default)]
    chain_id: Option<u64>,
    #[serde(default)]
    bundler_address: Option<String>,
    #[serde(default)]
    nonce: Option<u64>,
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
enum RepairAction {
    MarkSubmittedTxFailed,
    AbandonNonceReservation,
    ClearTentativeReceipt,
    MarkTxDropped,
    RebuildUserOpFromReceipt,
    RebuildReceiptFromChain,
}

impl RepairAction {
    fn as_str(&self) -> &'static str {
        match self {
            Self::MarkSubmittedTxFailed => "markSubmittedTxFailed",
            Self::AbandonNonceReservation => "abandonNonceReservation",
            Self::ClearTentativeReceipt => "clearTentativeReceipt",
            Self::MarkTxDropped => "markTxDropped",
            Self::RebuildUserOpFromReceipt => "rebuildUserOpFromReceipt",
            Self::RebuildReceiptFromChain => "rebuildReceiptFromChain",
        }
    }

    fn expected_finding_codes(&self) -> &'static [&'static str] {
        match self {
            Self::MarkSubmittedTxFailed => &["terminal_user_op_has_pending_tx"],
            Self::AbandonNonceReservation => &["terminal_nonce_has_pending_tx"],
            Self::ClearTentativeReceipt => &["receipt_for_non_terminal_user_op_tentative"],
            Self::MarkTxDropped => &["pending_tx_nonce_advanced_without_receipt"],
            Self::RebuildUserOpFromReceipt => &["receipt_for_non_terminal_user_op"],
            Self::RebuildReceiptFromChain => &[
                "chain_receipt_status_conflicts_with_local_tx",
                "chain_user_op_event_conflicts_with_local_status",
                "deep_reorg_suspected",
                "local_receipt_invalidated",
                "local_receipt_stale",
            ],
        }
    }
}

pub async fn handle(state: &DaemonState, params: Value) -> Result<Value, JsonRpcError> {
    let request = parse_request(params)?;
    match request.action {
        RepairAction::MarkSubmittedTxFailed => mark_submitted_tx_failed(state, request).await,
        RepairAction::AbandonNonceReservation => abandon_nonce_reservation(state, request).await,
        RepairAction::ClearTentativeReceipt => clear_tentative_receipt(state, request).await,
        RepairAction::MarkTxDropped => mark_tx_dropped(state, request).await,
        RepairAction::RebuildUserOpFromReceipt => {
            rebuild_user_op_from_receipt(state, request).await
        }
        RepairAction::RebuildReceiptFromChain => rebuild_receipt_from_chain(state, request).await,
    }
}

fn parse_request(params: Value) -> Result<RepairRequest, JsonRpcError> {
    let value = params
        .as_array()
        .and_then(|values| values.first())
        .cloned()
        .unwrap_or(params);
    serde_json::from_value(value).map_err(|err| invalid_params(&format!("{err}")))
}

async fn mark_submitted_tx_failed(
    state: &DaemonState,
    request: RepairRequest,
) -> Result<Value, JsonRpcError> {
    let tx_hash = required(request.tx_hash.as_deref(), "txHash")?;
    let before = state
        .store
        .submitted_tx_get(tx_hash)
        .await
        .map_err(|_| JsonRpcError::internal())?
        .ok_or_else(|| invalid_params("submitted transaction not found"))?;
    let after = json!({
        "txHash": tx_hash,
        "status": SubmittedTxStatus::Failed.as_str(),
    });
    if request.confirm {
        state
            .store
            .submitted_tx_set_status(tx_hash, SubmittedTxStatus::Failed)
            .await
            .map_err(|_| JsonRpcError::internal())?;
        state
            .store
            .diagnostic_set(
                "submitted_transaction",
                tx_hash,
                "manual_repair_marked_failed",
            )
            .await
            .map_err(|_| JsonRpcError::internal())?;
    }
    repair_response(
        state,
        &request,
        json!({ "txHash": before.tx_hash, "status": before.status.as_str() }),
        after,
    )
    .await
}

async fn abandon_nonce_reservation(
    state: &DaemonState,
    request: RepairRequest,
) -> Result<Value, JsonRpcError> {
    let chain_id = request.chain_id.unwrap_or(state.config.network.chain_id);
    let bundler_address = required(request.bundler_address.as_deref(), "bundlerAddress")?;
    let nonce = request
        .nonce
        .ok_or_else(|| invalid_params("nonce is required"))?;
    let before = json!({
        "chainId": chain_id,
        "bundlerAddress": bundler_address,
        "nonce": nonce,
    });
    let after = json!({
        "chainId": chain_id,
        "bundlerAddress": bundler_address,
        "nonce": nonce,
        "status": NonceStatus::Abandoned.as_str(),
    });
    if request.confirm {
        state
            .store
            .nonce_set_status(chain_id, bundler_address, nonce, NonceStatus::Abandoned)
            .await
            .map_err(|_| JsonRpcError::internal())?;
    }
    repair_response(state, &request, before, after).await
}

async fn clear_tentative_receipt(
    state: &DaemonState,
    request: RepairRequest,
) -> Result<Value, JsonRpcError> {
    let user_op_hash = required(request.user_op_hash.as_deref(), "userOpHash")?;
    let before = state
        .store
        .receipt_get(user_op_hash)
        .await
        .map_err(|_| JsonRpcError::internal())?;
    let before_value = json!({
        "userOpHash": user_op_hash,
        "receiptPresent": before.is_some(),
        "tentative": before.as_ref().map(|receipt| receipt.tentative),
    });
    let after = json!({
        "userOpHash": user_op_hash,
        "receiptPresent": false,
    });
    if request.confirm {
        state
            .store
            .receipt_delete_tentative(user_op_hash)
            .await
            .map_err(|_| JsonRpcError::internal())?;
    }
    repair_response(state, &request, before_value, after).await
}

async fn mark_tx_dropped(
    state: &DaemonState,
    request: RepairRequest,
) -> Result<Value, JsonRpcError> {
    if !state.chain.is_synced().await {
        return Err(invalid_params(
            "markTxDropped requires synced verified chain reads",
        ));
    }
    let tx_hash = required(request.tx_hash.as_deref(), "txHash")?;
    let before = state
        .store
        .submitted_tx_get(tx_hash)
        .await
        .map_err(|_| JsonRpcError::internal())?
        .ok_or_else(|| invalid_params("submitted transaction not found"))?;
    let after = json!({
        "txHash": tx_hash,
        "status": SubmittedTxStatus::Dropped.as_str(),
    });
    if request.confirm {
        state
            .store
            .submitted_tx_set_status(tx_hash, SubmittedTxStatus::Dropped)
            .await
            .map_err(|_| JsonRpcError::internal())?;
        state
            .store
            .diagnostic_set(
                "submitted_transaction",
                tx_hash,
                "manual_repair_marked_dropped",
            )
            .await
            .map_err(|_| JsonRpcError::internal())?;
    }
    repair_response(
        state,
        &request,
        json!({ "txHash": before.tx_hash, "status": before.status.as_str() }),
        after,
    )
    .await
}

async fn rebuild_user_op_from_receipt(
    state: &DaemonState,
    request: RepairRequest,
) -> Result<Value, JsonRpcError> {
    let user_op_hash = required(request.user_op_hash.as_deref(), "userOpHash")?;
    let receipt = state
        .store
        .receipt_get(user_op_hash)
        .await
        .map_err(|_| JsonRpcError::internal())?
        .ok_or_else(|| invalid_params("receipt not found"))?;
    if receipt.tentative {
        return Err(invalid_params(
            "cannot rebuild terminal state from tentative receipt",
        ));
    }
    if receipt.invalidated {
        return Err(invalid_params(
            "cannot rebuild terminal state from invalidated receipt",
        ));
    }
    let user_op = state
        .store
        .user_op_get(user_op_hash)
        .await
        .map_err(|_| JsonRpcError::internal())?
        .ok_or_else(|| invalid_params("user operation not found"))?;
    let tx = state
        .store
        .submitted_tx_get(&receipt.tx_hash)
        .await
        .map_err(|_| JsonRpcError::internal())?;
    let new_status = if receipt.success {
        UserOpStatus::Included
    } else {
        UserOpStatus::Reverted
    };
    let before = json!({
        "userOpHash": user_op_hash,
        "userOpStatus": user_op.status.as_str(),
        "txHash": receipt.tx_hash,
        "txPresent": tx.is_some(),
    });
    let after = json!({
        "userOpHash": user_op_hash,
        "userOpStatus": new_status.as_str(),
        "txHash": receipt.tx_hash,
        "txStatus": SubmittedTxStatus::Included.as_str(),
    });
    if request.confirm {
        state
            .store
            .user_op_set_status(user_op_hash, new_status)
            .await
            .map_err(|_| JsonRpcError::internal())?;
        if let Some(tx) = tx {
            state
                .store
                .submitted_tx_set_status(&tx.tx_hash, SubmittedTxStatus::Included)
                .await
                .map_err(|_| JsonRpcError::internal())?;
            state
                .store
                .nonce_set_status(
                    tx.chain_id,
                    &tx.bundler_address,
                    tx.nonce,
                    NonceStatus::Included,
                )
                .await
                .map_err(|_| JsonRpcError::internal())?;
        }
        state
            .store
            .diagnostic_clear("user_operation", user_op_hash)
            .await
            .map_err(|_| JsonRpcError::internal())?;
    }
    repair_response(state, &request, before, after).await
}

async fn rebuild_receipt_from_chain(
    state: &DaemonState,
    request: RepairRequest,
) -> Result<Value, JsonRpcError> {
    if !state.chain.is_synced().await {
        return Err(invalid_params(
            "rebuildReceiptFromChain requires synced verified chain reads",
        ));
    }
    let user_op_hash = required(request.user_op_hash.as_deref(), "userOpHash")?;
    let user_op = state
        .store
        .user_op_get(user_op_hash)
        .await
        .map_err(|_| JsonRpcError::internal())?
        .ok_or_else(|| invalid_params("user operation not found"))?;
    let submitted_txs = state
        .store
        .submitted_txs_list_all()
        .await
        .map_err(|_| JsonRpcError::internal())?;
    let submitted_tx = submitted_txs
        .into_iter()
        .find(|tx| tx.user_op_hash == user_op_hash);
    let local_receipt = state
        .store
        .receipt_get(user_op_hash)
        .await
        .map_err(|_| JsonRpcError::internal())?;
    let tx_hash = request
        .tx_hash
        .as_deref()
        .or_else(|| submitted_tx.as_ref().map(|tx| tx.tx_hash.as_str()))
        .or_else(|| {
            local_receipt
                .as_ref()
                .map(|receipt| receipt.tx_hash.as_str())
        })
        .ok_or_else(|| {
            invalid_params(
                "txHash is required when no submitted transaction or local receipt exists",
            )
        })?;
    let tx_hash_parsed: B256 = tx_hash
        .parse()
        .map_err(|_| invalid_params("txHash must be a transaction hash"))?;
    let chain_receipt = state
        .chain
        .eth_get_transaction_receipt(tx_hash_parsed)
        .await
        .map_err(|_| JsonRpcError::internal())?
        .ok_or_else(|| invalid_params("chain receipt not found"))?;
    let event = matching_user_operation_event(&user_op, &chain_receipt)?;
    let new_status = if event.success {
        UserOpStatus::Included
    } else {
        UserOpStatus::Reverted
    };
    let rebuilt_receipt = wallet_node_store::UserOperationReceipt {
        user_op_hash: user_op_hash.to_string(),
        tx_hash: tx_hash.to_string(),
        success: event.success,
        actual_gas_cost: Some(wallet_bundler::gas::u256_hex(event.actual_gas_cost)),
        actual_gas_used: Some(wallet_bundler::gas::u256_hex(event.actual_gas_used)),
        revert_reason: None,
        receipt_json: serde_json::to_string(&chain_receipt).unwrap_or_else(|_| "{}".to_string()),
        tentative: false,
        invalidated: false,
        created_at: now_unix_seconds(),
    };

    let before = json!({
        "userOpHash": user_op_hash,
        "userOpStatus": user_op.status.as_str(),
        "localReceiptPresent": local_receipt.is_some(),
        "localReceiptInvalidated": local_receipt.as_ref().map(|receipt| receipt.invalidated),
        "txHash": tx_hash,
        "txPresent": submitted_tx.is_some(),
    });
    let after = json!({
        "userOpHash": user_op_hash,
        "userOpStatus": new_status.as_str(),
        "txHash": tx_hash,
        "txStatus": SubmittedTxStatus::Included.as_str(),
        "receiptInvalidated": false,
    });
    if request.confirm {
        state
            .store
            .receipt_upsert(rebuilt_receipt)
            .await
            .map_err(|_| JsonRpcError::internal())?;
        state
            .store
            .user_op_set_status(user_op_hash, new_status)
            .await
            .map_err(|_| JsonRpcError::internal())?;
        if let Some(tx) = submitted_tx.as_ref() {
            mark_tx_included(state, tx).await?;
        }
        state
            .store
            .diagnostic_clear("user_operation", user_op_hash)
            .await
            .map_err(|_| JsonRpcError::internal())?;
        state
            .store
            .diagnostic_clear("user_operation_receipt", user_op_hash)
            .await
            .map_err(|_| JsonRpcError::internal())?;
        state
            .store
            .diagnostic_clear("submitted_transaction", tx_hash)
            .await
            .map_err(|_| JsonRpcError::internal())?;
    }
    repair_response(state, &request, before, after).await
}

fn matching_user_operation_event(
    user_op: &wallet_node_store::UserOperation,
    receipt: &TransactionReceipt,
) -> Result<wallet_bundler::receipt::UserOperationEvent, JsonRpcError> {
    if receipt.status != Some(1) {
        return Err(invalid_params(
            "chain transaction receipt is not successful",
        ));
    }
    let entry_point = user_op
        .entry_point
        .parse()
        .map_err(|_| invalid_params("stored entryPoint is invalid"))?;
    let user_op_hash = user_op
        .user_op_hash
        .parse()
        .map_err(|_| invalid_params("stored userOpHash is invalid"))?;
    let sender = user_op
        .sender
        .parse()
        .map_err(|_| invalid_params("stored sender is invalid"))?;
    let nonce = U256::from_str_radix(user_op.nonce.trim_start_matches("0x"), 16)
        .map_err(|_| invalid_params("stored nonce is invalid"))?;
    wallet_bundler::extract_user_operation_event(
        &receipt.logs,
        entry_point,
        user_op_hash,
        sender,
        nonce,
    )
    .ok_or_else(|| invalid_params("chain receipt does not contain matching UserOperationEvent"))
}

async fn mark_tx_included(
    state: &DaemonState,
    tx: &SubmittedTransaction,
) -> Result<(), JsonRpcError> {
    state
        .store
        .submitted_tx_set_status(&tx.tx_hash, SubmittedTxStatus::Included)
        .await
        .map_err(|_| JsonRpcError::internal())?;
    state
        .store
        .nonce_set_status(
            tx.chain_id,
            &tx.bundler_address,
            tx.nonce,
            NonceStatus::Included,
        )
        .await
        .map_err(|_| JsonRpcError::internal())?;
    Ok(())
}

async fn repair_response(
    state: &DaemonState,
    request: &RepairRequest,
    before: Value,
    after: Value,
) -> Result<Value, JsonRpcError> {
    let mut response = json!({
        "action": request.action.as_str(),
        "dryRun": !request.confirm,
        "confirmed": request.confirm,
        "repairApplied": request.confirm,
        "before": before,
        "after": after,
    });

    if request.verify_after_repair && !request.confirm {
        response["verificationSkippedReason"] = json!("dry_run");
        return Ok(response);
    }

    if request.verify_after_repair {
        let synced = state.chain.is_synced().await;
        let report = crate::handlers::wallet::audit_store::audit_report(state, synced).await?;
        let expected = request.action.expected_finding_codes();
        if expected.is_empty() {
            response["verificationSkippedReason"] = json!("no_targeted_finding_codes");
            return Ok(response);
        }

        let remaining_codes = report
            .findings
            .iter()
            .map(|finding| finding.code.as_str())
            .collect::<std::collections::BTreeSet<_>>();
        let resolved = expected
            .iter()
            .copied()
            .filter(|code| !remaining_codes.contains(code))
            .collect::<Vec<_>>();
        response["resolvedFindingCodes"] = json!(resolved);
        response["remainingFindings"] =
            serde_json::to_value(report.findings).map_err(|_| JsonRpcError::internal())?;
    }

    Ok(response)
}

fn required<'a>(value: Option<&'a str>, field: &str) -> Result<&'a str, JsonRpcError> {
    value.ok_or_else(|| invalid_params(&format!("{field} is required")))
}

fn invalid_params(reason: &str) -> JsonRpcError {
    JsonRpcError {
        code: wallet_node_api::INVALID_REQUEST,
        message: "Invalid request".to_string(),
        data: Some(json!({ "reason": reason })),
    }
}

fn now_unix_seconds() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use serde_json::json;
    use wallet_chain::{Log, MockChainAdapter};
    use wallet_node_store::{
        SubmittedTransaction, SubmittedTxStatus, UserOpStatus,
        UserOperation as StoredUserOperation, UserOperationReceipt,
    };

    use crate::state::DaemonState;

    use super::*;

    fn submitted_tx() -> SubmittedTransaction {
        SubmittedTransaction {
            tx_hash: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
                .to_string(),
            user_op_hash: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                .to_string(),
            chain_id: 1,
            bundler_address: "0xbeef000000000000000000000000000000000000".to_string(),
            nonce: 7,
            raw_tx: "0x02".to_string(),
            max_fee_per_gas: "0x64".to_string(),
            max_priority_fee_per_gas: "0x01".to_string(),
            status: SubmittedTxStatus::Submitted,
            replacement_of: None,
            submitted_at_block: Some(100),
            created_at: 1,
            updated_at: 1,
        }
    }

    fn user_op(status: UserOpStatus) -> StoredUserOperation {
        StoredUserOperation {
            user_op_hash: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                .to_string(),
            chain_id: 1,
            entry_point: format!("{:#x}", wallet_bundler::ENTRY_POINT_V07),
            sender: "0x1000000000000000000000000000000000000000".to_string(),
            nonce: "0x1".to_string(),
            user_op_json: "{}".to_string(),
            status,
            created_at: 1,
            updated_at: 1,
        }
    }

    fn address_topic(address: alloy_primitives::Address) -> B256 {
        let mut bytes = [0_u8; 32];
        bytes[12..].copy_from_slice(address.as_slice());
        B256::from(bytes)
    }

    fn event_data(
        nonce: U256,
        success: bool,
        actual_gas_cost: U256,
        actual_gas_used: U256,
    ) -> alloy_primitives::Bytes {
        let mut bytes = Vec::with_capacity(128);
        bytes.extend_from_slice(&nonce.to_be_bytes::<32>());
        bytes.extend_from_slice(&U256::from(success as u8).to_be_bytes::<32>());
        bytes.extend_from_slice(&actual_gas_cost.to_be_bytes::<32>());
        bytes.extend_from_slice(&actual_gas_used.to_be_bytes::<32>());
        bytes.into()
    }

    fn chain_receipt_for_user_op(tx: &SubmittedTransaction) -> TransactionReceipt {
        let tx_hash = tx.tx_hash.parse().unwrap();
        let user_op_hash = tx.user_op_hash.parse().unwrap();
        let sender = "0x1000000000000000000000000000000000000000"
            .parse()
            .unwrap();
        TransactionReceipt {
            transaction_hash: tx_hash,
            transaction_index: Some(0),
            block_hash: Some(B256::from([0x11; 32])),
            block_number: Some(100),
            from: tx.bundler_address.parse().unwrap(),
            to: Some(wallet_bundler::ENTRY_POINT_V07),
            cumulative_gas_used: 45_678,
            gas_used: Some(45_678),
            contract_address: None,
            logs: vec![Log {
                address: wallet_bundler::ENTRY_POINT_V07,
                topics: vec![
                    wallet_bundler::user_operation_event_topic(),
                    user_op_hash,
                    address_topic(sender),
                    address_topic(alloy_primitives::Address::ZERO),
                ],
                data: event_data(U256::from(1), true, U256::from(1_234), U256::from(45_678)),
                block_hash: None,
                block_number: None,
                transaction_hash: None,
                transaction_index: None,
                log_index: None,
                removed: None,
            }],
            status: Some(1),
            effective_gas_price: None,
        }
    }

    #[tokio::test]
    async fn dry_run_does_not_mutate_tx_status() {
        let state = DaemonState::for_tests(Arc::new(MockChainAdapter::with_synced(true)));
        let tx = submitted_tx();
        state.store.submitted_tx_insert(tx.clone()).await.unwrap();

        let value = handle(
            &state,
            json!([{ "action": "markSubmittedTxFailed", "txHash": tx.tx_hash }]),
        )
        .await
        .unwrap();

        let stored = state
            .store
            .submitted_tx_get("0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(value["dryRun"], true);
        assert_eq!(stored.status, SubmittedTxStatus::Submitted);
    }

    #[tokio::test]
    async fn confirmed_repair_mutates_only_target_tx() {
        let state = DaemonState::for_tests(Arc::new(MockChainAdapter::with_synced(true)));
        let tx = submitted_tx();
        state.store.submitted_tx_insert(tx.clone()).await.unwrap();

        let value = handle(
            &state,
            json!([{
                "action": "markSubmittedTxFailed",
                "txHash": tx.tx_hash,
                "confirm": true
            }]),
        )
        .await
        .unwrap();

        let stored = state
            .store
            .submitted_tx_get("0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(value["confirmed"], true);
        assert_eq!(stored.status, SubmittedTxStatus::Failed);
        assert_eq!(
            state
                .store
                .diagnostic_get(
                    "submitted_transaction",
                    "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                )
                .await
                .unwrap(),
            Some("manual_repair_marked_failed".to_string())
        );
    }

    #[tokio::test]
    async fn unsafe_repair_rejected_when_unsynced() {
        let state = DaemonState::for_tests(Arc::new(MockChainAdapter::with_synced(false)));

        let err = handle(
            &state,
            json!([{ "action": "markTxDropped", "txHash": "0xmissing" }]),
        )
        .await
        .unwrap_err();

        assert_eq!(err.code, wallet_node_api::INVALID_REQUEST);
    }

    #[tokio::test]
    async fn missing_subject_returns_typed_error() {
        let state = DaemonState::for_tests(Arc::new(MockChainAdapter::with_synced(true)));

        let err = handle(&state, json!([{ "action": "markSubmittedTxFailed" }]))
            .await
            .unwrap_err();

        assert_eq!(err.code, wallet_node_api::INVALID_REQUEST);
    }

    #[tokio::test]
    async fn rebuild_from_verified_receipt_updates_terminal_state() {
        let state = DaemonState::for_tests(Arc::new(MockChainAdapter::with_synced(true)));
        let tx = submitted_tx();
        state
            .store
            .user_op_insert(user_op(UserOpStatus::Submitted))
            .await
            .unwrap();
        state.store.submitted_tx_insert(tx.clone()).await.unwrap();
        state
            .store
            .reserve_next_nonce(1, &tx.bundler_address, 7)
            .await
            .unwrap();
        state
            .store
            .nonce_attach_tx_hash(1, &tx.bundler_address, 7, &tx.tx_hash)
            .await
            .unwrap();
        state
            .store
            .receipt_insert(UserOperationReceipt {
                user_op_hash: tx.user_op_hash.clone(),
                tx_hash: tx.tx_hash.clone(),
                success: true,
                actual_gas_cost: None,
                actual_gas_used: None,
                revert_reason: None,
                receipt_json: "{}".to_string(),
                tentative: false,
                invalidated: false,
                created_at: 1,
            })
            .await
            .unwrap();

        let value = handle(
            &state,
            json!([{
                "action": "rebuildUserOpFromReceipt",
                "userOpHash": tx.user_op_hash,
                "confirm": true
            }]),
        )
        .await
        .unwrap();

        assert_eq!(value["after"]["userOpStatus"], "included");
        assert_eq!(
            state
                .store
                .user_op_get("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
                .await
                .unwrap()
                .unwrap()
                .status,
            UserOpStatus::Included
        );
        assert!(state
            .store
            .nonces_list_pending(1, &tx.bundler_address)
            .await
            .unwrap()
            .is_empty());
    }

    #[tokio::test]
    async fn rebuild_user_op_from_receipt_rejects_invalidated_receipt() {
        let state = DaemonState::for_tests(Arc::new(MockChainAdapter::with_synced(true)));
        let tx = submitted_tx();
        state
            .store
            .user_op_insert(user_op(UserOpStatus::Submitted))
            .await
            .unwrap();
        state.store.submitted_tx_insert(tx.clone()).await.unwrap();
        state
            .store
            .reserve_next_nonce(1, &tx.bundler_address, 7)
            .await
            .unwrap();
        state
            .store
            .nonce_attach_tx_hash(1, &tx.bundler_address, 7, &tx.tx_hash)
            .await
            .unwrap();
        state
            .store
            .receipt_insert(UserOperationReceipt {
                user_op_hash: tx.user_op_hash.clone(),
                tx_hash: tx.tx_hash.clone(),
                success: true,
                actual_gas_cost: None,
                actual_gas_used: None,
                revert_reason: None,
                receipt_json: "{}".to_string(),
                tentative: false,
                invalidated: true,
                created_at: 1,
            })
            .await
            .unwrap();

        let err = handle(
            &state,
            json!([{
                "action": "rebuildUserOpFromReceipt",
                "userOpHash": tx.user_op_hash,
                "confirm": true
            }]),
        )
        .await
        .unwrap_err();

        assert_eq!(err.code, wallet_node_api::INVALID_REQUEST);
        assert_eq!(
            err.data,
            Some(json!({
                "reason": "cannot rebuild terminal state from invalidated receipt"
            }))
        );
        assert_eq!(
            state
                .store
                .user_op_get("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
                .await
                .unwrap()
                .unwrap()
                .status,
            UserOpStatus::Submitted
        );
        assert_eq!(
            state
                .store
                .submitted_tx_get(
                    "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
                )
                .await
                .unwrap()
                .unwrap()
                .status,
            SubmittedTxStatus::Submitted
        );
    }

    #[tokio::test]
    async fn rebuild_receipt_from_chain_upserts_invalidated_receipt() {
        let chain = Arc::new(MockChainAdapter::with_synced(true));
        let state = DaemonState::for_tests(chain.clone());
        let tx = submitted_tx();
        chain.set_transaction_receipt(tx.tx_hash.parse().unwrap(), chain_receipt_for_user_op(&tx));
        state
            .store
            .user_op_insert(user_op(UserOpStatus::Submitted))
            .await
            .unwrap();
        state.store.submitted_tx_insert(tx.clone()).await.unwrap();
        state
            .store
            .reserve_next_nonce(1, &tx.bundler_address, 7)
            .await
            .unwrap();
        state
            .store
            .nonce_attach_tx_hash(1, &tx.bundler_address, 7, &tx.tx_hash)
            .await
            .unwrap();
        state
            .store
            .receipt_insert(UserOperationReceipt {
                user_op_hash: tx.user_op_hash.clone(),
                tx_hash: tx.tx_hash.clone(),
                success: false,
                actual_gas_cost: None,
                actual_gas_used: None,
                revert_reason: None,
                receipt_json: "{}".to_string(),
                tentative: false,
                invalidated: true,
                created_at: 1,
            })
            .await
            .unwrap();

        let value = handle(
            &state,
            json!([{
                "action": "rebuildReceiptFromChain",
                "userOpHash": tx.user_op_hash,
                "confirm": true
            }]),
        )
        .await
        .unwrap();

        assert_eq!(value["after"]["userOpStatus"], "included");
        let receipt = state
            .store
            .receipt_get("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
            .await
            .unwrap()
            .unwrap();
        assert!(!receipt.invalidated);
        assert_eq!(receipt.actual_gas_cost.as_deref(), Some("0x4d2"));
        assert_eq!(
            state
                .store
                .submitted_tx_get(
                    "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
                )
                .await
                .unwrap()
                .unwrap()
                .status,
            SubmittedTxStatus::Included
        );
    }

    #[tokio::test]
    async fn rebuild_receipt_from_chain_resolves_invalidated_receipt_audit_finding() {
        let chain = Arc::new(MockChainAdapter::with_synced(true));
        let state = DaemonState::for_tests(chain.clone());
        let tx = submitted_tx();
        chain.set_transaction_receipt(tx.tx_hash.parse().unwrap(), chain_receipt_for_user_op(&tx));
        state
            .store
            .user_op_insert(user_op(UserOpStatus::Submitted))
            .await
            .unwrap();
        state.store.submitted_tx_insert(tx.clone()).await.unwrap();
        state
            .store
            .reserve_next_nonce(1, &tx.bundler_address, 7)
            .await
            .unwrap();
        state
            .store
            .nonce_attach_tx_hash(1, &tx.bundler_address, 7, &tx.tx_hash)
            .await
            .unwrap();
        state
            .store
            .receipt_insert(UserOperationReceipt {
                user_op_hash: tx.user_op_hash.clone(),
                tx_hash: tx.tx_hash.clone(),
                success: false,
                actual_gas_cost: None,
                actual_gas_used: None,
                revert_reason: None,
                receipt_json: "{}".to_string(),
                tentative: false,
                invalidated: true,
                created_at: 1,
            })
            .await
            .unwrap();

        let report = crate::handlers::wallet::audit_store::audit_report(&state, true)
            .await
            .unwrap();
        assert!(report.findings.iter().any(|finding| {
            finding.code == "local_receipt_invalidated"
                && finding.subject.as_deref() == Some(tx.user_op_hash.as_str())
                && finding.recommended_repair_action.as_deref() == Some("rebuildReceiptFromChain")
        }));

        let value = handle(
            &state,
            json!([{
                "action": "rebuildReceiptFromChain",
                "userOpHash": tx.user_op_hash,
                "confirm": true,
                "verifyAfterRepair": true
            }]),
        )
        .await
        .unwrap();

        assert!(value["resolvedFindingCodes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|code| code == "local_receipt_invalidated"));
        let report = crate::handlers::wallet::audit_store::audit_report(&state, true)
            .await
            .unwrap();
        assert!(!report
            .findings
            .iter()
            .any(|finding| finding.code == "local_receipt_invalidated"));
    }

    #[tokio::test]
    async fn confirmed_repair_verifies_resolved_finding() {
        let state = DaemonState::for_tests(Arc::new(MockChainAdapter::with_synced(false)));
        let mut tx = submitted_tx();
        tx.status = SubmittedTxStatus::Submitted;
        state
            .store
            .user_op_insert(user_op(UserOpStatus::Included))
            .await
            .unwrap();
        state.store.submitted_tx_insert(tx.clone()).await.unwrap();

        let value = handle(
            &state,
            json!([{
                "action": "markSubmittedTxFailed",
                "txHash": tx.tx_hash,
                "confirm": true,
                "verifyAfterRepair": true
            }]),
        )
        .await
        .unwrap();

        assert_eq!(value["repairApplied"], true);
        assert!(value["resolvedFindingCodes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|code| code == "terminal_user_op_has_pending_tx"));
        assert!(!value["remainingFindings"]
            .as_array()
            .unwrap()
            .iter()
            .any(|finding| finding["code"] == "terminal_user_op_has_pending_tx"));
    }

    #[tokio::test]
    async fn confirmed_repair_verification_keeps_unrelated_remaining_findings() {
        let state = DaemonState::for_tests(Arc::new(MockChainAdapter::with_synced(false)));
        let tx = submitted_tx();
        state.store.submitted_tx_insert(tx.clone()).await.unwrap();

        let value = handle(
            &state,
            json!([{
                "action": "markSubmittedTxFailed",
                "txHash": tx.tx_hash,
                "confirm": true,
                "verifyAfterRepair": true
            }]),
        )
        .await
        .unwrap();

        assert!(value["remainingFindings"]
            .as_array()
            .unwrap()
            .iter()
            .any(|finding| finding["code"] == "submitted_tx_missing_user_op"));
    }

    #[tokio::test]
    async fn dry_run_verification_is_skipped() {
        let state = DaemonState::for_tests(Arc::new(MockChainAdapter::with_synced(true)));
        let tx = submitted_tx();
        state.store.submitted_tx_insert(tx.clone()).await.unwrap();

        let value = handle(
            &state,
            json!([{
                "action": "markSubmittedTxFailed",
                "txHash": tx.tx_hash,
                "verifyAfterRepair": true
            }]),
        )
        .await
        .unwrap();

        assert_eq!(value["dryRun"], true);
        assert_eq!(value["repairApplied"], false);
        assert_eq!(value["verificationSkippedReason"], "dry_run");
        assert!(value.get("remainingFindings").is_none());
    }
}
