use alloy_primitives::{Address, B256, U256};
use wallet_chain::ChainAdapter;
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
    let pending = store.submitted_txs_list_for_watcher().await?;
    for tx in pending {
        let tx_hash: B256 =
            tx.tx_hash
                .parse()
                .map_err(|_| BundlerError::ReplacementNotPossible {
                    reason: "bad_tx_hash",
                })?;
        let Some(receipt) = chain
            .eth_get_transaction_receipt(tx_hash)
            .await
            .map_err(|_| BundlerError::ReplacementNotPossible {
                reason: "receipt_lookup_failed",
            })?
        else {
            if tx.status == SubmittedTxStatus::Submitting {
                transitions +=
                    retry_submitting_raw_transaction(store, submitter, &tx, tx_hash).await?;
            }
            continue;
        };

        if receipt.status != Some(1) {
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
                .receipt_insert(UserOperationReceipt {
                    user_op_hash: tx.user_op_hash.clone(),
                    tx_hash: tx.tx_hash.clone(),
                    success: event.success,
                    actual_gas_cost: Some(crate::gas::u256_hex(event.actual_gas_cost)),
                    actual_gas_used: Some(crate::gas::u256_hex(event.actual_gas_used)),
                    revert_reason: None,
                    receipt_json: serde_json::to_string(&receipt)
                        .unwrap_or_else(|_| "{}".to_string()),
                    tentative: false,
                    created_at: now_unix_seconds(),
                })
                .await?;
        } else {
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
    match submitter.submit_raw_transaction(&raw_tx, tx_hash).await? {
        RawTransactionSubmitOutcome::Accepted(_)
        | RawTransactionSubmitOutcome::AlreadyKnown
        | RawTransactionSubmitOutcome::NonceTooLow => {
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
    }
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
    use wallet_chain::types::TransactionReceipt;
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
