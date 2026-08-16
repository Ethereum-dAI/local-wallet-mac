#![allow(dead_code)]

use std::future::Future;
#[cfg(target_os = "macos")]
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::io::RawFd;
use std::time::Duration;

#[cfg(target_os = "macos")]
use nix::sys::event::{EventFilter, EventFlag, FilterFlag, KEvent, Kqueue};
use tokio::sync::watch;

#[derive(Debug, thiserror::Error)]
pub enum LifecycleError {
    #[error("kqueue setup: {0}")]
    KqueueSetup(nix::errno::Errno),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

pub struct LifecycleHandles {
    pub shutdown_tx: watch::Sender<bool>,
    pub shutdown_rx: watch::Receiver<bool>,
}

impl LifecycleHandles {
    pub fn new() -> Self {
        let (tx, rx) = watch::channel(false);
        Self {
            shutdown_tx: tx,
            shutdown_rx: rx,
        }
    }
}

/// Ensures early returns cannot strand the blocking alive-pipe watcher. The
/// guard lives for the daemon's full async entrypoint and broadcasts shutdown
/// when that entrypoint unwinds for any reason.
pub struct ShutdownOnDrop {
    shutdown_tx: watch::Sender<bool>,
}

impl ShutdownOnDrop {
    pub fn new(shutdown_tx: watch::Sender<bool>) -> Self {
        Self { shutdown_tx }
    }
}

impl Drop for ShutdownOnDrop {
    fn drop(&mut self) {
        let _ = self.shutdown_tx.send(true);
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum StartupStageResult<T> {
    Completed(T),
    ShutdownRequested,
}

/// Run an asynchronous startup stage only while the parent still owns the
/// daemon lifecycle. A shutdown that was already requested wins without
/// polling the stage, and a shutdown arriving later cancels the stage future.
pub async fn run_startup_stage<T>(
    shutdown_rx: &mut watch::Receiver<bool>,
    stage: impl Future<Output = T>,
) -> StartupStageResult<T> {
    if *shutdown_rx.borrow() {
        return StartupStageResult::ShutdownRequested;
    }

    tokio::select! {
        biased;
        _ = wait_for_shutdown(shutdown_rx) => StartupStageResult::ShutdownRequested,
        result = stage => StartupStageResult::Completed(result),
    }
}

async fn wait_for_shutdown(shutdown_rx: &mut watch::Receiver<bool>) {
    loop {
        if *shutdown_rx.borrow() {
            return;
        }
        if shutdown_rx.changed().await.is_err() {
            return;
        }
    }
}

pub fn install_signal_handlers(shutdown_tx: watch::Sender<bool>) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut sigterm =
            match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
                Ok(signal) => signal,
                Err(err) => {
                    tracing::warn!("failed to install SIGTERM handler: {err}");
                    return;
                }
            };
        let mut sigint =
            match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt()) {
                Ok(signal) => signal,
                Err(err) => {
                    tracing::warn!("failed to install SIGINT handler: {err}");
                    return;
                }
            };

        let signal_name = tokio::select! {
            _ = sigterm.recv() => "SIGTERM",
            _ = sigint.recv() => "SIGINT",
        };

        tracing::info!("received {signal_name}; requesting graceful shutdown");
        if let Err(err) = shutdown_tx.send(true) {
            tracing::warn!("failed to signal wallet-node shutdown from {signal_name}: {err}");
        }
    })
}

#[cfg(target_os = "macos")]
pub fn install_alive_pipe_watcher(
    alive_fd: RawFd,
    shutdown_tx: watch::Sender<bool>,
    shutdown_rx: watch::Receiver<bool>,
) -> Result<tokio::task::JoinHandle<()>, LifecycleError> {
    let alive_fd = unsafe { OwnedFd::from_raw_fd(alive_fd) };
    let kqueue = Kqueue::new().map_err(LifecycleError::KqueueSetup)?;
    let alive_ident = alive_fd.as_raw_fd() as libc::uintptr_t;
    let change = KEvent::new(
        alive_ident,
        EventFilter::EVFILT_READ,
        EventFlag::EV_ADD | EventFlag::EV_ONESHOT,
        FilterFlag::empty(),
        0,
        0,
    );

    kqueue
        .kevent(&[change], &mut [], None)
        .map_err(LifecycleError::KqueueSetup)?;

    Ok(tokio::task::spawn_blocking(move || {
        let _alive_fd = alive_fd;
        let mut events = [KEvent::new(
            0,
            EventFilter::EVFILT_READ,
            EventFlag::empty(),
            FilterFlag::empty(),
            0,
            0,
        )];
        let timeout = libc::timespec {
            tv_sec: 0,
            tv_nsec: 250_000_000,
        };

        loop {
            match kqueue.kevent(&[], &mut events, Some(timeout)) {
                Ok(0) => {
                    if *shutdown_rx.borrow() {
                        return;
                    }
                }
                Ok(_) => {
                    if events.iter().any(|event| {
                        event.ident() == alive_ident && event.flags().contains(EventFlag::EV_EOF)
                    }) {
                        let _ = shutdown_tx.send(true);
                        return;
                    }
                }
                Err(nix::errno::Errno::EINTR) => continue,
                Err(err) => {
                    tracing::warn!("alive pipe watcher failed: {err}");
                    return;
                }
            }
        }
    }))
}

#[cfg(not(target_os = "macos"))]
pub fn install_alive_pipe_watcher(
    alive_fd: RawFd,
    shutdown_tx: watch::Sender<bool>,
    shutdown_rx: watch::Receiver<bool>,
) -> Result<tokio::task::JoinHandle<()>, LifecycleError> {
    let _ = (alive_fd, shutdown_tx, shutdown_rx);
    Err(LifecycleError::KqueueSetup(nix::errno::Errno::ENOSYS))
}

pub fn install_ppid_backstop(
    shutdown_tx: watch::Sender<bool>,
    tick: Duration,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        loop {
            if shutdown_tx.is_closed() || *shutdown_tx.borrow() {
                return;
            }

            tokio::time::sleep(tick).await;

            if shutdown_tx.is_closed() || *shutdown_tx.borrow() {
                return;
            }

            // SAFETY: getppid has no preconditions and does not touch Rust-managed memory.
            if unsafe { libc::getppid() } == 1 {
                let _ = shutdown_tx.send(true);
                return;
            }
        }
    })
}

pub async fn deliver_ready_event_to_fd(
    ready_fd: RawFd,
    event: &crate::ready::ReadyEvent,
) -> std::io::Result<()> {
    let event = crate::ready::ReadyEvent {
        token: event.token.clone(),
        api_version: event.api_version,
        daemon_spawn_protocol: event.daemon_spawn_protocol,
        socket_path: event.socket_path.clone(),
        http_addr: event.http_addr.clone(),
    };

    tokio::task::spawn_blocking(move || crate::ready::write_to_fd(&event, ready_fd))
        .await
        .map_err(std::io::Error::other)?
}

#[cfg(test)]
mod tests {
    use super::{
        install_ppid_backstop, run_startup_stage, LifecycleHandles, ShutdownOnDrop,
        StartupStageResult,
    };
    use std::time::Duration;

    #[test]
    fn lifecycle_handles_creates_paired_tx_rx() {
        let handles = LifecycleHandles::new();

        assert!(!(*handles.shutdown_rx.borrow()));

        handles
            .shutdown_tx
            .send(true)
            .expect("send shutdown signal");

        assert!(*handles.shutdown_rx.borrow());
    }

    #[test]
    fn shutdown_guard_requests_shutdown_when_startup_returns_early() {
        let handles = LifecycleHandles::new();
        let shutdown_rx = handles.shutdown_rx;

        {
            let _guard = ShutdownOnDrop::new(handles.shutdown_tx);
            assert!(!(*shutdown_rx.borrow()));
        }

        assert!(*shutdown_rx.borrow());
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn alive_pipe_watcher_fires_on_eof() {
        use super::install_alive_pipe_watcher;
        use std::os::fd::IntoRawFd;

        let (read_fd, write_fd) = nix::unistd::pipe().expect("create alive pipe");
        let handles = LifecycleHandles::new();
        let LifecycleHandles {
            shutdown_tx,
            mut shutdown_rx,
        } = handles;

        let _watcher =
            install_alive_pipe_watcher(read_fd.into_raw_fd(), shutdown_tx, shutdown_rx.clone())
                .expect("install watcher");

        // Linux uses epoll; not exercised here, V1 is macOS-only.
        drop(write_fd);

        let changed = tokio::time::timeout(Duration::from_secs(1), shutdown_rx.changed()).await;
        assert!(matches!(changed, Ok(Ok(()))));
        assert!(*shutdown_rx.borrow());
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn alive_pipe_watcher_exits_on_external_shutdown() {
        use super::install_alive_pipe_watcher;
        use std::os::fd::IntoRawFd;

        let (read_fd, _write_fd) = nix::unistd::pipe().expect("create alive pipe");
        let handles = LifecycleHandles::new();
        let LifecycleHandles {
            shutdown_tx,
            shutdown_rx,
        } = handles;

        let watcher = install_alive_pipe_watcher(
            read_fd.into_raw_fd(),
            shutdown_tx.clone(),
            shutdown_rx.clone(),
        )
        .expect("install watcher");

        shutdown_tx.send(true).expect("send shutdown signal");

        let resolved = tokio::time::timeout(Duration::from_secs(1), watcher).await;
        assert!(matches!(resolved, Ok(Ok(()))));
    }

    #[tokio::test]
    async fn ppid_backstop_does_nothing_when_parent_alive() {
        let handles = LifecycleHandles::new();
        let LifecycleHandles {
            shutdown_tx,
            shutdown_rx,
        } = handles;

        let _backstop = install_ppid_backstop(shutdown_tx, Duration::from_millis(50));

        // Testing ppid==1 path requires forking; covered by integration tests in T12.
        tokio::time::sleep(Duration::from_millis(200)).await;

        assert!(!(*shutdown_rx.borrow()));
    }

    #[tokio::test]
    async fn startup_stage_completes_while_parent_is_alive() {
        let handles = LifecycleHandles::new();
        let mut shutdown_rx = handles.shutdown_rx;

        let result = run_startup_stage(&mut shutdown_rx, async { 42 }).await;

        assert_eq!(result, StartupStageResult::Completed(42));
    }

    #[tokio::test]
    async fn startup_stage_cancels_promptly_when_shutdown_arrives() {
        let handles = LifecycleHandles::new();
        let shutdown_tx = handles.shutdown_tx;
        let mut shutdown_rx = handles.shutdown_rx;
        let trigger = tokio::spawn(async move {
            tokio::task::yield_now().await;
            shutdown_tx.send(true).expect("request startup shutdown");
        });

        let result = tokio::time::timeout(
            Duration::from_secs(1),
            run_startup_stage(&mut shutdown_rx, std::future::pending::<()>()),
        )
        .await
        .expect("startup stage should observe shutdown promptly");

        trigger.await.expect("shutdown trigger should join");
        assert_eq!(result, StartupStageResult::ShutdownRequested);
    }

    #[tokio::test]
    async fn startup_stage_does_not_begin_after_shutdown() {
        let handles = LifecycleHandles::new();
        handles
            .shutdown_tx
            .send(true)
            .expect("request startup shutdown");
        let mut shutdown_rx = handles.shutdown_rx;

        let result = tokio::time::timeout(
            Duration::from_secs(1),
            run_startup_stage(&mut shutdown_rx, std::future::pending::<()>()),
        )
        .await
        .expect("already-requested shutdown should return immediately");

        assert_eq!(result, StartupStageResult::ShutdownRequested);
    }
}
