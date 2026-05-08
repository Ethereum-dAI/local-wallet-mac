use std::future::Future;
use std::sync::Arc;
use std::time::{Duration, Instant};

use alloy_primitives::Address;
use tokio::sync::watch;
use tokio::task::JoinHandle;
use wallet_bundler::{
    BundlerError, RawTransactionReceiptFetcher, RawTransactionSubmitClient, RawTransactionTransport,
};
use wallet_node_store::BundlerLifecycle;

use crate::state::DaemonState;

const TENTATIVE_RECEIPT_AFTER: Duration = Duration::from_secs(60);
const STATE_OVERRIDE_SMOKE_MAX_ATTEMPTS: usize = 3;

pub(crate) fn spawn_receipt_watcher(
    state: Arc<DaemonState>,
    shutdown_rx: watch::Receiver<bool>,
    interval: Duration,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        run_receipt_watcher(state, shutdown_rx, interval).await;
    })
}

pub(crate) fn spawn_state_override_smoke(
    state: Arc<DaemonState>,
    shutdown_rx: watch::Receiver<bool>,
    interval: Duration,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        run_state_override_smoke(state, shutdown_rx, interval).await;
    })
}

async fn run_state_override_smoke(
    state: Arc<DaemonState>,
    shutdown_rx: watch::Receiver<bool>,
    interval: Duration,
) {
    let chain = state.chain.clone();
    run_state_override_smoke_with(state, shutdown_rx, interval, move || {
        let chain = chain.clone();
        async move { wallet_chain::run_smoke_test(chain.as_ref()).await }
    })
    .await;
}

async fn run_state_override_smoke_with<F, Fut>(
    state: Arc<DaemonState>,
    mut shutdown_rx: watch::Receiver<bool>,
    interval: Duration,
    mut smoke_test: F,
) where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<(), wallet_chain::ChainError>>,
{
    let mut ticker = tokio::time::interval(interval);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    loop {
        tokio::select! {
            changed = shutdown_rx.changed() => {
                if changed.is_err() || *shutdown_rx.borrow() {
                    tracing::debug!("stateOverride smoke watcher stopping");
                    return;
                }
            }
            _ = ticker.tick() => {
                if !state.chain.is_synced().await {
                    continue;
                }
                for attempt in 1..=STATE_OVERRIDE_SMOKE_MAX_ATTEMPTS {
                    match smoke_test().await {
                        Ok(()) => {
                            state.mark_state_override_smoke_passed();
                            tracing::info!("stateOverride smoke test passed");
                            return;
                        }
                        Err(err) if attempt == STATE_OVERRIDE_SMOKE_MAX_ATTEMPTS => {
                            state.mark_state_override_smoke_failed(err.to_string());
                            tracing::warn!(
                                error = %err,
                                attempt,
                                max_attempts = STATE_OVERRIDE_SMOKE_MAX_ATTEMPTS,
                                "stateOverride smoke test failed"
                            );
                            return;
                        }
                        Err(err) => {
                            let delay = state_override_smoke_retry_delay(interval, attempt);
                            tracing::warn!(
                                error = %err,
                                attempt,
                                max_attempts = STATE_OVERRIDE_SMOKE_MAX_ATTEMPTS,
                                retry_after_ms = delay.as_millis(),
                                "stateOverride smoke test attempt failed"
                            );
                            if sleep_or_shutdown(&mut shutdown_rx, delay).await {
                                tracing::debug!("stateOverride smoke watcher stopping");
                                return;
                            }
                        }
                    }
                }
            }
        }
    }
}

fn state_override_smoke_retry_delay(interval: Duration, failed_attempt: usize) -> Duration {
    let multiplier = 1_u32.checked_shl((failed_attempt - 1) as u32).unwrap_or(1);
    interval.saturating_mul(multiplier)
}

async fn sleep_or_shutdown(shutdown_rx: &mut watch::Receiver<bool>, delay: Duration) -> bool {
    tokio::select! {
        changed = shutdown_rx.changed() => changed.is_err() || *shutdown_rx.borrow(),
        _ = tokio::time::sleep(delay) => false,
    }
}

async fn run_receipt_watcher(
    state: Arc<DaemonState>,
    mut shutdown_rx: watch::Receiver<bool>,
    interval: Duration,
) {
    let entry_point = match configured_entry_point(&state) {
        Ok(entry_point) => entry_point,
        Err(err) => {
            tracing::warn!(error = %err, "receipt watcher disabled");
            return;
        }
    };
    let submit_client = configured_submit_client(&state);
    let mut unsynced_since: Option<Instant> = None;
    let mut error_backoff = ReceiptWatcherBackoff::new(interval, Duration::from_secs(60));
    let mut next_attempt_after: Option<Instant> = None;
    let mut ticker = tokio::time::interval(interval);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    loop {
        tokio::select! {
            changed = shutdown_rx.changed() => {
                if changed.is_err() || *shutdown_rx.borrow() {
                    tracing::debug!("receipt watcher stopping");
                    return;
                }
            }
            _ = ticker.tick() => {
                if let Some(next_attempt) = next_attempt_after {
                    if Instant::now() < next_attempt {
                        continue;
                    }
                }

                let mut recovered_after_unsynced = false;
                let result = if state.chain.is_synced().await {
                    recovered_after_unsynced = unsynced_since.take().is_some();
                    let transport = submit_client
                        .as_ref()
                        .map(|client| client as &dyn RawTransactionTransport);
                    wallet_bundler::watcher::reconcile_once_with_submitter(
                        &state.store,
                        state.chain.as_ref(),
                        entry_point,
                        transport,
                    ).await
                } else {
                    let since = match unsynced_since {
                        Some(since) => since,
                        None => {
                            log_receipt_watcher_unsynced_skip();
                            let now = Instant::now();
                            unsynced_since = Some(now);
                            now
                        }
                    };
                    if since.elapsed() >= TENTATIVE_RECEIPT_AFTER {
                        match submit_client
                            .as_ref()
                            .map(|client| client as &dyn RawTransactionReceiptFetcher)
                        {
                            Some(fetcher) => wallet_bundler::watcher::reconcile_tentative_once(
                                &state.store,
                                fetcher,
                            ).await,
                            None => Ok(0),
                        }
                    } else {
                        Ok(0)
                    }
                };
                let result = match result {
                    Ok(transitions) => retire_drained_relayer_keys(&state)
                        .await
                        .map(|retired| transitions + retired)
                        .map_err(BundlerError::from),
                    Err(err) => Err(err),
                };

                match result {
                    Ok(transitions) if transitions > 0 => {
                        error_backoff.record_success();
                        next_attempt_after = None;
                        log_receipt_watcher_reconciled(transitions, recovered_after_unsynced);
                    }
                    Ok(_) => {
                        error_backoff.record_success();
                        next_attempt_after = None;
                    }
                    Err(err) => {
                        let delay = error_backoff.record_failure();
                        next_attempt_after = Some(Instant::now() + delay);
                        log_receipt_watcher_failure(&err, delay);
                    }
                }
            }
        }
    }
}

pub(crate) async fn retire_drained_relayer_keys(
    state: &DaemonState,
) -> Result<usize, wallet_node_store::StoreError> {
    let owner_scope = wallet_node_store::DEFAULT_OWNER_SCOPE;
    let chain_id = state.config.network.chain_id;
    let pending = state.store.submitted_txs_list_for_watcher().await?;
    let accounts = state
        .store
        .bundler_account_list_for_owner(owner_scope, chain_id)
        .await?;
    let mut retired = 0;

    for account in accounts
        .into_iter()
        .filter(|account| account.lifecycle == BundlerLifecycle::Retiring)
    {
        let has_pending = pending.iter().any(|tx| {
            tx.chain_id == account.chain_id
                && tx.bundler_address.eq_ignore_ascii_case(&account.address)
        });
        if has_pending {
            continue;
        }

        state
            .store
            .bundler_account_set_lifecycle_for_owner(
                &account.owner_scope,
                account.chain_id,
                &account.address,
                BundlerLifecycle::Retired,
            )
            .await?;
        let mut retired_account = account.clone();
        retired_account.lifecycle = BundlerLifecycle::Retired;
        if let Err(err) = crate::handlers::wallet::relayer_audit::record(
            state,
            "relayer_key_retired",
            &retired_account,
            None,
            "success",
            None,
        )
        .await
        {
            tracing::warn!(
                error = ?err,
                relayer = %retired_account.address,
                "failed to record relayer retirement audit event"
            );
        }
        retired += 1;
    }

    Ok(retired)
}

fn log_receipt_watcher_unsynced_skip() {
    tracing::info!(
        event = "receipt_watcher_unsynced_skip",
        reason = "verified_reads_unsynced",
        "receipt watcher skipped because verified reads are unsynced"
    );
}

fn log_receipt_watcher_reconciled(transitions: usize, recovered_after_unsynced: bool) {
    if recovered_after_unsynced {
        tracing::info!(
            event = "receipt_watcher_recovered",
            transitions,
            "receipt watcher recovered and reconciled transactions"
        );
    } else {
        tracing::info!(
            event = "receipt_watcher_reconciled",
            transitions,
            "receipt watcher reconciled transactions"
        );
    }
}

fn log_receipt_watcher_failure(err: &BundlerError, delay: Duration) {
    tracing::warn!(
        event = "receipt_watcher_pass_failed",
        error.kind = receipt_watcher_error_kind(err),
        retry_after_ms = delay.as_millis(),
        "receipt watcher pass failed"
    );
}

fn receipt_watcher_error_kind(err: &BundlerError) -> &'static str {
    match err {
        BundlerError::ReplacementNotPossible { reason } => reason,
        BundlerError::RawTransactionSubmission { .. } => "raw_transaction_submission_failed",
        BundlerError::Chain(_) => "chain_error",
        BundlerError::Store(_) => "store_error",
        BundlerError::InvalidTransaction(_) => "invalid_transaction",
        BundlerError::InvalidUserOperation(_) => "invalid_user_operation",
        BundlerError::EntrypointNotAllowlisted(_) => "entrypoint_not_allowlisted",
        BundlerError::ChainMismatch { .. } => "chain_mismatch",
        BundlerError::PolicyCapExceeded { .. } => "policy_cap_exceeded",
        BundlerError::PaymasterNotSupported => "paymaster_not_supported",
        BundlerError::SignatureMissing => "signature_missing",
        BundlerError::SimulationFailed { .. } => "simulation_failed",
        BundlerError::InvalidPinnedArtifact { .. } => "invalid_pinned_artifact",
        BundlerError::AccountCodeNotAllowlisted { .. } => "account_code_not_allowlisted",
    }
}

#[derive(Debug)]
struct ReceiptWatcherBackoff {
    base: Duration,
    cap: Duration,
    next: Duration,
}

impl ReceiptWatcherBackoff {
    fn new(base: Duration, cap: Duration) -> Self {
        Self {
            base,
            cap,
            next: base,
        }
    }

    fn record_failure(&mut self) -> Duration {
        let delay = self.next;
        self.next = self.next.checked_mul(2).unwrap_or(self.cap).min(self.cap);
        delay
    }

    fn record_success(&mut self) {
        self.next = self.base;
    }
}

fn configured_entry_point(state: &DaemonState) -> Result<Address, String> {
    let value = state
        .config
        .bundler
        .entry_points
        .first()
        .ok_or_else(|| "no configured entrypoint".to_string())?;
    value
        .parse()
        .map_err(|err| format!("invalid configured entrypoint {value}: {err}"))
}

fn configured_submit_client(state: &DaemonState) -> Option<RawTransactionSubmitClient> {
    state
        .config
        .bundler
        .submit_rpcs
        .first()
        .map(|endpoint| RawTransactionSubmitClient::new(endpoint.clone()))
}

#[cfg(test)]
mod tests {
    use std::io::{self, Write};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::sync::Mutex;
    use std::time::Duration;

    use crate::state::{DaemonState, StateOverrideSmokeStatus};
    use tracing_subscriber::layer::SubscriberExt;
    use wallet_chain::{ChainError, MockChainAdapter};
    use wallet_node_store::{BundlerLifecycle, SubmittedTransaction, SubmittedTxStatus};

    #[tokio::test]
    async fn configured_entrypoint_parses_default_config() {
        let state = DaemonState::for_tests(Arc::new(MockChainAdapter::new()));
        assert_eq!(
            super::configured_entry_point(&state).unwrap(),
            wallet_bundler::ENTRY_POINT_V07
        );
    }

    #[tokio::test]
    async fn configured_submit_client_uses_first_submit_rpc() {
        let state = DaemonState::for_tests(Arc::new(MockChainAdapter::new()));
        assert!(super::configured_submit_client(&state).is_some());
    }

    #[tokio::test]
    async fn retire_drained_relayer_keys_marks_retiring_key_retired() {
        let state = DaemonState::for_tests(Arc::new(MockChainAdapter::new()));
        state
            .store
            .bundler_account_insert(1, "0x1111000000000000000000000000000000000000", "key-1")
            .await
            .unwrap();
        state
            .store
            .bundler_account_set_lifecycle(
                1,
                "0x1111000000000000000000000000000000000000",
                BundlerLifecycle::Retiring,
            )
            .await
            .unwrap();

        let retired = super::retire_drained_relayer_keys(&state).await.unwrap();

        assert_eq!(retired, 1);
        let accounts = state.store.bundler_account_list(1).await.unwrap();
        assert_eq!(accounts[0].lifecycle, BundlerLifecycle::Retired);
        let events = state
            .store
            .relayer_key_audit_list("default", 1, 10)
            .await
            .unwrap();
        assert!(events
            .iter()
            .any(|event| event.event_type == "relayer_key_retired"));
    }

    #[tokio::test]
    async fn retire_drained_relayer_keys_keeps_retiring_key_with_pending_tx() {
        let state = DaemonState::for_tests(Arc::new(MockChainAdapter::new()));
        let relayer = "0x1111000000000000000000000000000000000000";
        state
            .store
            .bundler_account_insert(1, relayer, "key-1")
            .await
            .unwrap();
        state
            .store
            .bundler_account_set_lifecycle(1, relayer, BundlerLifecycle::Retiring)
            .await
            .unwrap();
        state
            .store
            .submitted_tx_insert(SubmittedTransaction {
                tx_hash: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                    .to_string(),
                user_op_hash: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
                    .to_string(),
                chain_id: 1,
                bundler_address: relayer.to_string(),
                nonce: 1,
                raw_tx: "0x02".to_string(),
                max_fee_per_gas: "0x40".to_string(),
                max_priority_fee_per_gas: "0x05".to_string(),
                status: SubmittedTxStatus::Submitted,
                replacement_of: None,
                submitted_at_block: Some(100),
                created_at: 1,
                updated_at: 1,
            })
            .await
            .unwrap();

        let retired = super::retire_drained_relayer_keys(&state).await.unwrap();

        assert_eq!(retired, 0);
        let accounts = state.store.bundler_account_list(1).await.unwrap();
        assert_eq!(accounts[0].lifecycle, BundlerLifecycle::Retiring);
    }

    #[tokio::test]
    async fn state_override_smoke_retries_transient_failure_before_passing() {
        let state = Arc::new(DaemonState::for_tests(Arc::new(
            MockChainAdapter::with_synced(true),
        )));
        let (_shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);
        let attempts = Arc::new(AtomicUsize::new(0));
        let attempts_for_smoke = attempts.clone();

        super::run_state_override_smoke_with(
            state.clone(),
            shutdown_rx,
            Duration::from_millis(1),
            move || {
                let attempts = attempts_for_smoke.clone();
                async move {
                    if attempts.fetch_add(1, Ordering::SeqCst) == 0 {
                        Err(ChainError::RpcError("transient".to_string()))
                    } else {
                        Ok(())
                    }
                }
            },
        )
        .await;

        assert_eq!(attempts.load(Ordering::SeqCst), 2);
        assert_eq!(
            state.state_override_smoke_status(),
            StateOverrideSmokeStatus::Passed
        );
    }

    #[tokio::test]
    async fn state_override_smoke_records_failure_after_retry_budget() {
        let state = Arc::new(DaemonState::for_tests(Arc::new(
            MockChainAdapter::with_synced(true),
        )));
        let (_shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);
        let attempts = Arc::new(AtomicUsize::new(0));
        let attempts_for_smoke = attempts.clone();

        super::run_state_override_smoke_with(
            state.clone(),
            shutdown_rx,
            Duration::from_millis(1),
            move || {
                let attempts = attempts_for_smoke.clone();
                async move {
                    attempts.fetch_add(1, Ordering::SeqCst);
                    Err(ChainError::RpcError("persistent".to_string()))
                }
            },
        )
        .await;

        assert_eq!(
            attempts.load(Ordering::SeqCst),
            super::STATE_OVERRIDE_SMOKE_MAX_ATTEMPTS
        );
        assert_eq!(
            state.state_override_smoke_status(),
            StateOverrideSmokeStatus::Failed("rpc error: persistent".to_string())
        );
    }

    #[tokio::test]
    async fn state_override_smoke_shutdown_during_retry_keeps_status_pending() {
        let state = Arc::new(DaemonState::for_tests(Arc::new(
            MockChainAdapter::with_synced(true),
        )));
        let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);
        let attempts = Arc::new(AtomicUsize::new(0));
        let attempts_for_smoke = attempts.clone();

        let task = tokio::spawn(super::run_state_override_smoke_with(
            state.clone(),
            shutdown_rx,
            Duration::from_secs(60),
            move || {
                let attempts = attempts_for_smoke.clone();
                async move {
                    attempts.fetch_add(1, Ordering::SeqCst);
                    Err(ChainError::RpcError("transient".to_string()))
                }
            },
        ));

        while attempts.load(Ordering::SeqCst) == 0 {
            tokio::task::yield_now().await;
        }
        shutdown_tx.send(true).expect("send shutdown");
        tokio::time::timeout(Duration::from_secs(1), task)
            .await
            .expect("watcher exits")
            .expect("task joins");

        assert_eq!(attempts.load(Ordering::SeqCst), 1);
        assert_eq!(
            state.state_override_smoke_status(),
            StateOverrideSmokeStatus::Pending
        );
    }

    #[test]
    fn receipt_watcher_backoff_doubles_caps_and_resets() {
        let mut backoff =
            super::ReceiptWatcherBackoff::new(Duration::from_secs(6), Duration::from_secs(60));

        assert_eq!(backoff.record_failure(), Duration::from_secs(6));
        assert_eq!(backoff.record_failure(), Duration::from_secs(12));
        assert_eq!(backoff.record_failure(), Duration::from_secs(24));
        assert_eq!(backoff.record_failure(), Duration::from_secs(48));
        assert_eq!(backoff.record_failure(), Duration::from_secs(60));
        assert_eq!(backoff.record_failure(), Duration::from_secs(60));

        backoff.record_success();
        assert_eq!(backoff.record_failure(), Duration::from_secs(6));
    }

    #[test]
    fn receipt_watcher_observability_logs_stable_redacted_events() {
        let output = CapturedOutput::default();
        let subscriber = tracing_subscriber::registry().with(
            tracing_subscriber::fmt::layer()
                .json()
                .with_ansi(false)
                .with_writer(output.clone()),
        );
        let dispatch = tracing::Dispatch::new(subscriber);

        tracing::dispatcher::with_default(&dispatch, || {
            super::log_receipt_watcher_unsynced_skip();
            super::log_receipt_watcher_reconciled(3, true);
            super::log_receipt_watcher_failure(
                &wallet_bundler::BundlerError::ReplacementNotPossible {
                    reason: "receipt_lookup_failed",
                },
                Duration::from_secs(6),
            );
            super::log_receipt_watcher_failure(
                &wallet_bundler::BundlerError::RawTransactionSubmission {
                    reason: "provider body secret".to_string(),
                },
                Duration::from_secs(12),
            );
        });

        let output = output.as_string();
        assert!(output.contains("receipt_watcher_unsynced_skip"));
        assert!(output.contains("receipt_watcher_recovered"));
        assert!(output.contains("\"transitions\":3"));
        assert!(output.contains("receipt_watcher_pass_failed"));
        assert!(output.contains("receipt_lookup_failed"));
        assert!(output.contains("raw_transaction_submission_failed"));
        assert!(!output.contains("provider body secret"));
    }

    #[derive(Clone, Default)]
    struct CapturedOutput {
        bytes: Arc<Mutex<Vec<u8>>>,
    }

    impl CapturedOutput {
        fn as_string(&self) -> String {
            let bytes = self.bytes.lock().expect("captured log lock poisoned");
            String::from_utf8(bytes.clone()).expect("captured log output should be UTF-8")
        }
    }

    impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for CapturedOutput {
        type Writer = CapturedWriter;

        fn make_writer(&'a self) -> Self::Writer {
            CapturedWriter {
                bytes: self.bytes.clone(),
            }
        }
    }

    struct CapturedWriter {
        bytes: Arc<Mutex<Vec<u8>>>,
    }

    impl Write for CapturedWriter {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            self.bytes
                .lock()
                .expect("captured log lock poisoned")
                .extend_from_slice(buf);
            Ok(buf.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
}
