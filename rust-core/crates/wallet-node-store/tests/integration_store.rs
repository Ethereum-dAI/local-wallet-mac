use std::{
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

use wallet_node_store::{
    db, migrations, open_read_only, pending_operations, NonceStatus, StoreActor, StoreError,
    SubmittedTransaction, SubmittedTxStatus, UserOpInsertOutcome, UserOpStatus, UserOperation,
    UserOperationReceipt,
};

const CHAIN_ID: u64 = 1;
const BUNDLER: &str = "0xbbbb";
const USER_OP_HASH: &str = "0xuserop";
const TX_HASH: &str = "0xtttt";

fn migrated_in_memory_conn() -> rusqlite::Connection {
    let mut conn = db::open_in_memory().unwrap();
    migrations::apply(&mut conn).unwrap();
    conn
}

fn user_op(
    user_op_hash: &str,
    sender: &str,
    status: UserOpStatus,
    updated_at: i64,
) -> UserOperation {
    UserOperation {
        user_op_hash: user_op_hash.to_owned(),
        chain_id: CHAIN_ID,
        entry_point: "0xentrypoint".to_owned(),
        sender: sender.to_owned(),
        nonce: "0x0".to_owned(),
        user_op_json: format!(r#"{{"hash":"{user_op_hash}","sender":"{sender}"}}"#),
        status,
        created_at: updated_at,
        updated_at,
    }
}

fn submitted_tx(
    tx_hash: &str,
    user_op_hash: &str,
    status: SubmittedTxStatus,
    nonce: u64,
    updated_at: i64,
) -> SubmittedTransaction {
    SubmittedTransaction {
        tx_hash: tx_hash.to_owned(),
        user_op_hash: user_op_hash.to_owned(),
        chain_id: CHAIN_ID,
        bundler_address: BUNDLER.to_owned(),
        nonce,
        raw_tx: format!("0xraw{updated_at}"),
        max_fee_per_gas: "0x3b9aca00".to_owned(),
        max_priority_fee_per_gas: "0x3b9aca0".to_owned(),
        status,
        replacement_of: None,
        submitted_at_block: None,
        created_at: updated_at,
        updated_at,
    }
}

fn receipt(user_op_hash: &str, tx_hash: &str) -> UserOperationReceipt {
    UserOperationReceipt {
        user_op_hash: user_op_hash.to_owned(),
        tx_hash: tx_hash.to_owned(),
        success: true,
        actual_gas_cost: Some("0x5208".to_owned()),
        actual_gas_used: Some("0x100".to_owned()),
        revert_reason: None,
        receipt_json: format!(r#"{{"userOpHash":"{user_op_hash}","txHash":"{tx_hash}"}}"#),
        tentative: false,
        created_at: 1,
    }
}

struct TempStoreDir {
    path: PathBuf,
}

impl TempStoreDir {
    fn new(prefix: &str) -> Self {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!("{prefix}-{}-{now}", std::process::id()));
        std::fs::create_dir(&path).unwrap();

        #[cfg(unix)]
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();

        Self { path }
    }

    fn db_path(&self) -> PathBuf {
        self.path.join("store.sqlite")
    }
}

impl Drop for TempStoreDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

fn migrate_file_db(path: &Path) {
    let mut conn = db::open(path).unwrap();
    migrations::apply(&mut conn).unwrap();
}

#[tokio::test]
async fn end_to_end_submit_lifecycle() {
    let conn = migrated_in_memory_conn();
    let handle = StoreActor::start(conn);

    handle
        .bundler_account_insert(CHAIN_ID, BUNDLER, "bundler-eoa:1")
        .await
        .unwrap();

    let outcome = handle
        .user_op_insert(user_op(USER_OP_HASH, "0xsender", UserOpStatus::Received, 1))
        .await
        .unwrap();
    assert_eq!(outcome, UserOpInsertOutcome::Inserted);

    handle
        .user_op_set_status(USER_OP_HASH, UserOpStatus::Simulated)
        .await
        .unwrap();
    assert_eq!(
        handle
            .user_op_get(USER_OP_HASH)
            .await
            .unwrap()
            .unwrap()
            .status,
        UserOpStatus::Simulated
    );

    let nonce = handle
        .reserve_next_nonce(CHAIN_ID, BUNDLER, 0)
        .await
        .unwrap();
    assert_eq!(nonce, 0);

    handle
        .submitted_tx_insert(submitted_tx(
            TX_HASH,
            USER_OP_HASH,
            SubmittedTxStatus::Submitting,
            nonce,
            2,
        ))
        .await
        .unwrap();
    handle
        .nonce_attach_tx_hash(CHAIN_ID, BUNDLER, nonce, TX_HASH)
        .await
        .unwrap();

    handle
        .submitted_tx_set_status(TX_HASH, SubmittedTxStatus::Submitted)
        .await
        .unwrap();
    handle
        .user_op_set_status(USER_OP_HASH, UserOpStatus::Submitted)
        .await
        .unwrap();
    handle
        .nonce_set_status(CHAIN_ID, BUNDLER, nonce, NonceStatus::Submitted)
        .await
        .unwrap();

    handle
        .submitted_tx_set_status(TX_HASH, SubmittedTxStatus::Included)
        .await
        .unwrap();
    handle
        .user_op_set_status(USER_OP_HASH, UserOpStatus::Included)
        .await
        .unwrap();
    handle
        .nonce_set_status(CHAIN_ID, BUNDLER, nonce, NonceStatus::Included)
        .await
        .unwrap();

    handle
        .receipt_insert(receipt(USER_OP_HASH, TX_HASH))
        .await
        .unwrap();

    let stored_op = handle.user_op_get(USER_OP_HASH).await.unwrap().unwrap();
    assert_eq!(stored_op.status, UserOpStatus::Included);

    let stored_tx = handle.submitted_tx_get(TX_HASH).await.unwrap().unwrap();
    assert_eq!(stored_tx.status, SubmittedTxStatus::Included);

    let pending_nonces = handle.nonces_list_pending(CHAIN_ID, BUNDLER).await.unwrap();
    assert!(pending_nonces.is_empty());

    assert!(handle.receipt_get(USER_OP_HASH).await.unwrap().is_some());

    handle.shutdown_and_wait().await.unwrap();
}

#[tokio::test]
async fn idempotent_send_does_not_consume_second_nonce() {
    let conn = migrated_in_memory_conn();
    let handle = StoreActor::start(conn);

    handle
        .bundler_account_insert(CHAIN_ID, BUNDLER, "bundler-eoa:1")
        .await
        .unwrap();
    assert_eq!(
        handle
            .user_op_insert(user_op(USER_OP_HASH, "0xsender", UserOpStatus::Received, 1,))
            .await
            .unwrap(),
        UserOpInsertOutcome::Inserted
    );

    let nonce = handle
        .reserve_next_nonce(CHAIN_ID, BUNDLER, 0)
        .await
        .unwrap();
    assert_eq!(nonce, 0);
    handle
        .submitted_tx_insert(submitted_tx(
            TX_HASH,
            USER_OP_HASH,
            SubmittedTxStatus::Submitting,
            nonce,
            2,
        ))
        .await
        .unwrap();
    handle
        .nonce_attach_tx_hash(CHAIN_ID, BUNDLER, nonce, TX_HASH)
        .await
        .unwrap();
    handle
        .submitted_tx_set_status(TX_HASH, SubmittedTxStatus::Submitted)
        .await
        .unwrap();
    handle
        .user_op_set_status(USER_OP_HASH, UserOpStatus::Submitted)
        .await
        .unwrap();
    handle
        .nonce_set_status(CHAIN_ID, BUNDLER, nonce, NonceStatus::Submitted)
        .await
        .unwrap();

    let duplicate = UserOperation {
        sender: "0xdifferent".to_owned(),
        user_op_json: r#"{"different":true}"#.to_owned(),
        ..user_op(USER_OP_HASH, "0xdifferent", UserOpStatus::Received, 3)
    };
    let outcome = handle.user_op_insert(duplicate).await.unwrap();
    match outcome {
        UserOpInsertOutcome::AlreadyExists(existing) => {
            assert_eq!(existing.sender, "0xsender");
        }
        other => panic!("expected AlreadyExists, got {other:?}"),
    }

    let pending_nonces = handle.nonces_list_pending(CHAIN_ID, BUNDLER).await.unwrap();
    assert_eq!(pending_nonces.len(), 1);
    assert_eq!(pending_nonces[0].nonce, 0);

    handle.shutdown_and_wait().await.unwrap();
}

#[tokio::test]
async fn watcher_startup_query_filters_pending() {
    let conn = migrated_in_memory_conn();
    let handle = StoreActor::start(conn);

    for (idx, status) in [
        SubmittedTxStatus::Submitting,
        SubmittedTxStatus::Submitted,
        SubmittedTxStatus::Included,
        SubmittedTxStatus::Dropped,
        SubmittedTxStatus::Failed,
    ]
    .into_iter()
    .enumerate()
    {
        handle
            .submitted_tx_insert(submitted_tx(
                &format!("0xtx{idx}"),
                &format!("0xuserop{idx}"),
                status,
                idx as u64,
                (idx + 1) as i64,
            ))
            .await
            .unwrap();
    }

    let watcher_txs = handle.submitted_txs_list_for_watcher().await.unwrap();

    assert_eq!(watcher_txs.len(), 2);
    assert_eq!(watcher_txs[0].status, SubmittedTxStatus::Submitting);
    assert_eq!(watcher_txs[1].status, SubmittedTxStatus::Submitted);
    assert!(watcher_txs[0].updated_at <= watcher_txs[1].updated_at);

    handle.shutdown_and_wait().await.unwrap();
}

#[tokio::test]
async fn migration_idempotent_on_reopen() {
    let mut conn = db::open_in_memory().unwrap();

    migrations::apply(&mut conn).unwrap();
    let user_version: u32 = conn
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .unwrap();
    assert_eq!(user_version, 1);

    migrations::apply(&mut conn).unwrap();
    let user_version: u32 = conn
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .unwrap();
    assert_eq!(user_version, 1);
}

#[tokio::test]
#[ignore = "requires file-backed SQLite for BEGIN IMMEDIATE; run with --include-ignored"]
async fn concurrent_reservations_under_file_backed_db() -> Result<(), StoreError> {
    let temp_dir = TempStoreDir::new("wallet-node-store-concurrent");
    let db_path = temp_dir.db_path();
    migrate_file_db(&db_path);

    let conn = db::open(&db_path)?;
    let handle = StoreActor::start(conn);

    let mut tasks = Vec::new();
    for _ in 0..10 {
        let handle = handle.clone();
        tasks.push(tokio::spawn(async move {
            handle.reserve_next_nonce(CHAIN_ID, BUNDLER, 0).await
        }));
    }

    let mut nonces = Vec::new();
    for task in tasks {
        nonces.push(task.await.map_err(|_| StoreError::Backpressure)??);
    }
    nonces.sort_unstable();

    assert_eq!(nonces, (0..10).collect::<Vec<_>>());

    handle.shutdown_and_wait().await?;
    Ok(())
}

#[tokio::test]
#[ignore = "requires file-backed SQLite + WAL mode; run with --include-ignored"]
async fn wal_writer_reader_concurrency() -> Result<(), StoreError> {
    let temp_dir = TempStoreDir::new("wallet-node-store-wal");
    let db_path = temp_dir.db_path();
    migrate_file_db(&db_path);

    let conn = db::open(&db_path)?;
    let handle = StoreActor::start(conn);

    for idx in 0..5 {
        let outcome = handle
            .user_op_insert(user_op(
                &format!("0xwaluserop{idx}"),
                &format!("0xsender{idx}"),
                UserOpStatus::Received,
                idx,
            ))
            .await?;
        assert_eq!(outcome, UserOpInsertOutcome::Inserted);
    }

    let read_conn = open_read_only(&db_path)?;
    let ops = pending_operations(&read_conn)?;

    // WAL readers observe a consistent snapshot; depending on timing, it may
    // include any number of already-committed writer commands.
    assert!(ops.len() <= 5);

    handle.shutdown_and_wait().await?;
    Ok(())
}
