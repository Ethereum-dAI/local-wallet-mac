use alloy_primitives::{Address, B256, U256};
use wallet_chain::{ChainAdapter, TransactionReceipt};
use wallet_node_store::{
    NonceStatus, StoreHandle, SubmittedTransaction, SubmittedTxStatus, UserOpStatus,
    UserOperationReceipt,
};

use crate::receipt::extract_user_operation_event;
use crate::submit::{
    RawTransactionReceiptFetcher, RawTransactionSubmitOutcome, RawTransactionTransport,
};
use crate::{BundlerError, Result};

pub const DEFAULT_REPLACEMENT_ELIGIBILITY_BLOCKS: u64 = 6;
pub const DEFAULT_RECEIPT_RECHECK_DEPTH_BLOCKS: u64 = 12;

pub async fn reconcile_once(
    store: &StoreHandle,
    chain: &dyn ChainAdapter,
    entry_point: Address,
) -> Result<usize> {
    reconcile_once_with_submitter(store, chain, entry_point, None).await
}

pub async fn reconcile_once_with_submitter(
    store: &StoreHandle,
    chain: &dyn ChainAdapter,
    entry_point: Address,
    submitter: Option<&dyn RawTransactionTransport>,
) -> Result<usize> {
    if !chain.is_synced().await {
        return Ok(0);
    }

    let mut transitions = store.receipts_clear_tentative().await?;
    transitions += recheck_active_receipts(
        store,
        chain,
        entry_point,
        DEFAULT_RECEIPT_RECHECK_DEPTH_BLOCKS,
    )
    .await?;
    let pending = store.submitted_txs_list_for_watcher().await?;
    for tx in pending {
        let tx_hash: B256 =
            tx.tx_hash
                .parse()
                .map_err(|_| BundlerError::ReplacementNotPossible {
                    reason: "bad_tx_hash",
                })?;
        let receipt = match chain.eth_get_transaction_receipt(tx_hash).await {
            Ok(receipt) => receipt,
            Err(_) => {
                record_diagnostic(store, &tx, "receipt_lookup_failed").await?;
                return Err(BundlerError::ReplacementNotPossible {
                    reason: "receipt_lookup_failed",
                });
            }
        };
        let Some(receipt) = receipt else {
            if tx.status == SubmittedTxStatus::Submitting {
                transitions +=
                    retry_submitting_raw_transaction(store, submitter, &tx, tx_hash).await?;
            }
            continue;
        };

        if receipt.status != Some(1) {
            record_diagnostic(store, &tx, "transaction_receipt_failed").await?;
            store
                .submitted_tx_set_status(&tx.tx_hash, SubmittedTxStatus::Failed)
                .await?;
            store
                .user_op_set_status(&tx.user_op_hash, UserOpStatus::Failed)
                .await?;
            store
                .nonce_set_status(
                    tx.chain_id,
                    &tx.bundler_address,
                    tx.nonce,
                    NonceStatus::Failed,
                )
                .await?;
            transitions += 1;
            continue;
        }

        let Some(op) = store.user_op_get(&tx.user_op_hash).await? else {
            record_diagnostic(store, &tx, "user_op_row_missing_for_receipt").await?;
            store
                .submitted_tx_set_status(&tx.tx_hash, SubmittedTxStatus::Failed)
                .await?;
            store
                .nonce_set_status(
                    tx.chain_id,
                    &tx.bundler_address,
                    tx.nonce,
                    NonceStatus::Failed,
                )
                .await?;
            transitions += 1;
            continue;
        };
        let user_op_hash =
            tx.user_op_hash
                .parse()
                .map_err(|_| BundlerError::ReplacementNotPossible {
                    reason: "bad_user_op_hash",
                })?;
        let sender = op
            .sender
            .parse()
            .map_err(|_| BundlerError::ReplacementNotPossible {
                reason: "bad_sender",
            })?;
        let nonce = U256::from_str_radix(op.nonce.trim_start_matches("0x"), 16).map_err(|_| {
            BundlerError::ReplacementNotPossible {
                reason: "bad_nonce",
            }
        })?;

        if let Some(event) =
            extract_user_operation_event(&receipt.logs, entry_point, user_op_hash, sender, nonce)
        {
            store
                .submitted_tx_set_status(&tx.tx_hash, SubmittedTxStatus::Included)
                .await?;
            clear_diagnostic(store, &tx).await?;
            store
                .user_op_set_status(
                    &tx.user_op_hash,
                    if event.success {
                        UserOpStatus::Included
                    } else {
                        UserOpStatus::Reverted
                    },
                )
                .await?;
            store
                .nonce_set_status(
                    tx.chain_id,
                    &tx.bundler_address,
                    tx.nonce,
                    NonceStatus::Included,
                )
                .await?;
            store
                .receipt_upsert(UserOperationReceipt {
                    user_op_hash: tx.user_op_hash.clone(),
                    tx_hash: tx.tx_hash.clone(),
                    success: event.success,
                    actual_gas_cost: Some(crate::gas::u256_hex(event.actual_gas_cost)),
                    actual_gas_used: Some(crate::gas::u256_hex(event.actual_gas_used)),
                    revert_reason: None,
                    receipt_json: serde_json::to_string(&receipt)
                        .unwrap_or_else(|_| "{}".to_string()),
                    tentative: false,
                    invalidated: false,
                    created_at: now_unix_seconds(),
                })
                .await?;
        } else {
            record_diagnostic(store, &tx, "receipt_missing_user_operation_event").await?;
            store
                .submitted_tx_set_status(&tx.tx_hash, SubmittedTxStatus::Failed)
                .await?;
            store
                .user_op_set_status(&tx.user_op_hash, UserOpStatus::Failed)
                .await?;
            store
                .nonce_set_status(
                    tx.chain_id,
                    &tx.bundler_address,
                    tx.nonce,
                    NonceStatus::Failed,
                )
                .await?;
        }
        transitions += 1;
    }
    Ok(transitions)
}

async fn recheck_active_receipts(
    store: &StoreHandle,
    chain: &dyn ChainAdapter,
    entry_point: Address,
    maturity_depth: u64,
) -> Result<usize> {
    let candidates = active_receipt_recheck_candidates(store.receipts_list_canonical().await?);
    if candidates.is_empty() {
        return Ok(0);
    }

    let head_number = match chain.current_head().await {
        Ok(head) => head.number,
        Err(_) => {
            if let Some((stored, _)) = candidates.first() {
                if let Err(error) =
                    record_receipt_recheck_diagnostic(store, stored, "receipt_recheck_head_failed")
                        .await
                {
                    tracing::warn!(
                        error = ?error,
                        "failed to record receipt recheck head diagnostic"
                    );
                }
            }
            return Ok(0);
        }
    };
    let mut transitions = 0;

    for (stored, stored_block_number) in candidates {
        if head_number.saturating_sub(stored_block_number) >= maturity_depth {
            continue;
        }

        let tx_hash: B256 =
            stored
                .tx_hash
                .parse()
                .map_err(|_| BundlerError::ReplacementNotPossible {
                    reason: "bad_tx_hash",
                })?;
        let live_receipt = match chain.eth_get_transaction_receipt(tx_hash).await {
            Ok(receipt) => receipt,
            Err(_) => {
                if let Err(error) = record_receipt_recheck_diagnostic(
                    store,
                    &stored,
                    "active_receipt_recheck_lookup_failed",
                )
                .await
                {
                    tracing::warn!(
                        user_op_hash = %stored.user_op_hash,
                        error = %error,
                        "recheck: active receipt lookup diagnostic write failed, skipping candidate"
                    );
                    continue;
                }
                transitions += 1;
                continue;
            }
        };
        let Some(live_receipt) = live_receipt else {
            if let Err(error) = record_receipt_recheck_diagnostic(
                store,
                &stored,
                "active_receipt_recheck_missing_receipt",
            )
            .await
            {
                tracing::warn!(
                    user_op_hash = %stored.user_op_hash,
                    error = %error,
                    "recheck: active receipt missing diagnostic write failed, skipping candidate"
                );
                continue;
            }
            invalidate_active_receipt(store, &stored, "active_receipt_recheck_missing_receipt")
                .await?;
            transitions += 1;
            continue;
        };

        if live_receipt.status != Some(1) {
            if let Err(error) = record_receipt_recheck_diagnostic(
                store,
                &stored,
                "active_receipt_recheck_failed_status",
            )
            .await
            {
                tracing::warn!(
                    user_op_hash = %stored.user_op_hash,
                    error = %error,
                    "recheck: active receipt failed-status diagnostic write failed, skipping candidate"
                );
                continue;
            }
            invalidate_active_receipt(store, &stored, "active_receipt_recheck_failed_status")
                .await?;
            transitions += 1;
            continue;
        }

        if receipt_still_matches_user_operation(store, entry_point, &stored, &live_receipt).await? {
            if let Err(error) = clear_receipt_recheck_diagnostic(store, &stored).await {
                tracing::warn!(
                    user_op_hash = %stored.user_op_hash,
                    error = %error,
                    "recheck: stale receipt diagnostic clear failed, skipping candidate"
                );
                continue;
            }
        } else {
            if let Err(error) = record_receipt_recheck_diagnostic(
                store,
                &stored,
                "active_receipt_recheck_event_mismatch",
            )
            .await
            {
                tracing::warn!(
                    user_op_hash = %stored.user_op_hash,
                    error = %error,
                    "recheck: active receipt event-mismatch diagnostic write failed, skipping candidate"
                );
                continue;
            }
            invalidate_active_receipt(store, &stored, "active_receipt_recheck_event_mismatch")
                .await?;
            transitions += 1;
        }
    }

    Ok(transitions)
}

fn active_receipt_recheck_candidates(
    receipts: Vec<UserOperationReceipt>,
) -> Vec<(UserOperationReceipt, u64)> {
    receipts
        .into_iter()
        .filter_map(|stored| {
            let parsed: TransactionReceipt = serde_json::from_str(&stored.receipt_json).ok()?;
            let block_number = parsed.block_number?;
            Some((stored, block_number))
        })
        .collect()
}

async fn receipt_still_matches_user_operation(
    store: &StoreHandle,
    entry_point: Address,
    stored: &UserOperationReceipt,
    live_receipt: &TransactionReceipt,
) -> Result<bool> {
    let Some(op) = store.user_op_get(&stored.user_op_hash).await? else {
        return Ok(false);
    };
    let user_op_hash: B256 =
        stored
            .user_op_hash
            .parse()
            .map_err(|_| BundlerError::ReplacementNotPossible {
                reason: "bad_user_op_hash",
            })?;
    let sender = op
        .sender
        .parse()
        .map_err(|_| BundlerError::ReplacementNotPossible {
            reason: "bad_sender",
        })?;
    let nonce = U256::from_str_radix(op.nonce.trim_start_matches("0x"), 16).map_err(|_| {
        BundlerError::ReplacementNotPossible {
            reason: "bad_nonce",
        }
    })?;

    Ok(
        extract_user_operation_event(&live_receipt.logs, entry_point, user_op_hash, sender, nonce)
            .map(|event| event.success == stored.success)
            .unwrap_or(false),
    )
}

pub fn eligible_replacement_candidate<'a>(
    pending: &'a [SubmittedTransaction],
    chain_id: u64,
    bundler_address: &str,
    current_block: u64,
    min_age_blocks: u64,
) -> Option<&'a SubmittedTransaction> {
    let oldest = pending
        .iter()
        .filter(|tx| {
            tx.chain_id == chain_id
                && tx.bundler_address.eq_ignore_ascii_case(bundler_address)
                && matches!(
                    tx.status,
                    SubmittedTxStatus::Submitting | SubmittedTxStatus::Submitted
                )
        })
        .min_by_key(|tx| (tx.nonce, tx.created_at, tx.updated_at))?;
    let submitted_at_block = oldest.submitted_at_block?;
    if current_block.saturating_sub(submitted_at_block) >= min_age_blocks {
        Some(oldest)
    } else {
        None
    }
}

pub async fn reconcile_tentative_once(
    store: &StoreHandle,
    receipt_fetcher: &dyn RawTransactionReceiptFetcher,
) -> Result<usize> {
    let pending = store.submitted_txs_list_for_watcher().await?;
    let mut transitions = 0;
    for tx in pending {
        if store.receipt_get(&tx.user_op_hash).await?.is_some() {
            continue;
        }
        let tx_hash: B256 =
            tx.tx_hash
                .parse()
                .map_err(|_| BundlerError::ReplacementNotPossible {
                    reason: "bad_tx_hash",
                })?;
        let Some(receipt) = receipt_fetcher.get_transaction_receipt(tx_hash).await? else {
            continue;
        };
        let Some(status) = receipt.status else {
            continue;
        };
        store
            .receipt_insert(UserOperationReceipt {
                user_op_hash: tx.user_op_hash.clone(),
                tx_hash: tx.tx_hash.clone(),
                success: status == 1,
                actual_gas_cost: None,
                actual_gas_used: receipt.gas_used.map(|gas| format!("0x{gas:x}")),
                revert_reason: None,
                receipt_json: serde_json::to_string(&receipt).unwrap_or_else(|_| "{}".to_string()),
                tentative: true,
                invalidated: false,
                created_at: now_unix_seconds(),
            })
            .await?;
        transitions += 1;
    }
    Ok(transitions)
}

async fn retry_submitting_raw_transaction(
    store: &StoreHandle,
    submitter: Option<&dyn RawTransactionTransport>,
    tx: &SubmittedTransaction,
    tx_hash: B256,
) -> Result<usize> {
    let Some(submitter) = submitter else {
        return Ok(0);
    };
    let raw_tx = parse_hex_bytes(&tx.raw_tx)?;
    match submitter.submit_raw_transaction(&raw_tx, tx_hash).await {
        Err(err) => {
            record_diagnostic(store, tx, "raw_transaction_retry_failed").await?;
            Err(err)
        }
        Ok(outcome) => match outcome {
            RawTransactionSubmitOutcome::Accepted(_)
            | RawTransactionSubmitOutcome::AlreadyKnown
            | RawTransactionSubmitOutcome::NonceTooLow => {
                clear_diagnostic(store, tx).await?;
                store
                    .submitted_tx_set_status(&tx.tx_hash, SubmittedTxStatus::Submitted)
                    .await?;
                store
                    .nonce_set_status(
                        tx.chain_id,
                        &tx.bundler_address,
                        tx.nonce,
                        NonceStatus::Submitted,
                    )
                    .await?;
                store
                    .user_op_set_status(&tx.user_op_hash, UserOpStatus::Submitted)
                    .await?;
                Ok(1)
            }
        },
    }
}

async fn record_diagnostic(
    store: &StoreHandle,
    tx: &SubmittedTransaction,
    reason: &str,
) -> Result<()> {
    store
        .diagnostic_set("user_operation", &tx.user_op_hash, reason)
        .await?;
    store
        .diagnostic_set("submitted_transaction", &tx.tx_hash, reason)
        .await?;
    Ok(())
}

async fn clear_diagnostic(store: &StoreHandle, tx: &SubmittedTransaction) -> Result<()> {
    store
        .diagnostic_clear("user_operation", &tx.user_op_hash)
        .await?;
    store
        .diagnostic_clear("submitted_transaction", &tx.tx_hash)
        .await?;
    Ok(())
}

async fn record_receipt_recheck_diagnostic(
    store: &StoreHandle,
    receipt: &UserOperationReceipt,
    reason: &str,
) -> Result<()> {
    store
        .diagnostic_set("user_operation", &receipt.user_op_hash, reason)
        .await?;
    store
        .diagnostic_set("user_operation_receipt", &receipt.user_op_hash, reason)
        .await?;
    if store.submitted_tx_get(&receipt.tx_hash).await?.is_some() {
        store
            .diagnostic_set("submitted_transaction", &receipt.tx_hash, reason)
            .await?;
    }
    Ok(())
}

async fn invalidate_active_receipt(
    store: &StoreHandle,
    receipt: &UserOperationReceipt,
    _reason: &str,
) -> Result<()> {
    store
        .receipt_mark_invalidated(&receipt.user_op_hash)
        .await?;
    match store.submitted_tx_get(&receipt.tx_hash).await {
        Ok(Some(_)) => {
            if let Err(error) = store
                .submitted_tx_set_status(&receipt.tx_hash, SubmittedTxStatus::Submitting)
                .await
            {
                tracing::warn!(
                    user_op_hash = %receipt.user_op_hash,
                    error = %error,
                    "recheck: submitted transaction reset after receipt invalidation failed"
                );
            }
        }
        Ok(None) => {}
        Err(error) => {
            tracing::warn!(
                user_op_hash = %receipt.user_op_hash,
                error = %error,
                "recheck: submitted transaction lookup after receipt invalidation failed"
            );
        }
    }
    Ok(())
}

async fn clear_receipt_recheck_diagnostic(
    store: &StoreHandle,
    receipt: &UserOperationReceipt,
) -> Result<()> {
    store
        .diagnostic_clear("user_operation", &receipt.user_op_hash)
        .await?;
    store
        .diagnostic_clear("user_operation_receipt", &receipt.user_op_hash)
        .await?;
    if store.submitted_tx_get(&receipt.tx_hash).await?.is_some() {
        store
            .diagnostic_clear("submitted_transaction", &receipt.tx_hash)
            .await?;
    }
    Ok(())
}

fn parse_hex_bytes(value: &str) -> Result<alloy_primitives::Bytes> {
    let Some(hex_value) = value.strip_prefix("0x") else {
        return Err(BundlerError::InvalidTransaction(
            "raw_tx_missing_0x_prefix".to_string(),
        ));
    };
    let bytes = hex::decode(hex_value)
        .map_err(|_| BundlerError::InvalidTransaction("raw_tx_invalid_hex".to_string()))?;
    Ok(bytes.into())
}

fn now_unix_seconds() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

#[cfg(test)]
mod tests {
    use alloy_primitives::Bytes;
    use wallet_chain::types::{BlockHeader, TransactionReceipt};
    use wallet_chain::Log;
    use wallet_chain::MockChainAdapter;
    use wallet_node_store::{
        db, migrations, NonceStatus, StoreActor, SubmittedTransaction, SubmittedTxStatus,
        UserOpStatus, UserOperation, UserOperationReceipt,
    };

    use crate::ENTRY_POINT_V07;

    use super::*;

    fn receipt(user_op_hash: &str, tentative: bool) -> UserOperationReceipt {
        UserOperationReceipt {
            user_op_hash: user_op_hash.to_owned(),
            tx_hash: "0x1111111111111111111111111111111111111111111111111111111111111111"
                .to_owned(),
            success: true,
            actual_gas_cost: None,
            actual_gas_used: None,
            revert_reason: None,
            receipt_json: "{}".to_owned(),
            tentative,
            invalidated: false,
            created_at: 1,
        }
    }

    async fn store_handle() -> wallet_node_store::StoreHandle {
        let mut conn = db::open_in_memory().unwrap();
        migrations::apply(&mut conn).unwrap();
        StoreActor::start(conn)
    }

    fn pending_user_op(user_op_hash: &str, status: UserOpStatus) -> UserOperation {
        UserOperation {
            user_op_hash: user_op_hash.to_owned(),
            chain_id: 1,
            entry_point: format!("{ENTRY_POINT_V07:#x}"),
            sender: "0x1000000000000000000000000000000000000000".to_owned(),
            nonce: "0x1".to_owned(),
            user_op_json: "{}".to_owned(),
            status,
            created_at: 1,
            updated_at: 1,
        }
    }

    fn submitted_tx(
        tx_hash: &str,
        user_op_hash: &str,
        status: SubmittedTxStatus,
    ) -> SubmittedTransaction {
        SubmittedTransaction {
            tx_hash: tx_hash.to_owned(),
            user_op_hash: user_op_hash.to_owned(),
            chain_id: 1,
            bundler_address: "0xbeef000000000000000000000000000000000000".to_owned(),
            nonce: 0,
            raw_tx: "0x020180".to_owned(),
            max_fee_per_gas: "0x3b9aca00".to_owned(),
            max_priority_fee_per_gas: "0x3b9aca0".to_owned(),
            status,
            replacement_of: None,
            submitted_at_block: Some(100),
            created_at: 1,
            updated_at: 1,
        }
    }

    fn submitted_tx_with_nonce(
        tx_hash: &str,
        nonce: u64,
        submitted_at_block: Option<u64>,
    ) -> SubmittedTransaction {
        SubmittedTransaction {
            tx_hash: tx_hash.to_owned(),
            user_op_hash: format!("0xuserop{nonce}"),
            chain_id: 1,
            bundler_address: "0xbeef000000000000000000000000000000000000".to_owned(),
            nonce,
            raw_tx: "0x020180".to_owned(),
            max_fee_per_gas: "0x3b9aca00".to_owned(),
            max_priority_fee_per_gas: "0x3b9aca0".to_owned(),
            status: SubmittedTxStatus::Submitted,
            replacement_of: None,
            submitted_at_block,
            created_at: nonce as i64,
            updated_at: nonce as i64,
        }
    }

    fn address_topic(address: Address) -> B256 {
        let mut bytes = [0u8; 32];
        bytes[12..].copy_from_slice(address.as_slice());
        B256::from(bytes)
    }

    fn verified_receipt(
        tx_hash: &str,
        user_op_hash: &str,
        status: u64,
        event_success: bool,
    ) -> TransactionReceipt {
        let sender: Address = "0x1000000000000000000000000000000000000000"
            .parse()
            .unwrap();
        TransactionReceipt {
            transaction_hash: tx_hash.parse().unwrap(),
            transaction_index: Some(0),
            block_hash: None,
            block_number: Some(10),
            from: "0xbeef000000000000000000000000000000000000"
                .parse()
                .unwrap(),
            to: Some(ENTRY_POINT_V07),
            cumulative_gas_used: 21_000,
            gas_used: Some(21_000),
            contract_address: None,
            logs: vec![Log {
                address: ENTRY_POINT_V07,
                topics: vec![
                    crate::receipt::user_operation_event_topic(),
                    user_op_hash.parse().unwrap(),
                    address_topic(sender),
                    address_topic(Address::ZERO),
                ],
                data: event_data(
                    U256::from(1),
                    event_success,
                    U256::from(1_234),
                    U256::from(45_678),
                ),
                block_hash: None,
                block_number: Some(10),
                transaction_hash: Some(tx_hash.parse().unwrap()),
                transaction_index: Some(0),
                log_index: Some(0),
                removed: Some(false),
            }],
            status: Some(status),
            effective_gas_price: None,
        }
    }

    fn head(number: u64) -> BlockHeader {
        BlockHeader {
            number,
            hash: B256::from([1; 32]),
            parent_hash: B256::from([2; 32]),
            timestamp: 1_700_000_000,
            state_root: None,
            transactions_root: None,
            receipts_root: None,
            gas_used: None,
            gas_limit: None,
            base_fee_per_gas: None,
        }
    }

    fn event_data(
        nonce: U256,
        success: bool,
        actual_gas_cost: U256,
        actual_gas_used: U256,
    ) -> Bytes {
        let mut bytes = Vec::with_capacity(128);
        bytes.extend_from_slice(&nonce.to_be_bytes::<32>());
        bytes.extend_from_slice(&U256::from(success as u8).to_be_bytes::<32>());
        bytes.extend_from_slice(&actual_gas_cost.to_be_bytes::<32>());
        bytes.extend_from_slice(&actual_gas_used.to_be_bytes::<32>());
        bytes.into()
    }

    struct MockSubmitter {
        outcome: RawTransactionSubmitOutcome,
        receipt: Option<TransactionReceipt>,
    }

    #[async_trait::async_trait]
    impl crate::submit::RawTransactionSubmitter for MockSubmitter {
        async fn submit_raw_transaction(
            &self,
            raw_tx: &Bytes,
            expected_tx_hash: B256,
        ) -> Result<RawTransactionSubmitOutcome> {
            assert_eq!(raw_tx.as_ref(), &[0x02, 0x01, 0x80]);
            assert_eq!(
                expected_tx_hash,
                "0x1111111111111111111111111111111111111111111111111111111111111111"
                    .parse::<B256>()
                    .unwrap()
            );
            Ok(self.outcome.clone())
        }
    }

    #[async_trait::async_trait]
    impl RawTransactionReceiptFetcher for MockSubmitter {
        async fn get_transaction_receipt(
            &self,
            tx_hash: B256,
        ) -> Result<Option<TransactionReceipt>> {
            assert_eq!(
                tx_hash,
                "0x1111111111111111111111111111111111111111111111111111111111111111"
                    .parse::<B256>()
                    .unwrap()
            );
            Ok(self.receipt.clone())
        }
    }

    #[tokio::test]
    async fn synced_reconciliation_discards_tentative_receipts() {
        let store = store_handle().await;
        store
            .receipt_insert(receipt(
                "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                true,
            ))
            .await
            .unwrap();
        store
            .receipt_insert(receipt(
                "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                false,
            ))
            .await
            .unwrap();

        let chain = MockChainAdapter::with_synced(true);
        let transitions = reconcile_once(&store, &chain, ENTRY_POINT_V07)
            .await
            .unwrap();

        assert_eq!(transitions, 1);
        assert!(store
            .receipt_get("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
            .await
            .unwrap()
            .is_none());
        assert!(store
            .receipt_get("0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
            .await
            .unwrap()
            .is_some());

        store.shutdown_and_wait().await.unwrap();
    }

    #[tokio::test]
    async fn unsynced_reconciliation_keeps_tentative_receipts() {
        let store = store_handle().await;
        store
            .receipt_insert(receipt(
                "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                true,
            ))
            .await
            .unwrap();

        let chain = MockChainAdapter::with_synced(false);
        let transitions = reconcile_once(&store, &chain, ENTRY_POINT_V07)
            .await
            .unwrap();

        assert_eq!(transitions, 0);
        assert!(store
            .receipt_get("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
            .await
            .unwrap()
            .is_some());

        store.shutdown_and_wait().await.unwrap();
    }

    #[tokio::test]
    async fn active_receipt_recheck_records_diagnostic_when_receipt_disappears() {
        let store = store_handle().await;
        let user_op_hash = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let tx_hash = "0x1111111111111111111111111111111111111111111111111111111111111111";
        let canonical = verified_receipt(tx_hash, user_op_hash, 1, true);
        store
            .user_op_insert(pending_user_op(user_op_hash, UserOpStatus::Included))
            .await
            .unwrap();
        store
            .submitted_tx_insert(submitted_tx(
                tx_hash,
                user_op_hash,
                SubmittedTxStatus::Included,
            ))
            .await
            .unwrap();
        store
            .receipt_insert(UserOperationReceipt {
                user_op_hash: user_op_hash.to_owned(),
                tx_hash: tx_hash.to_owned(),
                success: true,
                actual_gas_cost: Some("0x4d2".to_owned()),
                actual_gas_used: Some("0xb26e".to_owned()),
                revert_reason: None,
                receipt_json: serde_json::to_string(&canonical).unwrap(),
                tentative: false,
                invalidated: false,
                created_at: 1,
            })
            .await
            .unwrap();

        let chain = MockChainAdapter::with_synced(true);
        chain.set_current_head(head(11));
        let transitions = reconcile_once(&store, &chain, ENTRY_POINT_V07)
            .await
            .unwrap();

        assert_eq!(transitions, 1);
        assert_eq!(chain.receipt_call_count(), 2);
        assert_eq!(
            store
                .diagnostic_get("user_operation_receipt", user_op_hash)
                .await
                .unwrap()
                .as_deref(),
            Some("active_receipt_recheck_missing_receipt")
        );
        assert_eq!(
            store
                .diagnostic_get("submitted_transaction", tx_hash)
                .await
                .unwrap()
                .as_deref(),
            Some("active_receipt_recheck_missing_receipt")
        );
        let receipt = store.receipt_get(user_op_hash).await.unwrap().unwrap();
        assert!(!receipt.tentative);
        assert!(receipt.invalidated);
        assert_eq!(receipt.actual_gas_cost, None);
        assert_eq!(receipt.actual_gas_used, None);
        assert_eq!(
            store
                .submitted_tx_get(tx_hash)
                .await
                .unwrap()
                .unwrap()
                .status,
            SubmittedTxStatus::Submitting
        );

        store.shutdown_and_wait().await.unwrap();
    }

    #[tokio::test]
    async fn active_receipt_recheck_head_failure_does_not_abort_pending_receipt_processing() {
        let store = store_handle().await;
        let active_user_op_hash =
            "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let active_tx_hash = "0x1111111111111111111111111111111111111111111111111111111111111111";
        let pending_user_op_hash =
            "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        let pending_tx_hash = "0x2222222222222222222222222222222222222222222222222222222222222222";
        let canonical = verified_receipt(active_tx_hash, active_user_op_hash, 1, true);
        let pending_receipt = verified_receipt(pending_tx_hash, pending_user_op_hash, 1, true);

        store
            .user_op_insert(pending_user_op(active_user_op_hash, UserOpStatus::Included))
            .await
            .unwrap();
        store
            .submitted_tx_insert(submitted_tx(
                active_tx_hash,
                active_user_op_hash,
                SubmittedTxStatus::Included,
            ))
            .await
            .unwrap();
        store
            .receipt_insert(UserOperationReceipt {
                user_op_hash: active_user_op_hash.to_owned(),
                tx_hash: active_tx_hash.to_owned(),
                success: true,
                actual_gas_cost: Some("0x4d2".to_owned()),
                actual_gas_used: Some("0xb26e".to_owned()),
                revert_reason: None,
                receipt_json: serde_json::to_string(&canonical).unwrap(),
                tentative: false,
                invalidated: false,
                created_at: 1,
            })
            .await
            .unwrap();
        store
            .user_op_insert(pending_user_op(
                pending_user_op_hash,
                UserOpStatus::Submitted,
            ))
            .await
            .unwrap();
        store
            .reserve_next_nonce(1, "0xbeef000000000000000000000000000000000000", 0)
            .await
            .unwrap();
        store
            .nonce_attach_tx_hash(
                1,
                "0xbeef000000000000000000000000000000000000",
                0,
                pending_tx_hash,
            )
            .await
            .unwrap();
        store
            .nonce_set_status(
                1,
                "0xbeef000000000000000000000000000000000000",
                0,
                NonceStatus::Submitted,
            )
            .await
            .unwrap();
        store
            .submitted_tx_insert(submitted_tx(
                pending_tx_hash,
                pending_user_op_hash,
                SubmittedTxStatus::Submitted,
            ))
            .await
            .unwrap();

        let chain = MockChainAdapter::with_synced(true);
        chain.inject_current_head_error(Box::new(|| {
            wallet_chain::ChainError::RpcError("head temporarily unavailable".to_string())
        }));
        chain.set_transaction_receipt(pending_tx_hash.parse().unwrap(), pending_receipt);
        let transitions = reconcile_once(&store, &chain, ENTRY_POINT_V07)
            .await
            .unwrap();

        assert_eq!(transitions, 1);
        assert_eq!(chain.current_head_call_count(), 1);
        assert_eq!(chain.receipt_call_count(), 1);
        assert_eq!(
            store
                .diagnostic_get("user_operation_receipt", active_user_op_hash)
                .await
                .unwrap()
                .as_deref(),
            Some("receipt_recheck_head_failed")
        );
        assert_eq!(
            store
                .user_op_get(pending_user_op_hash)
                .await
                .unwrap()
                .unwrap()
                .status,
            UserOpStatus::Included
        );

        store.shutdown_and_wait().await.unwrap();
    }

    #[tokio::test]
    async fn recheck_per_candidate_store_error_does_not_abort_other_candidates() {
        let active_error_user_op_hash =
            "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let active_error_tx_hash =
            "0x1111111111111111111111111111111111111111111111111111111111111111";
        let active_success_user_op_hash =
            "0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
        let active_success_tx_hash =
            "0x3333333333333333333333333333333333333333333333333333333333333333";
        let pending_user_op_hash =
            "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        let pending_tx_hash = "0x2222222222222222222222222222222222222222222222222222222222222222";

        let mut conn = db::open_in_memory().unwrap();
        migrations::apply(&mut conn).unwrap();
        conn.execute(
            &format!(
                "CREATE TRIGGER fail_recheck_diag_for_first_candidate \
                 BEFORE INSERT ON operation_diagnostics \
                 WHEN NEW.subject_type = 'user_operation_receipt' \
                 AND NEW.subject_id = '{}' \
                 BEGIN \
                 SELECT RAISE(ABORT, 'injected diagnostic failure'); \
                 END",
                active_error_user_op_hash
            ),
            [],
        )
        .unwrap();
        let store = StoreActor::start(conn);

        let active_error_receipt =
            verified_receipt(active_error_tx_hash, active_error_user_op_hash, 1, true);
        let active_success_receipt =
            verified_receipt(active_success_tx_hash, active_success_user_op_hash, 1, true);
        let pending_receipt = verified_receipt(pending_tx_hash, pending_user_op_hash, 1, true);

        store
            .receipt_insert(UserOperationReceipt {
                user_op_hash: active_error_user_op_hash.to_owned(),
                tx_hash: active_error_tx_hash.to_owned(),
                success: true,
                actual_gas_cost: Some("0x4d2".to_owned()),
                actual_gas_used: Some("0xb26e".to_owned()),
                revert_reason: None,
                receipt_json: serde_json::to_string(&active_error_receipt).unwrap(),
                tentative: false,
                invalidated: false,
                created_at: 1,
            })
            .await
            .unwrap();
        store
            .receipt_insert(UserOperationReceipt {
                user_op_hash: active_success_user_op_hash.to_owned(),
                tx_hash: active_success_tx_hash.to_owned(),
                success: true,
                actual_gas_cost: Some("0x4d2".to_owned()),
                actual_gas_used: Some("0xb26e".to_owned()),
                revert_reason: None,
                receipt_json: serde_json::to_string(&active_success_receipt).unwrap(),
                tentative: false,
                invalidated: false,
                created_at: 2,
            })
            .await
            .unwrap();
        store
            .user_op_insert(pending_user_op(
                pending_user_op_hash,
                UserOpStatus::Submitted,
            ))
            .await
            .unwrap();
        store
            .reserve_next_nonce(1, "0xbeef000000000000000000000000000000000000", 0)
            .await
            .unwrap();
        store
            .nonce_attach_tx_hash(
                1,
                "0xbeef000000000000000000000000000000000000",
                0,
                pending_tx_hash,
            )
            .await
            .unwrap();
        store
            .nonce_set_status(
                1,
                "0xbeef000000000000000000000000000000000000",
                0,
                NonceStatus::Submitted,
            )
            .await
            .unwrap();
        store
            .submitted_tx_insert(submitted_tx(
                pending_tx_hash,
                pending_user_op_hash,
                SubmittedTxStatus::Submitted,
            ))
            .await
            .unwrap();

        let chain = MockChainAdapter::with_synced(true);
        chain.set_current_head(head(11));
        chain.set_transaction_receipt(pending_tx_hash.parse().unwrap(), pending_receipt);

        let transitions = reconcile_once(&store, &chain, ENTRY_POINT_V07)
            .await
            .unwrap();

        assert_eq!(transitions, 2);
        assert_eq!(chain.receipt_call_count(), 3);
        assert!(
            !store
                .receipt_get(active_error_user_op_hash)
                .await
                .unwrap()
                .unwrap()
                .invalidated
        );
        assert!(
            store
                .receipt_get(active_success_user_op_hash)
                .await
                .unwrap()
                .unwrap()
                .invalidated
        );
        assert_eq!(
            store
                .diagnostic_get("user_operation_receipt", active_success_user_op_hash)
                .await
                .unwrap()
                .as_deref(),
            Some("active_receipt_recheck_missing_receipt")
        );
        assert_eq!(
            store
                .user_op_get(pending_user_op_hash)
                .await
                .unwrap()
                .unwrap()
                .status,
            UserOpStatus::Included
        );
        assert_eq!(
            store
                .submitted_tx_get(pending_tx_hash)
                .await
                .unwrap()
                .unwrap()
                .status,
            SubmittedTxStatus::Included
        );

        store.shutdown_and_wait().await.unwrap();
    }

    #[tokio::test]
    async fn active_receipt_recheck_clears_stale_diagnostic_when_receipt_still_matches() {
        let store = store_handle().await;
        let user_op_hash = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let tx_hash = "0x1111111111111111111111111111111111111111111111111111111111111111";
        let canonical = verified_receipt(tx_hash, user_op_hash, 1, true);
        store
            .user_op_insert(pending_user_op(user_op_hash, UserOpStatus::Included))
            .await
            .unwrap();
        store
            .submitted_tx_insert(submitted_tx(
                tx_hash,
                user_op_hash,
                SubmittedTxStatus::Included,
            ))
            .await
            .unwrap();
        store
            .receipt_insert(UserOperationReceipt {
                user_op_hash: user_op_hash.to_owned(),
                tx_hash: tx_hash.to_owned(),
                success: true,
                actual_gas_cost: Some("0x4d2".to_owned()),
                actual_gas_used: Some("0xb26e".to_owned()),
                revert_reason: None,
                receipt_json: serde_json::to_string(&canonical).unwrap(),
                tentative: false,
                invalidated: false,
                created_at: 1,
            })
            .await
            .unwrap();
        store
            .diagnostic_set(
                "user_operation_receipt",
                user_op_hash,
                "active_receipt_recheck_missing_receipt",
            )
            .await
            .unwrap();

        let chain = MockChainAdapter::with_synced(true);
        chain.set_current_head(head(11));
        chain.set_transaction_receipt(tx_hash.parse().unwrap(), canonical);
        let transitions = reconcile_once(&store, &chain, ENTRY_POINT_V07)
            .await
            .unwrap();

        assert_eq!(transitions, 0);
        assert_eq!(chain.receipt_call_count(), 1);
        assert!(store
            .diagnostic_get("user_operation_receipt", user_op_hash)
            .await
            .unwrap()
            .is_none());

        store.shutdown_and_wait().await.unwrap();
    }

    #[tokio::test]
    async fn submitting_row_without_receipt_is_retried_and_marked_submitted() {
        let store = store_handle().await;
        let user_op_hash = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let tx_hash = "0x1111111111111111111111111111111111111111111111111111111111111111";
        store
            .user_op_insert(pending_user_op(user_op_hash, UserOpStatus::Simulated))
            .await
            .unwrap();
        store
            .reserve_next_nonce(1, "0xbeef000000000000000000000000000000000000", 0)
            .await
            .unwrap();
        store
            .nonce_attach_tx_hash(1, "0xbeef000000000000000000000000000000000000", 0, tx_hash)
            .await
            .unwrap();
        store
            .submitted_tx_insert(submitted_tx(
                tx_hash,
                user_op_hash,
                SubmittedTxStatus::Submitting,
            ))
            .await
            .unwrap();

        let chain = MockChainAdapter::with_synced(true);
        let submitter = MockSubmitter {
            outcome: RawTransactionSubmitOutcome::AlreadyKnown,
            receipt: None,
        };
        let transitions =
            reconcile_once_with_submitter(&store, &chain, ENTRY_POINT_V07, Some(&submitter))
                .await
                .unwrap();

        assert_eq!(transitions, 1);
        assert_eq!(
            store
                .submitted_tx_get(tx_hash)
                .await
                .unwrap()
                .unwrap()
                .status,
            SubmittedTxStatus::Submitted
        );
        assert_eq!(
            store
                .user_op_get(user_op_hash)
                .await
                .unwrap()
                .unwrap()
                .status,
            UserOpStatus::Submitted
        );
        assert_eq!(
            store
                .nonces_list_pending(1, "0xbeef000000000000000000000000000000000000")
                .await
                .unwrap()[0]
                .status,
            NonceStatus::Submitted
        );

        store.shutdown_and_wait().await.unwrap();
    }

    #[tokio::test]
    async fn unsynced_then_recovered_reconciliation_converges_without_intermediate_mutation() {
        let store = store_handle().await;
        let user_op_hash = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let tx_hash = "0x1111111111111111111111111111111111111111111111111111111111111111";
        store
            .user_op_insert(pending_user_op(user_op_hash, UserOpStatus::Submitted))
            .await
            .unwrap();
        store
            .reserve_next_nonce(1, "0xbeef000000000000000000000000000000000000", 0)
            .await
            .unwrap();
        store
            .nonce_attach_tx_hash(1, "0xbeef000000000000000000000000000000000000", 0, tx_hash)
            .await
            .unwrap();
        store
            .nonce_set_status(
                1,
                "0xbeef000000000000000000000000000000000000",
                0,
                NonceStatus::Submitted,
            )
            .await
            .unwrap();
        store
            .submitted_tx_insert(submitted_tx(
                tx_hash,
                user_op_hash,
                SubmittedTxStatus::Submitted,
            ))
            .await
            .unwrap();
        let chain = MockChainAdapter::with_synced(false);

        let transitions = reconcile_once(&store, &chain, ENTRY_POINT_V07)
            .await
            .unwrap();

        assert_eq!(transitions, 0);
        assert_eq!(chain.receipt_call_count(), 0);
        assert_eq!(
            store
                .submitted_tx_get(tx_hash)
                .await
                .unwrap()
                .unwrap()
                .status,
            SubmittedTxStatus::Submitted
        );
        assert_eq!(
            store
                .user_op_get(user_op_hash)
                .await
                .unwrap()
                .unwrap()
                .status,
            UserOpStatus::Submitted
        );
        assert_eq!(
            store
                .nonces_list_pending(1, "0xbeef000000000000000000000000000000000000")
                .await
                .unwrap()[0]
                .status,
            NonceStatus::Submitted
        );
        assert!(store.receipt_get(user_op_hash).await.unwrap().is_none());

        chain.set_synced(true);
        chain.set_transaction_receipt(
            tx_hash.parse().unwrap(),
            verified_receipt(tx_hash, user_op_hash, 1, true),
        );
        let transitions = reconcile_once(&store, &chain, ENTRY_POINT_V07)
            .await
            .unwrap();

        assert_eq!(transitions, 1);
        assert_eq!(
            store
                .submitted_tx_get(tx_hash)
                .await
                .unwrap()
                .unwrap()
                .status,
            SubmittedTxStatus::Included
        );
        assert_eq!(
            store
                .user_op_get(user_op_hash)
                .await
                .unwrap()
                .unwrap()
                .status,
            UserOpStatus::Included
        );
        assert_eq!(
            store
                .nonces_list_pending(1, "0xbeef000000000000000000000000000000000000")
                .await
                .unwrap()
                .len(),
            0
        );
        let stored_receipt = store.receipt_get(user_op_hash).await.unwrap().unwrap();
        assert!(!stored_receipt.tentative);
        assert!(stored_receipt.success);

        store.shutdown_and_wait().await.unwrap();
    }

    #[tokio::test]
    async fn verified_inclusion_marks_nonce_included() {
        let store = store_handle().await;
        let user_op_hash = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let tx_hash = "0x1111111111111111111111111111111111111111111111111111111111111111";
        store
            .user_op_insert(pending_user_op(user_op_hash, UserOpStatus::Submitted))
            .await
            .unwrap();
        store
            .reserve_next_nonce(1, "0xbeef000000000000000000000000000000000000", 0)
            .await
            .unwrap();
        store
            .nonce_attach_tx_hash(1, "0xbeef000000000000000000000000000000000000", 0, tx_hash)
            .await
            .unwrap();
        store
            .nonce_set_status(
                1,
                "0xbeef000000000000000000000000000000000000",
                0,
                NonceStatus::Submitted,
            )
            .await
            .unwrap();
        store
            .submitted_tx_insert(submitted_tx(
                tx_hash,
                user_op_hash,
                SubmittedTxStatus::Submitted,
            ))
            .await
            .unwrap();
        let chain = MockChainAdapter::with_synced(true);
        chain.set_transaction_receipt(
            tx_hash.parse().unwrap(),
            verified_receipt(tx_hash, user_op_hash, 1, true),
        );

        let transitions = reconcile_once(&store, &chain, ENTRY_POINT_V07)
            .await
            .unwrap();

        assert_eq!(transitions, 1);
        assert_eq!(
            store
                .nonces_list_pending(1, "0xbeef000000000000000000000000000000000000")
                .await
                .unwrap()
                .len(),
            0
        );
        assert_eq!(
            store
                .submitted_tx_get(tx_hash)
                .await
                .unwrap()
                .unwrap()
                .status,
            SubmittedTxStatus::Included
        );
        assert_eq!(
            store
                .user_op_get(user_op_hash)
                .await
                .unwrap()
                .unwrap()
                .status,
            UserOpStatus::Included
        );
        let stored_receipt = store.receipt_get(user_op_hash).await.unwrap().unwrap();
        assert!(stored_receipt.success);
        assert_eq!(stored_receipt.actual_gas_cost, Some("0x4d2".to_owned()));
        assert_eq!(stored_receipt.actual_gas_used, Some("0xb26e".to_owned()));

        store.shutdown_and_wait().await.unwrap();
    }

    #[tokio::test]
    async fn verified_reverted_user_operation_keeps_nonce_included() {
        let store = store_handle().await;
        let user_op_hash = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let tx_hash = "0x1111111111111111111111111111111111111111111111111111111111111111";
        store
            .user_op_insert(pending_user_op(user_op_hash, UserOpStatus::Submitted))
            .await
            .unwrap();
        store
            .reserve_next_nonce(1, "0xbeef000000000000000000000000000000000000", 0)
            .await
            .unwrap();
        store
            .nonce_attach_tx_hash(1, "0xbeef000000000000000000000000000000000000", 0, tx_hash)
            .await
            .unwrap();
        store
            .nonce_set_status(
                1,
                "0xbeef000000000000000000000000000000000000",
                0,
                NonceStatus::Submitted,
            )
            .await
            .unwrap();
        store
            .submitted_tx_insert(submitted_tx(
                tx_hash,
                user_op_hash,
                SubmittedTxStatus::Submitted,
            ))
            .await
            .unwrap();
        let chain = MockChainAdapter::with_synced(true);
        chain.set_transaction_receipt(
            tx_hash.parse().unwrap(),
            verified_receipt(tx_hash, user_op_hash, 1, false),
        );

        let transitions = reconcile_once(&store, &chain, ENTRY_POINT_V07)
            .await
            .unwrap();

        assert_eq!(transitions, 1);
        assert_eq!(
            store
                .submitted_tx_get(tx_hash)
                .await
                .unwrap()
                .unwrap()
                .status,
            SubmittedTxStatus::Included
        );
        assert_eq!(
            store
                .user_op_get(user_op_hash)
                .await
                .unwrap()
                .unwrap()
                .status,
            UserOpStatus::Reverted
        );
        assert_eq!(
            store
                .nonces_list_pending(1, "0xbeef000000000000000000000000000000000000")
                .await
                .unwrap()
                .len(),
            0
        );
        let stored_receipt = store.receipt_get(user_op_hash).await.unwrap().unwrap();
        assert!(!stored_receipt.success);
        assert_eq!(stored_receipt.actual_gas_cost, Some("0x4d2".to_owned()));
        assert_eq!(stored_receipt.actual_gas_used, Some("0xb26e".to_owned()));

        store.shutdown_and_wait().await.unwrap();
    }

    #[tokio::test]
    async fn verified_failed_receipt_marks_nonce_failed() {
        let store = store_handle().await;
        let user_op_hash = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let tx_hash = "0x1111111111111111111111111111111111111111111111111111111111111111";
        store
            .user_op_insert(pending_user_op(user_op_hash, UserOpStatus::Submitted))
            .await
            .unwrap();
        store
            .reserve_next_nonce(1, "0xbeef000000000000000000000000000000000000", 0)
            .await
            .unwrap();
        store
            .nonce_attach_tx_hash(1, "0xbeef000000000000000000000000000000000000", 0, tx_hash)
            .await
            .unwrap();
        store
            .nonce_set_status(
                1,
                "0xbeef000000000000000000000000000000000000",
                0,
                NonceStatus::Submitted,
            )
            .await
            .unwrap();
        store
            .submitted_tx_insert(submitted_tx(
                tx_hash,
                user_op_hash,
                SubmittedTxStatus::Submitted,
            ))
            .await
            .unwrap();
        let chain = MockChainAdapter::with_synced(true);
        chain.set_transaction_receipt(
            tx_hash.parse().unwrap(),
            verified_receipt(tx_hash, user_op_hash, 0, true),
        );

        let transitions = reconcile_once(&store, &chain, ENTRY_POINT_V07)
            .await
            .unwrap();

        assert_eq!(transitions, 1);
        assert_eq!(
            store
                .nonces_list_pending(1, "0xbeef000000000000000000000000000000000000")
                .await
                .unwrap()
                .len(),
            0
        );
        assert!(store.receipt_get(user_op_hash).await.unwrap().is_none());
        assert_eq!(
            store
                .diagnostic_get("user_operation", user_op_hash)
                .await
                .unwrap(),
            Some("transaction_receipt_failed".to_string())
        );
        assert_eq!(
            store
                .diagnostic_get("submitted_transaction", tx_hash)
                .await
                .unwrap(),
            Some("transaction_receipt_failed".to_string())
        );

        store.shutdown_and_wait().await.unwrap();
    }

    #[tokio::test]
    async fn receipt_lookup_failure_records_diagnostic_without_mutating_then_recovers() {
        let store = store_handle().await;
        let user_op_hash = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let tx_hash = "0x1111111111111111111111111111111111111111111111111111111111111111";
        store
            .user_op_insert(pending_user_op(user_op_hash, UserOpStatus::Submitted))
            .await
            .unwrap();
        store
            .reserve_next_nonce(1, "0xbeef000000000000000000000000000000000000", 0)
            .await
            .unwrap();
        store
            .nonce_attach_tx_hash(1, "0xbeef000000000000000000000000000000000000", 0, tx_hash)
            .await
            .unwrap();
        store
            .nonce_set_status(
                1,
                "0xbeef000000000000000000000000000000000000",
                0,
                NonceStatus::Submitted,
            )
            .await
            .unwrap();
        store
            .submitted_tx_insert(submitted_tx(
                tx_hash,
                user_op_hash,
                SubmittedTxStatus::Submitted,
            ))
            .await
            .unwrap();
        let chain = MockChainAdapter::with_synced(true);
        chain.inject_error(Box::new(|| {
            wallet_chain::ChainError::RpcError("temporary outage with provider body".to_string())
        }));

        let err = reconcile_once(&store, &chain, ENTRY_POINT_V07)
            .await
            .unwrap_err();

        assert!(matches!(
            err,
            BundlerError::ReplacementNotPossible {
                reason: "receipt_lookup_failed"
            }
        ));
        assert_eq!(
            store
                .submitted_tx_get(tx_hash)
                .await
                .unwrap()
                .unwrap()
                .status,
            SubmittedTxStatus::Submitted
        );
        assert_eq!(
            store
                .user_op_get(user_op_hash)
                .await
                .unwrap()
                .unwrap()
                .status,
            UserOpStatus::Submitted
        );
        assert_eq!(
            store
                .nonces_list_pending(1, "0xbeef000000000000000000000000000000000000")
                .await
                .unwrap()[0]
                .status,
            NonceStatus::Submitted
        );
        assert!(store.receipt_get(user_op_hash).await.unwrap().is_none());
        assert_eq!(
            store
                .diagnostic_get("user_operation", user_op_hash)
                .await
                .unwrap(),
            Some("receipt_lookup_failed".to_string())
        );
        assert_eq!(
            store
                .diagnostic_get("submitted_transaction", tx_hash)
                .await
                .unwrap(),
            Some("receipt_lookup_failed".to_string())
        );

        chain.clear_error();
        chain.set_transaction_receipt(
            tx_hash.parse().unwrap(),
            verified_receipt(tx_hash, user_op_hash, 1, true),
        );
        let transitions = reconcile_once(&store, &chain, ENTRY_POINT_V07)
            .await
            .unwrap();

        assert_eq!(transitions, 1);
        assert_eq!(
            store
                .submitted_tx_get(tx_hash)
                .await
                .unwrap()
                .unwrap()
                .status,
            SubmittedTxStatus::Included
        );
        assert_eq!(
            store
                .user_op_get(user_op_hash)
                .await
                .unwrap()
                .unwrap()
                .status,
            UserOpStatus::Included
        );
        assert_eq!(
            store
                .nonces_list_pending(1, "0xbeef000000000000000000000000000000000000")
                .await
                .unwrap()
                .len(),
            0
        );
        assert!(store.receipt_get(user_op_hash).await.unwrap().is_some());
        assert_eq!(
            store
                .diagnostic_get("user_operation", user_op_hash)
                .await
                .unwrap(),
            None
        );
        assert_eq!(
            store
                .diagnostic_get("submitted_transaction", tx_hash)
                .await
                .unwrap(),
            None
        );

        store.shutdown_and_wait().await.unwrap();
    }

    #[tokio::test]
    async fn tentative_reconciliation_inserts_display_only_receipt() {
        let store = store_handle().await;
        let user_op_hash = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let tx_hash = "0x1111111111111111111111111111111111111111111111111111111111111111";
        store
            .user_op_insert(pending_user_op(user_op_hash, UserOpStatus::Submitted))
            .await
            .unwrap();
        store
            .submitted_tx_insert(submitted_tx(
                tx_hash,
                user_op_hash,
                SubmittedTxStatus::Submitted,
            ))
            .await
            .unwrap();
        let receipt = TransactionReceipt {
            transaction_hash: tx_hash.parse().unwrap(),
            transaction_index: Some(0),
            block_hash: None,
            block_number: Some(10),
            from: "0xbeef000000000000000000000000000000000000"
                .parse()
                .unwrap(),
            to: Some(ENTRY_POINT_V07),
            cumulative_gas_used: 21_000,
            gas_used: Some(21_000),
            contract_address: None,
            logs: Vec::new(),
            status: Some(1),
            effective_gas_price: None,
        };
        let submitter = MockSubmitter {
            outcome: RawTransactionSubmitOutcome::AlreadyKnown,
            receipt: Some(receipt),
        };

        let transitions = reconcile_tentative_once(&store, &submitter).await.unwrap();

        assert_eq!(transitions, 1);
        let stored_receipt = store.receipt_get(user_op_hash).await.unwrap().unwrap();
        assert!(stored_receipt.tentative);
        assert!(stored_receipt.success);
        assert_eq!(stored_receipt.actual_gas_used, Some("0x5208".to_owned()));
        assert_eq!(
            store
                .submitted_tx_get(tx_hash)
                .await
                .unwrap()
                .unwrap()
                .status,
            SubmittedTxStatus::Submitted
        );
        assert_eq!(
            store
                .user_op_get(user_op_hash)
                .await
                .unwrap()
                .unwrap()
                .status,
            UserOpStatus::Submitted
        );
        assert_eq!(
            reconcile_tentative_once(&store, &submitter).await.unwrap(),
            0
        );

        store.shutdown_and_wait().await.unwrap();
    }

    #[tokio::test]
    async fn submitting_row_without_submitter_waits_for_later_retry() {
        let store = store_handle().await;
        let user_op_hash = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let tx_hash = "0x1111111111111111111111111111111111111111111111111111111111111111";
        store
            .user_op_insert(pending_user_op(user_op_hash, UserOpStatus::Simulated))
            .await
            .unwrap();
        store
            .submitted_tx_insert(submitted_tx(
                tx_hash,
                user_op_hash,
                SubmittedTxStatus::Submitting,
            ))
            .await
            .unwrap();

        let chain = MockChainAdapter::with_synced(true);
        let transitions = reconcile_once_with_submitter(&store, &chain, ENTRY_POINT_V07, None)
            .await
            .unwrap();

        assert_eq!(transitions, 0);
        assert_eq!(
            store
                .submitted_tx_get(tx_hash)
                .await
                .unwrap()
                .unwrap()
                .status,
            SubmittedTxStatus::Submitting
        );

        store.shutdown_and_wait().await.unwrap();
    }

    #[test]
    fn replacement_candidate_uses_oldest_pending_nonce_when_old_enough() {
        let pending = vec![
            submitted_tx_with_nonce(
                "0x2222222222222222222222222222222222222222222222222222222222222222",
                2,
                Some(100),
            ),
            submitted_tx_with_nonce(
                "0x1111111111111111111111111111111111111111111111111111111111111111",
                1,
                Some(100),
            ),
        ];

        let candidate = eligible_replacement_candidate(
            &pending,
            1,
            "0xBEEF000000000000000000000000000000000000",
            106,
            DEFAULT_REPLACEMENT_ELIGIBILITY_BLOCKS,
        )
        .unwrap();

        assert_eq!(
            candidate.tx_hash,
            "0x1111111111111111111111111111111111111111111111111111111111111111"
        );
    }

    #[test]
    fn replacement_candidate_waits_until_min_age_blocks() {
        let pending = vec![submitted_tx_with_nonce(
            "0x1111111111111111111111111111111111111111111111111111111111111111",
            1,
            Some(100),
        )];

        assert!(eligible_replacement_candidate(
            &pending,
            1,
            "0xbeef000000000000000000000000000000000000",
            105,
            DEFAULT_REPLACEMENT_ELIGIBILITY_BLOCKS,
        )
        .is_none());
        assert!(eligible_replacement_candidate(
            &pending,
            1,
            "0xbeef000000000000000000000000000000000000",
            106,
            DEFAULT_REPLACEMENT_ELIGIBILITY_BLOCKS,
        )
        .is_some());
    }

    #[test]
    fn replacement_candidate_ignores_unknown_block_and_wrong_account() {
        let mut pending = vec![submitted_tx_with_nonce(
            "0x1111111111111111111111111111111111111111111111111111111111111111",
            1,
            None,
        )];
        assert!(eligible_replacement_candidate(
            &pending,
            1,
            "0xbeef000000000000000000000000000000000000",
            200,
            DEFAULT_REPLACEMENT_ELIGIBILITY_BLOCKS,
        )
        .is_none());

        pending[0].submitted_at_block = Some(100);
        assert!(eligible_replacement_candidate(
            &pending,
            1,
            "0xdead000000000000000000000000000000000000",
            200,
            DEFAULT_REPLACEMENT_ELIGIBILITY_BLOCKS,
        )
        .is_none());
    }
}
