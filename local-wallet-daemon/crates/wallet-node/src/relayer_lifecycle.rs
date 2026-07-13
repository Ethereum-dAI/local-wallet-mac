use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
};

use tokio::sync::{Mutex as AsyncMutex, OwnedMutexGuard};

type RelayerLifecycleLockMap = BTreeMap<(String, u64), Arc<AsyncMutex<()>>>;

#[derive(Debug, Default)]
pub(crate) struct RelayerLifecycleLocks {
    locks: Mutex<RelayerLifecycleLockMap>,
}

pub(crate) struct RelayerLifecycleGuard {
    _lock: Arc<AsyncMutex<()>>,
    _guard: OwnedMutexGuard<()>,
}

impl RelayerLifecycleLocks {
    pub(crate) async fn acquire(&self, owner_scope: &str, chain_id: u64) -> RelayerLifecycleGuard {
        let key = (owner_scope.to_string(), chain_id);
        let lock = {
            let mut locks = self
                .locks
                .lock()
                .expect("relayer lifecycle lock map is not poisoned");
            locks
                .entry(key)
                .or_insert_with(|| Arc::new(AsyncMutex::new(())))
                .clone()
        };
        debug_assert!(
            self.lock_count() <= 16,
            "relayer lifecycle locks should stay bounded while owner scopes are fixed"
        );
        let guard = lock.clone().lock_owned().await;
        RelayerLifecycleGuard {
            _lock: lock,
            _guard: guard,
        }
    }

    fn lock_count(&self) -> usize {
        self.locks
            .lock()
            .expect("relayer lifecycle lock map is not poisoned")
            .len()
    }
}

#[cfg(test)]
mod tests {
    use std::{
        sync::{
            atomic::{AtomicUsize, Ordering},
            Arc,
        },
        time::Duration,
    };

    use super::RelayerLifecycleLocks;

    #[tokio::test]
    async fn serializes_same_owner_and_chain() {
        let locks = Arc::new(RelayerLifecycleLocks::default());
        let entered = Arc::new(AtomicUsize::new(0));

        let first_locks = locks.clone();
        let first_entered = entered.clone();
        let first = tokio::spawn(async move {
            let _guard = first_locks.acquire("default", 1).await;
            first_entered.store(1, Ordering::SeqCst);
            tokio::time::sleep(Duration::from_millis(50)).await;
            first_entered.store(2, Ordering::SeqCst);
        });

        while entered.load(Ordering::SeqCst) == 0 {
            tokio::task::yield_now().await;
        }

        let second_locks = locks.clone();
        let second_entered = entered.clone();
        let second = tokio::spawn(async move {
            let _guard = second_locks.acquire("default", 1).await;
            assert_eq!(second_entered.load(Ordering::SeqCst), 2);
        });

        first.await.expect("first lock task should finish");
        second.await.expect("second lock task should finish");
    }
}
