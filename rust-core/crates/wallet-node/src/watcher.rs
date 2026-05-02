use std::sync::Arc;
use std::time::{Duration, Instant};

use alloy_primitives::Address;
use tokio::sync::watch;
use tokio::task::JoinHandle;
use wallet_bundler::{
    RawTransactionReceiptFetcher, RawTransactionSubmitClient, RawTransactionTransport,
};

use crate::state::DaemonState;

const TENTATIVE_RECEIPT_AFTER: Duration = Duration::from_secs(60);

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
    mut shutdown_rx: watch::Receiver<bool>,
    interval: Duration,
) {
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
                match wallet_chain::run_smoke_test(state.chain.as_ref()).await {
                    Ok(()) => {
                        state.mark_state_override_smoke_passed();
                        tracing::info!("stateOverride smoke test passed");
                    }
                    Err(err) => {
                        state.mark_state_override_smoke_failed(err.to_string());
                        tracing::warn!(error = %err, "stateOverride smoke test failed");
                    }
                }
                return;
            }
        }
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

                let result = if state.chain.is_synced().await {
                    unsynced_since = None;
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
                    let since = *unsynced_since.get_or_insert_with(Instant::now);
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
                match result {
                    Ok(transitions) if transitions > 0 => {
                        error_backoff.record_success();
                        next_attempt_after = None;
                        tracing::info!(transitions, "receipt watcher reconciled transactions");
                    }
                    Ok(_) => {
                        error_backoff.record_success();
                        next_attempt_after = None;
                    }
                    Err(err) => {
                        let delay = error_backoff.record_failure();
                        next_attempt_after = Some(Instant::now() + delay);
                        tracing::warn!(
                            error = %err,
                            retry_after_ms = delay.as_millis(),
                            "receipt watcher pass failed"
                        );
                    }
                }
            }
        }
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
    use std::sync::Arc;
    use std::time::Duration;

    use crate::state::DaemonState;
    use wallet_chain::MockChainAdapter;

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
}
