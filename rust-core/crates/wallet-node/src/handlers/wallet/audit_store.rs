use alloy_primitives::{Address, B256, U256};
use serde::Deserialize;
use serde_json::Value;
use wallet_chain::BlockTag;
use wallet_node_store::{
    AuditFindingSeverity, AuditFindingSource, StoreAuditFinding, SubmittedTxStatus, UserOpStatus,
};

use crate::state::DaemonState;

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AuditRequest {
    #[serde(default)]
    persist: bool,
}

pub async fn handle(
    state: &DaemonState,
    params: Value,
) -> Result<Value, wallet_node_api::JsonRpcError> {
    let request = parse_request(params)?;
    let synced = state.chain.is_synced().await;
    let mut report = audit_report(state, synced).await?;
    if request.persist {
        let run_id = state
            .store
            .audit_report_persist(state.config.network.chain_id, synced, report.clone())
            .await
            .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
        report = report.with_audit_run_id(run_id);
    }

    serde_json::to_value(report).map_err(|_| wallet_node_api::JsonRpcError::internal())
}

pub(crate) async fn audit_report(
    state: &DaemonState,
    synced: bool,
) -> Result<wallet_node_store::StoreAuditReport, wallet_node_api::JsonRpcError> {
    let report = state
        .store
        .audit_store()
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    let chain_findings = audit_chain(state, synced).await;

    Ok(report.with_additional_findings(chain_findings))
}

fn parse_request(params: Value) -> Result<AuditRequest, wallet_node_api::JsonRpcError> {
    let value = params
        .as_array()
        .and_then(|values| values.first())
        .cloned()
        .unwrap_or(params);
    if value.is_null() {
        return Ok(AuditRequest::default());
    }
    serde_json::from_value(value).map_err(|err| wallet_node_api::JsonRpcError {
        code: wallet_node_api::INVALID_REQUEST,
        message: "Invalid request".to_string(),
        data: Some(serde_json::json!({ "reason": err.to_string() })),
    })
}

async fn audit_chain(state: &DaemonState, synced: bool) -> Vec<StoreAuditFinding> {
    let mut findings = Vec::new();
    if !synced {
        findings.push(chain_finding(
            AuditFindingSeverity::Warning,
            "chain_audit_skipped_unsynced",
            None,
            None,
            "chain-backed audit skipped because verified reads are not synced",
            Some("Wait for wallet_health to report verified reads ready, then re-run the audit."),
        ));
        return findings;
    }

    let entry_point = match state.config.bundler.entry_points.first() {
        Some(value) => match value.parse::<Address>() {
            Ok(value) => value,
            Err(_) => {
                findings.push(chain_finding(
                    AuditFindingSeverity::Error,
                    "chain_audit_invalid_entry_point",
                    None,
                    Some(value.clone()),
                    "configured EntryPoint is not a valid address",
                    Some("Fix wallet-node config and restart the daemon."),
                ));
                return findings;
            }
        },
        None => {
            findings.push(chain_finding(
                AuditFindingSeverity::Error,
                "chain_audit_missing_entry_point",
                None,
                None,
                "no EntryPoint is configured",
                Some("Fix wallet-node config and restart the daemon."),
            ));
            return findings;
        }
    };

    let txs = match state.store.submitted_txs_list_all().await {
        Ok(txs) => txs,
        Err(_) => {
            findings.push(chain_finding(
                AuditFindingSeverity::Error,
                "chain_audit_store_read_failed",
                None,
                None,
                "failed to read submitted transactions for chain audit",
                Some("Inspect wallet-node logs and retry after store access is healthy."),
            ));
            return findings;
        }
    };

    for tx in txs {
        let tx_hash = match tx.tx_hash.parse::<B256>() {
            Ok(value) => value,
            Err(_) => {
                findings.push(chain_finding(
                    AuditFindingSeverity::Error,
                    "chain_audit_bad_tx_hash",
                    Some("submitted_transactions"),
                    Some(tx.tx_hash.clone()),
                    "submitted transaction hash is not valid hex",
                    Some("Repair or mark the malformed submitted transaction row failed."),
                ));
                continue;
            }
        };

        let receipt = match state.chain.eth_get_transaction_receipt(tx_hash).await {
            Ok(receipt) => receipt,
            Err(err) => {
                findings.push(chain_finding(
                    AuditFindingSeverity::Warning,
                    "chain_audit_receipt_lookup_failed",
                    Some("submitted_transactions"),
                    Some(tx.tx_hash.clone()),
                    format!("receipt lookup failed: {err}"),
                    Some("Retry the audit after verified chain reads recover."),
                ));
                continue;
            }
        };

        match receipt {
            None => {
                if matches!(
                    tx.status,
                    SubmittedTxStatus::Included
                        | SubmittedTxStatus::Failed
                        | SubmittedTxStatus::Dropped
                ) {
                    let code = if matches!(tx.status, SubmittedTxStatus::Included) {
                        "deep_reorg_suspected"
                    } else {
                        "canonical_receipt_missing"
                    };
                    findings.push(chain_finding(
                        AuditFindingSeverity::Error,
                        code,
                        Some("submitted_transactions"),
                        Some(tx.tx_hash.clone()),
                        "local terminal transaction has no receipt on chain",
                        Some("Investigate possible deep reorg or local row corruption before repair."),
                    ));
                    if state
                        .store
                        .receipt_get(&tx.user_op_hash)
                        .await
                        .ok()
                        .flatten()
                        .is_some()
                    {
                        findings.push(chain_finding(
                            AuditFindingSeverity::Warning,
                            "local_receipt_stale",
                            Some("user_operation_receipts"),
                            Some(tx.user_op_hash.clone()),
                            "local receipt exists for a transaction that is missing from the canonical chain",
                            Some("Rebuild local state only after confirming the stored receipt is verified and canonical."),
                        ));
                    }
                }
                if matches!(
                    tx.status,
                    SubmittedTxStatus::Submitting | SubmittedTxStatus::Submitted
                ) {
                    audit_missing_pending_receipt_nonce(state, &tx, &mut findings).await;
                }
            }
            Some(receipt) => {
                if receipt.status == Some(0) && matches!(tx.status, SubmittedTxStatus::Included) {
                    findings.push(chain_finding(
                        AuditFindingSeverity::Error,
                        "chain_receipt_status_conflicts_with_local_tx",
                        Some("submitted_transactions"),
                        Some(tx.tx_hash.clone()),
                        "local tx is included but chain receipt status is failed",
                        Some(
                            "Rebuild local transaction and UserOp state from the verified receipt.",
                        ),
                    ));
                }
                if receipt.status == Some(1)
                    && matches!(
                        tx.status,
                        SubmittedTxStatus::Failed | SubmittedTxStatus::Dropped
                    )
                {
                    findings.push(chain_finding(
                        AuditFindingSeverity::Error,
                        "chain_receipt_status_conflicts_with_local_tx",
                        Some("submitted_transactions"),
                        Some(tx.tx_hash.clone()),
                        "local tx is failed/dropped but chain receipt status is successful",
                        Some(
                            "Rebuild local transaction and UserOp state from the verified receipt.",
                        ),
                    ));
                }
                audit_user_operation_event(state, entry_point, &tx, &receipt, &mut findings).await;
            }
        }
    }

    audit_active_bundler_nonce(state, &mut findings).await;
    findings
}

async fn audit_missing_pending_receipt_nonce(
    state: &DaemonState,
    tx: &wallet_node_store::SubmittedTransaction,
    findings: &mut Vec<StoreAuditFinding>,
) {
    let bundler = match tx.bundler_address.parse::<Address>() {
        Ok(value) => value,
        Err(_) => {
            findings.push(chain_finding(
                AuditFindingSeverity::Error,
                "chain_audit_bad_bundler_address",
                Some("submitted_transactions"),
                Some(tx.tx_hash.clone()),
                "submitted transaction bundler address is invalid",
                Some("Repair or mark the malformed submitted transaction row failed."),
            ));
            return;
        }
    };
    match state
        .chain
        .eth_get_transaction_count(bundler, BlockTag::Latest)
        .await
    {
        Ok(chain_nonce) if chain_nonce > tx.nonce => findings.push(chain_finding(
            AuditFindingSeverity::Warning,
            "pending_tx_nonce_advanced_without_receipt",
            Some("submitted_transactions"),
            Some(tx.tx_hash.clone()),
            format!(
                "bundler chain nonce {chain_nonce} advanced past pending local nonce {} without a receipt",
                tx.nonce
            ),
            Some("Confirm no receipt exists, then mark the tx dropped or failed explicitly."),
        )),
        Ok(_) => {}
        Err(err) => findings.push(chain_finding(
            AuditFindingSeverity::Warning,
            "chain_audit_bundler_nonce_lookup_failed",
            Some("submitted_transactions"),
            Some(tx.tx_hash.clone()),
            format!("bundler nonce lookup failed: {err}"),
            Some("Retry the audit after verified chain reads recover."),
        )),
    }
}

async fn audit_user_operation_event(
    state: &DaemonState,
    entry_point: Address,
    tx: &wallet_node_store::SubmittedTransaction,
    receipt: &wallet_chain::TransactionReceipt,
    findings: &mut Vec<StoreAuditFinding>,
) {
    if receipt.status != Some(1) {
        return;
    }
    let Some(op) = (match state.store.user_op_get(&tx.user_op_hash).await {
        Ok(op) => op,
        Err(_) => {
            findings.push(chain_finding(
                AuditFindingSeverity::Warning,
                "chain_audit_user_op_read_failed",
                Some("user_operations"),
                Some(tx.user_op_hash.clone()),
                "failed to read stored UserOp for receipt event validation",
                Some("Inspect store health and retry the audit."),
            ));
            return;
        }
    }) else {
        return;
    };
    let user_op_hash = match tx.user_op_hash.parse::<B256>() {
        Ok(value) => value,
        Err(_) => return,
    };
    let sender = match op.sender.parse::<Address>() {
        Ok(value) => value,
        Err(_) => {
            findings.push(chain_finding(
                AuditFindingSeverity::Error,
                "chain_audit_bad_sender",
                Some("user_operations"),
                Some(tx.user_op_hash.clone()),
                "stored UserOp sender is invalid",
                Some("Repair or fail the malformed user operation row."),
            ));
            return;
        }
    };
    let nonce = match U256::from_str_radix(op.nonce.trim_start_matches("0x"), 16) {
        Ok(value) => value,
        Err(_) => {
            findings.push(chain_finding(
                AuditFindingSeverity::Error,
                "chain_audit_bad_user_op_nonce",
                Some("user_operations"),
                Some(tx.user_op_hash.clone()),
                "stored UserOp nonce is invalid",
                Some("Repair or fail the malformed user operation row."),
            ));
            return;
        }
    };
    match wallet_bundler::extract_user_operation_event(
        &receipt.logs,
        entry_point,
        user_op_hash,
        sender,
        nonce,
    ) {
        None => findings.push(chain_finding(
            AuditFindingSeverity::Warning,
            "receipt_missing_user_operation_event",
            Some("submitted_transactions"),
            Some(tx.tx_hash.clone()),
            "chain receipt is successful but has no matching EntryPoint UserOperationEvent",
            Some("Mark the local tx failed or inspect whether the stored UserOp hash/sender/nonce is wrong."),
        )),
        Some(event) => {
            let local_success = matches!(op.status, UserOpStatus::Included);
            let local_reverted = matches!(op.status, UserOpStatus::Reverted);
            if (event.success && local_reverted) || (!event.success && local_success) {
                findings.push(chain_finding(
                    AuditFindingSeverity::Error,
                    "chain_user_op_event_conflicts_with_local_status",
                    Some("user_operations"),
                    Some(tx.user_op_hash.clone()),
                    "UserOperationEvent success flag conflicts with local UserOp terminal status",
                    Some("Rebuild local UserOp status from the verified EntryPoint event."),
                ));
            }
        }
    }
}

async fn audit_active_bundler_nonce(state: &DaemonState, findings: &mut Vec<StoreAuditFinding>) {
    let active = match state
        .store
        .bundler_account_active(state.config.network.chain_id)
        .await
    {
        Ok(active) => active,
        Err(_) => {
            findings.push(chain_finding(
                AuditFindingSeverity::Warning,
                "chain_audit_active_bundler_read_failed",
                Some("bundler_accounts"),
                None,
                "failed to read active bundler EOA for nonce audit",
                Some("Inspect store health and retry the audit."),
            ));
            return;
        }
    };
    let Some(active) = active else {
        return;
    };
    let address = match active.address.parse::<Address>() {
        Ok(value) => value,
        Err(_) => {
            findings.push(chain_finding(
                AuditFindingSeverity::Error,
                "chain_audit_bad_active_bundler_address",
                Some("bundler_accounts"),
                Some(active.address),
                "active bundler EOA address is invalid",
                Some("Rotate or repair the active bundler account row."),
            ));
            return;
        }
    };
    let chain_nonce = match state
        .chain
        .eth_get_transaction_count(address, BlockTag::Latest)
        .await
    {
        Ok(value) => value,
        Err(err) => {
            findings.push(chain_finding(
                AuditFindingSeverity::Warning,
                "chain_audit_active_bundler_nonce_lookup_failed",
                Some("bundler_accounts"),
                Some(active.address),
                format!("active bundler EOA nonce lookup failed: {err}"),
                Some("Retry the audit after verified chain reads recover."),
            ));
            return;
        }
    };
    let pending = match state
        .store
        .nonces_list_pending(state.config.network.chain_id, &active.address)
        .await
    {
        Ok(value) => value,
        Err(_) => return,
    };
    if let Some(lowest) = pending.iter().map(|nonce| nonce.nonce).min() {
        if chain_nonce > lowest {
            findings.push(chain_finding(
                AuditFindingSeverity::Warning,
                "active_bundler_nonce_ahead_of_local_pending",
                Some("nonce_reservations"),
                Some(format!("{}:{lowest}", active.address)),
                format!("active bundler chain nonce {chain_nonce} is ahead of lowest local pending nonce {lowest}"),
                Some("Audit pending tx receipts and mark skipped local nonces dropped or failed."),
            ));
        }
    }
}

fn chain_finding(
    severity: AuditFindingSeverity,
    code: &'static str,
    table: Option<&str>,
    subject: Option<String>,
    message: impl Into<String>,
    suggested_action: Option<&str>,
) -> StoreAuditFinding {
    wallet_node_store::audit::finding_with_repair_action(
        AuditFindingSource::Chain,
        severity,
        code,
        table,
        subject,
        message,
        suggested_action,
        wallet_node_store::audit::recommended_repair_action_for_code(code),
    )
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use alloy_primitives::B256;
    use wallet_chain::{Address, Log, MockChainAdapter, TransactionReceipt};
    use wallet_node_store::{
        BundlerLifecycle, SubmittedTransaction, SubmittedTxStatus, UserOpInsertOutcome,
        UserOpStatus, UserOperation,
    };

    use crate::state::DaemonState;

    use super::*;

    fn submitted_tx(tx_hash: &str, nonce: u64, status: SubmittedTxStatus) -> SubmittedTransaction {
        SubmittedTransaction {
            tx_hash: tx_hash.to_string(),
            user_op_hash: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                .to_string(),
            chain_id: 1,
            bundler_address: "0xbeef000000000000000000000000000000000000".to_string(),
            nonce,
            raw_tx: "0x02".to_string(),
            max_fee_per_gas: "0x64".to_string(),
            max_priority_fee_per_gas: "0x01".to_string(),
            status,
            replacement_of: None,
            submitted_at_block: Some(100),
            created_at: 1,
            updated_at: 1,
        }
    }

    fn stored_user_op(status: UserOpStatus) -> UserOperation {
        UserOperation {
            user_op_hash: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                .to_string(),
            chain_id: 1,
            entry_point: "0x0000000071727de22e5e9d8baf0edac6f37da032".to_string(),
            sender: "0x1000000000000000000000000000000000000000".to_string(),
            nonce: "0x1".to_string(),
            user_op_json: "{}".to_string(),
            status,
            created_at: 1,
            updated_at: 1,
        }
    }

    fn address_topic(address: Address) -> B256 {
        let mut bytes = [0u8; 32];
        bytes[12..].copy_from_slice(address.as_slice());
        B256::from(bytes)
    }

    fn event_data(
        nonce: U256,
        success: bool,
        actual_gas_cost: U256,
        actual_gas_used: U256,
    ) -> wallet_chain::Bytes {
        let mut bytes = Vec::with_capacity(128);
        bytes.extend_from_slice(&nonce.to_be_bytes::<32>());
        bytes.extend_from_slice(&U256::from(success as u8).to_be_bytes::<32>());
        bytes.extend_from_slice(&actual_gas_cost.to_be_bytes::<32>());
        bytes.extend_from_slice(&actual_gas_used.to_be_bytes::<32>());
        bytes.into()
    }

    fn verified_user_op_receipt(tx_hash: B256, success: bool) -> TransactionReceipt {
        let sender: Address = "0x1000000000000000000000000000000000000000"
            .parse()
            .unwrap();
        TransactionReceipt {
            transaction_hash: tx_hash,
            transaction_index: Some(0),
            block_hash: Some(B256::from([0x11; 32])),
            block_number: Some(100),
            from: "0xbeef000000000000000000000000000000000000"
                .parse()
                .unwrap(),
            to: Some(
                "0x0000000071727de22e5e9d8baf0edac6f37da032"
                    .parse()
                    .unwrap(),
            ),
            cumulative_gas_used: 21_000,
            gas_used: Some(21_000),
            contract_address: None,
            logs: vec![Log {
                address: "0x0000000071727de22e5e9d8baf0edac6f37da032"
                    .parse()
                    .unwrap(),
                topics: vec![
                    wallet_bundler::user_operation_event_topic(),
                    "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                        .parse()
                        .unwrap(),
                    address_topic(sender),
                    address_topic(Address::ZERO),
                ],
                data: event_data(
                    U256::from(1),
                    success,
                    U256::from(1_234),
                    U256::from(45_678),
                ),
                block_hash: Some(B256::from([0x11; 32])),
                block_number: Some(100),
                transaction_hash: Some(tx_hash),
                transaction_index: Some(0),
                log_index: Some(0),
                removed: Some(false),
            }],
            status: Some(1),
            effective_gas_price: None,
        }
    }

    #[tokio::test]
    async fn unsynced_chain_returns_warning_instead_of_error() {
        let chain = Arc::new(MockChainAdapter::with_synced(false));
        let state = DaemonState::for_tests(chain);

        let value = handle(&state, serde_json::json!([])).await.unwrap();

        assert_eq!(value["summary"]["warning"], 1);
        assert_eq!(value["findings"][0]["code"], "chain_audit_skipped_unsynced");
    }

    #[tokio::test]
    async fn audit_skips_chain_findings_while_unsynced_then_validates_after_recovery() {
        let chain = Arc::new(MockChainAdapter::with_synced(false));
        let state = DaemonState::for_tests(chain.clone());
        let tx_hash: B256 = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            .parse()
            .unwrap();
        assert!(matches!(
            state
                .store
                .user_op_insert(stored_user_op(UserOpStatus::Included))
                .await
                .unwrap(),
            UserOpInsertOutcome::Inserted
        ));
        state
            .store
            .submitted_tx_insert(submitted_tx(
                "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                7,
                SubmittedTxStatus::Included,
            ))
            .await
            .unwrap();

        let value = handle(&state, serde_json::json!([])).await.unwrap();
        let findings = value["findings"].as_array().unwrap();

        assert!(findings
            .iter()
            .any(|finding| finding["code"] == "chain_audit_skipped_unsynced"));
        assert!(!findings
            .iter()
            .any(|finding| finding["code"] == "deep_reorg_suspected"));
        assert_eq!(chain.receipt_call_count(), 0);

        chain.set_synced(true);
        chain.set_transaction_receipt(tx_hash, verified_user_op_receipt(tx_hash, true));
        let value = handle(&state, serde_json::json!([])).await.unwrap();
        let findings = value["findings"].as_array().unwrap();

        assert!(chain.receipt_call_count() > 0);
        assert!(!findings
            .iter()
            .any(|finding| finding["code"] == "chain_audit_skipped_unsynced"));
        assert!(!findings
            .iter()
            .any(|finding| finding["code"] == "deep_reorg_suspected"));
        assert_eq!(value["summary"]["error"], 0);
    }

    #[tokio::test]
    async fn synced_healthy_empty_store_has_no_chain_findings() {
        let chain = Arc::new(MockChainAdapter::with_synced(true));
        let state = DaemonState::for_tests(chain);

        let value = handle(&state, serde_json::json!([])).await.unwrap();

        assert_eq!(value["summary"]["warning"], 0);
        assert_eq!(value["summary"]["error"], 0);
    }

    #[tokio::test]
    async fn chain_audit_detects_nonce_advanced_without_receipt() {
        let chain = Arc::new(MockChainAdapter::with_synced(true));
        let bundler: Address = "0xbeef000000000000000000000000000000000000"
            .parse()
            .unwrap();
        chain.set_transaction_count(bundler, wallet_chain::BlockTag::Latest, 9);
        let state = DaemonState::for_tests(chain);
        state
            .store
            .submitted_tx_insert(submitted_tx(
                "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                7,
                SubmittedTxStatus::Submitted,
            ))
            .await
            .unwrap();

        let value = handle(&state, serde_json::json!([])).await.unwrap();

        assert!(value["findings"]
            .as_array()
            .unwrap()
            .iter()
            .any(
                |finding| finding["code"] == "pending_tx_nonce_advanced_without_receipt"
                    && finding["recommendedRepairAction"] == "markTxDropped"
            ));
    }

    #[tokio::test]
    async fn chain_errors_become_findings() {
        let chain = Arc::new(MockChainAdapter::with_synced(true));
        chain.inject_error(Box::new(|| {
            wallet_chain::ChainError::RpcError("nope".to_string())
        }));
        let state = DaemonState::for_tests(chain);
        state
            .store
            .submitted_tx_insert(submitted_tx(
                "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                7,
                SubmittedTxStatus::Submitted,
            ))
            .await
            .unwrap();

        let value = handle(&state, serde_json::json!([])).await.unwrap();

        assert!(value["findings"]
            .as_array()
            .unwrap()
            .iter()
            .any(|finding| finding["code"] == "chain_audit_receipt_lookup_failed"));
    }

    #[tokio::test]
    async fn terminal_local_tx_missing_chain_receipt_is_reported() {
        let chain = Arc::new(MockChainAdapter::with_synced(true));
        let state = DaemonState::for_tests(chain);
        state
            .store
            .submitted_tx_insert(submitted_tx(
                "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                7,
                SubmittedTxStatus::Included,
            ))
            .await
            .unwrap();

        let value = handle(&state, serde_json::json!([])).await.unwrap();

        assert!(value["findings"]
            .as_array()
            .unwrap()
            .iter()
            .any(|finding| finding["code"] == "deep_reorg_suspected"));
    }

    #[tokio::test]
    async fn stale_local_receipt_is_reported_when_chain_receipt_is_missing() {
        let chain = Arc::new(MockChainAdapter::with_synced(true));
        let state = DaemonState::for_tests(chain);
        let tx = submitted_tx(
            "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            7,
            SubmittedTxStatus::Included,
        );
        state.store.submitted_tx_insert(tx.clone()).await.unwrap();
        state
            .store
            .receipt_insert(wallet_node_store::UserOperationReceipt {
                user_op_hash: tx.user_op_hash,
                tx_hash: tx.tx_hash,
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

        let value = handle(&state, serde_json::json!([])).await.unwrap();

        assert!(value["findings"]
            .as_array()
            .unwrap()
            .iter()
            .any(|finding| finding["code"] == "local_receipt_stale"
                && finding["recommendedRepairAction"] == "rebuildReceiptFromChain"));
    }

    #[tokio::test]
    async fn receipt_status_conflict_is_reported() {
        let chain = Arc::new(MockChainAdapter::with_synced(true));
        let tx_hash: B256 = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            .parse()
            .unwrap();
        chain.set_transaction_receipt(
            tx_hash,
            TransactionReceipt {
                transaction_hash: tx_hash,
                transaction_index: Some(0),
                block_hash: Some(B256::from([0x11; 32])),
                block_number: Some(100),
                from: "0xbeef000000000000000000000000000000000000"
                    .parse()
                    .unwrap(),
                to: None,
                cumulative_gas_used: 21_000,
                gas_used: Some(21_000),
                contract_address: None,
                logs: vec![],
                status: Some(0),
                effective_gas_price: None,
            },
        );
        let state = DaemonState::for_tests(chain);
        state
            .store
            .submitted_tx_insert(submitted_tx(
                "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                7,
                SubmittedTxStatus::Included,
            ))
            .await
            .unwrap();

        let value = handle(&state, serde_json::json!([])).await.unwrap();

        assert!(value["findings"]
            .as_array()
            .unwrap()
            .iter()
            .any(
                |finding| finding["code"] == "chain_receipt_status_conflicts_with_local_tx"
                    && finding["recommendedRepairAction"] == "rebuildReceiptFromChain"
            ));
    }

    #[tokio::test]
    async fn successful_receipt_without_matching_user_operation_event_is_reported() {
        let chain = Arc::new(MockChainAdapter::with_synced(true));
        let tx_hash: B256 = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            .parse()
            .unwrap();
        chain.set_transaction_receipt(
            tx_hash,
            TransactionReceipt {
                transaction_hash: tx_hash,
                transaction_index: Some(0),
                block_hash: Some(B256::from([0x11; 32])),
                block_number: Some(100),
                from: "0xbeef000000000000000000000000000000000000"
                    .parse()
                    .unwrap(),
                to: Some(
                    "0x0000000071727de22e5e9d8baf0edac6f37da032"
                        .parse()
                        .unwrap(),
                ),
                cumulative_gas_used: 21_000,
                gas_used: Some(21_000),
                contract_address: None,
                logs: vec![],
                status: Some(1),
                effective_gas_price: None,
            },
        );
        let state = DaemonState::for_tests(chain);
        assert!(matches!(
            state
                .store
                .user_op_insert(stored_user_op(UserOpStatus::Included))
                .await
                .unwrap(),
            UserOpInsertOutcome::Inserted
        ));
        state
            .store
            .submitted_tx_insert(submitted_tx(
                "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                7,
                SubmittedTxStatus::Included,
            ))
            .await
            .unwrap();

        let value = handle(&state, serde_json::json!([])).await.unwrap();

        assert!(value["findings"]
            .as_array()
            .unwrap()
            .iter()
            .any(|finding| finding["code"] == "receipt_missing_user_operation_event"));
    }

    #[tokio::test]
    async fn active_bundler_nonce_ahead_of_local_pending_is_reported() {
        let chain = Arc::new(MockChainAdapter::with_synced(true));
        let bundler: Address = "0xbeef000000000000000000000000000000000000"
            .parse()
            .unwrap();
        chain.set_transaction_count(bundler, wallet_chain::BlockTag::Latest, 9);
        let state = DaemonState::for_tests(chain);
        state
            .store
            .bundler_account_insert(1, "0xbeef000000000000000000000000000000000000", "k1")
            .await
            .unwrap();
        state
            .store
            .bundler_account_set_lifecycle(
                1,
                "0xbeef000000000000000000000000000000000000",
                BundlerLifecycle::Active,
            )
            .await
            .unwrap();
        state
            .store
            .reserve_next_nonce(1, "0xbeef000000000000000000000000000000000000", 7)
            .await
            .unwrap();

        let value = handle(&state, serde_json::json!([])).await.unwrap();

        assert!(value["findings"]
            .as_array()
            .unwrap()
            .iter()
            .any(|finding| finding["code"] == "active_bundler_nonce_ahead_of_local_pending"));
    }
}
