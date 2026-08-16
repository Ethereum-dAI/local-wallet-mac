use thiserror::Error;
use wallet_node_store::{
    BundlerAccount, BundlerLifecycle, StoreError, StoreHandle, SubmittedTxStatus,
};

pub(crate) struct SuppliedBundlerKey<'a> {
    pub owner_scope: &'a str,
    pub chain_id: u64,
    pub key_ref: &'a str,
    pub address: &'a str,
}

#[derive(Debug)]
pub(crate) enum ReconciliationMutation {
    None,
    Inserted,
    ActivatedExisting,
    Rebound { previous: BundlerAccount },
}

#[derive(Debug)]
pub(crate) struct ReconciliationOutcome {
    pub current: BundlerAccount,
    pub mutation: ReconciliationMutation,
}

#[derive(Debug, Error)]
pub(crate) enum ReconciliationError {
    #[error("supplied bundler address is registered under a different key_ref")]
    AddressRegisteredUnderDifferentKeyRef,

    #[error("supplied bundler account is not active")]
    SuppliedAccountNotActive,

    #[error("active bundler account differs from supplied key")]
    ActiveAccountDiffers,

    #[error("supplied bundler key_ref resolves to a different address with live local work")]
    LiveLocalWork,

    #[error(transparent)]
    Store(#[from] StoreError),
}

pub(crate) async fn reconcile(
    store: &StoreHandle,
    supplied: SuppliedBundlerKey<'_>,
    desired_lifecycle: BundlerLifecycle,
) -> Result<ReconciliationOutcome, ReconciliationError> {
    let accounts = store
        .bundler_account_list_for_owner(supplied.owner_scope, supplied.chain_id)
        .await?;

    if let Some(address_match) = accounts
        .iter()
        .find(|account| account.address.eq_ignore_ascii_case(supplied.address))
    {
        if address_match.key_ref != supplied.key_ref {
            return Err(ReconciliationError::AddressRegisteredUnderDifferentKeyRef);
        }
        if matches!(
            address_match.lifecycle,
            BundlerLifecycle::Retired | BundlerLifecycle::Deleted
        ) {
            return Err(ReconciliationError::SuppliedAccountNotActive);
        }
        if address_match.lifecycle == BundlerLifecycle::Active
            || address_match.lifecycle == BundlerLifecycle::Retiring
            || address_match.lifecycle == desired_lifecycle
        {
            return Ok(ReconciliationOutcome {
                current: address_match.clone(),
                mutation: ReconciliationMutation::None,
            });
        }

        if address_match.lifecycle != BundlerLifecycle::PendingFunding
            || desired_lifecycle != BundlerLifecycle::Active
        {
            return Err(ReconciliationError::SuppliedAccountNotActive);
        }
        if active_account(&accounts).is_some() {
            return Err(ReconciliationError::ActiveAccountDiffers);
        }

        store
            .bundler_account_activate_pending_for_owner(
                supplied.owner_scope,
                supplied.chain_id,
                supplied.address,
            )
            .await?;
        return Ok(ReconciliationOutcome {
            current: supplied_account(supplied, desired_lifecycle),
            mutation: ReconciliationMutation::ActivatedExisting,
        });
    }

    if let Some(key_ref_match) = accounts
        .iter()
        .find(|account| account.key_ref == supplied.key_ref)
    {
        if key_ref_match.lifecycle != BundlerLifecycle::Active {
            return Err(ReconciliationError::SuppliedAccountNotActive);
        }
        return rebind_active(store, supplied, key_ref_match).await;
    }

    if active_account(&accounts).is_some() && desired_lifecycle == BundlerLifecycle::Active {
        return Err(ReconciliationError::ActiveAccountDiffers);
    }

    store
        .bundler_account_insert_for_owner(
            supplied.owner_scope,
            supplied.chain_id,
            supplied.address,
            supplied.key_ref,
            desired_lifecycle,
        )
        .await?;
    Ok(ReconciliationOutcome {
        current: supplied_account(supplied, desired_lifecycle),
        mutation: ReconciliationMutation::Inserted,
    })
}

pub(crate) async fn rollback_rebound(
    store: &StoreHandle,
    outcome: &ReconciliationOutcome,
) -> Result<bool, StoreError> {
    let ReconciliationMutation::Rebound { previous } = &outcome.mutation else {
        return Ok(false);
    };
    store
        .bundler_account_rollback_replacement_for_owner(
            &outcome.current.owner_scope,
            outcome.current.chain_id,
            &outcome.current.address,
            &outcome.current.key_ref,
            &previous.address,
            &previous.key_ref,
        )
        .await?;
    Ok(true)
}

async fn rebind_active(
    store: &StoreHandle,
    supplied: SuppliedBundlerKey<'_>,
    active: &BundlerAccount,
) -> Result<ReconciliationOutcome, ReconciliationError> {
    if has_live_local_work(store, active).await? {
        return Err(ReconciliationError::LiveLocalWork);
    }

    tracing::warn!(
        owner_scope = %supplied.owner_scope,
        chain_id = supplied.chain_id,
        key_ref = %supplied.key_ref,
        old_address = %active.address,
        new_address = %supplied.address,
        "retiring stale active bundler account metadata and adopting supplied key"
    );
    store
        .bundler_account_replace_active_for_owner(
            supplied.owner_scope,
            supplied.chain_id,
            &active.address,
            supplied.address,
            supplied.key_ref,
        )
        .await?;
    Ok(ReconciliationOutcome {
        current: supplied_account(supplied, BundlerLifecycle::Active),
        mutation: ReconciliationMutation::Rebound {
            previous: active.clone(),
        },
    })
}

async fn has_live_local_work(
    store: &StoreHandle,
    account: &BundlerAccount,
) -> Result<bool, StoreError> {
    let pending_nonces = store
        .nonces_list_pending(account.chain_id, &account.address)
        .await?;
    if !pending_nonces.is_empty() {
        return Ok(true);
    }

    let live_txs = store.submitted_txs_list_for_watcher().await?;
    Ok(live_txs.iter().any(|tx| {
        tx.chain_id == account.chain_id
            && tx.bundler_address.eq_ignore_ascii_case(&account.address)
            && matches!(
                tx.status,
                SubmittedTxStatus::Submitting | SubmittedTxStatus::Submitted
            )
    }))
}

fn active_account(accounts: &[BundlerAccount]) -> Option<&BundlerAccount> {
    accounts
        .iter()
        .find(|account| account.lifecycle == BundlerLifecycle::Active)
}

fn supplied_account(
    supplied: SuppliedBundlerKey<'_>,
    lifecycle: BundlerLifecycle,
) -> BundlerAccount {
    BundlerAccount {
        owner_scope: supplied.owner_scope.to_owned(),
        chain_id: supplied.chain_id,
        address: supplied.address.to_owned(),
        key_ref: supplied.key_ref.to_owned(),
        lifecycle,
        created_at: 0,
        activated_at: (lifecycle == BundlerLifecycle::Active).then_some(0),
        retired_at: None,
        deleted_at: None,
        last_used_at: None,
        last_exported_at: None,
        compromise_status: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wallet_node_store::{db, migrations, StoreActor};

    const OWNER: &str = "default";
    const CHAIN_ID: u64 = 11_155_111;
    const KEY_REF: &str = "bundler-eoa:default:11155111:1";
    const OLD_ADDRESS: &str = "0xa09d9ce68cb323ee2b2ba939084b13a8eeaa5bcc";
    const NEW_ADDRESS: &str = "0x122cbfd6b318e468625fa9f2264dc77d887b8393";

    fn migrated_store() -> StoreHandle {
        let mut conn = db::open_in_memory().expect("in-memory store should open");
        migrations::apply(&mut conn).expect("migrations should apply");
        StoreActor::start(conn)
    }

    fn supplied(address: &'static str, key_ref: &'static str) -> SuppliedBundlerKey<'static> {
        SuppliedBundlerKey {
            owner_scope: OWNER,
            chain_id: CHAIN_ID,
            key_ref,
            address,
        }
    }

    #[tokio::test]
    async fn supplied_bundler_key_registration_is_idempotent() {
        let store = migrated_store();
        store
            .bundler_account_insert_for_owner(
                OWNER,
                CHAIN_ID,
                OLD_ADDRESS,
                KEY_REF,
                BundlerLifecycle::Active,
            )
            .await
            .unwrap();

        let outcome = reconcile(
            &store,
            supplied(OLD_ADDRESS, KEY_REF),
            BundlerLifecycle::Active,
        )
        .await
        .unwrap();

        assert!(matches!(outcome.mutation, ReconciliationMutation::None));
        assert_eq!(outcome.current.key_ref, KEY_REF);
        store.shutdown_and_wait().await.unwrap();
    }

    #[tokio::test]
    async fn exact_retiring_key_is_accepted_without_lifecycle_mutation() {
        let store = migrated_store();
        store
            .bundler_account_insert_for_owner(
                OWNER,
                CHAIN_ID,
                OLD_ADDRESS,
                KEY_REF,
                BundlerLifecycle::Retiring,
            )
            .await
            .unwrap();
        store
            .bundler_account_insert_for_owner(
                OWNER,
                CHAIN_ID,
                NEW_ADDRESS,
                "bundler-eoa:default:11155111:2",
                BundlerLifecycle::Active,
            )
            .await
            .unwrap();

        let outcome = reconcile(
            &store,
            supplied(OLD_ADDRESS, KEY_REF),
            BundlerLifecycle::PendingFunding,
        )
        .await
        .unwrap();

        assert!(matches!(outcome.mutation, ReconciliationMutation::None));
        assert_eq!(outcome.current.lifecycle, BundlerLifecycle::Retiring);
        let accounts = store
            .bundler_account_list_for_owner(OWNER, CHAIN_ID)
            .await
            .unwrap();
        assert!(accounts.iter().any(|account| {
            account.address == OLD_ADDRESS
                && account.key_ref == KEY_REF
                && account.lifecycle == BundlerLifecycle::Retiring
        }));
        store.shutdown_and_wait().await.unwrap();
    }

    #[tokio::test]
    async fn exact_deleted_key_is_never_resurrected() {
        for desired in [BundlerLifecycle::Active, BundlerLifecycle::PendingFunding] {
            let store = migrated_store();
            store
                .bundler_account_insert_for_owner(
                    OWNER,
                    CHAIN_ID,
                    OLD_ADDRESS,
                    KEY_REF,
                    BundlerLifecycle::Deleted,
                )
                .await
                .unwrap();

            let error = reconcile(&store, supplied(OLD_ADDRESS, KEY_REF), desired)
                .await
                .unwrap_err();

            assert!(matches!(
                error,
                ReconciliationError::SuppliedAccountNotActive
            ));
            let accounts = store
                .bundler_account_list_for_owner(OWNER, CHAIN_ID)
                .await
                .unwrap();
            assert_eq!(accounts.len(), 1);
            assert_eq!(accounts[0].lifecycle, BundlerLifecycle::Deleted);
            store.shutdown_and_wait().await.unwrap();
        }
    }

    #[tokio::test]
    async fn exact_retired_key_is_never_resurrected() {
        for desired in [BundlerLifecycle::Active, BundlerLifecycle::PendingFunding] {
            let store = migrated_store();
            store
                .bundler_account_insert_for_owner(
                    OWNER,
                    CHAIN_ID,
                    OLD_ADDRESS,
                    KEY_REF,
                    BundlerLifecycle::Retired,
                )
                .await
                .unwrap();

            let error = reconcile(&store, supplied(OLD_ADDRESS, KEY_REF), desired)
                .await
                .unwrap_err();

            assert!(matches!(
                error,
                ReconciliationError::SuppliedAccountNotActive
            ));
            let accounts = store
                .bundler_account_list_for_owner(OWNER, CHAIN_ID)
                .await
                .unwrap();
            assert_eq!(accounts.len(), 1);
            assert_eq!(accounts[0].lifecycle, BundlerLifecycle::Retired);
            store.shutdown_and_wait().await.unwrap();
        }
    }

    #[tokio::test]
    async fn exact_pending_key_can_recover_to_active_when_no_active_exists() {
        let store = migrated_store();
        store
            .bundler_account_insert_for_owner(
                OWNER,
                CHAIN_ID,
                OLD_ADDRESS,
                KEY_REF,
                BundlerLifecycle::PendingFunding,
            )
            .await
            .unwrap();

        let outcome = reconcile(
            &store,
            supplied(OLD_ADDRESS, KEY_REF),
            BundlerLifecycle::Active,
        )
        .await
        .unwrap();

        assert!(matches!(
            outcome.mutation,
            ReconciliationMutation::ActivatedExisting
        ));
        let active = store
            .bundler_account_active_for_owner(OWNER, CHAIN_ID)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(active.address, OLD_ADDRESS);
        assert_eq!(active.key_ref, KEY_REF);
        store.shutdown_and_wait().await.unwrap();
    }

    #[tokio::test]
    async fn supplied_bundler_key_registration_rejects_address_under_different_key_ref() {
        let store = migrated_store();
        store
            .bundler_account_insert_for_owner(
                OWNER,
                CHAIN_ID,
                OLD_ADDRESS,
                KEY_REF,
                BundlerLifecycle::Active,
            )
            .await
            .unwrap();

        let error = reconcile(
            &store,
            supplied(OLD_ADDRESS, "bundler-eoa:default:11155111:2"),
            BundlerLifecycle::Active,
        )
        .await
        .unwrap_err();

        assert!(matches!(
            error,
            ReconciliationError::AddressRegisteredUnderDifferentKeyRef
        ));
        store.shutdown_and_wait().await.unwrap();
    }

    #[tokio::test]
    async fn supplied_bundler_key_registration_adopts_idle_key_ref_address_mismatch() {
        let store = migrated_store();
        store
            .bundler_account_insert_for_owner(
                OWNER,
                CHAIN_ID,
                OLD_ADDRESS,
                KEY_REF,
                BundlerLifecycle::Active,
            )
            .await
            .unwrap();

        let outcome = reconcile(
            &store,
            supplied(NEW_ADDRESS, KEY_REF),
            BundlerLifecycle::Active,
        )
        .await
        .unwrap();

        assert!(matches!(
            outcome.mutation,
            ReconciliationMutation::Rebound { .. }
        ));
        let active = store
            .bundler_account_active_for_owner(OWNER, CHAIN_ID)
            .await
            .unwrap()
            .unwrap();
        assert!(active.address.eq_ignore_ascii_case(NEW_ADDRESS));
        store.shutdown_and_wait().await.unwrap();
    }

    #[tokio::test]
    async fn supplied_bundler_key_registration_rejects_live_key_ref_address_mismatch() {
        let store = migrated_store();
        store
            .bundler_account_insert_for_owner(
                OWNER,
                CHAIN_ID,
                OLD_ADDRESS,
                KEY_REF,
                BundlerLifecycle::Active,
            )
            .await
            .unwrap();
        store
            .reserve_next_nonce(CHAIN_ID, OLD_ADDRESS, 0)
            .await
            .unwrap();

        let error = reconcile(
            &store,
            supplied(NEW_ADDRESS, KEY_REF),
            BundlerLifecycle::Active,
        )
        .await
        .unwrap_err();

        assert!(matches!(error, ReconciliationError::LiveLocalWork));
        let active = store
            .bundler_account_active_for_owner(OWNER, CHAIN_ID)
            .await
            .unwrap()
            .unwrap();
        assert!(active.address.eq_ignore_ascii_case(OLD_ADDRESS));
        store.shutdown_and_wait().await.unwrap();
    }

    #[tokio::test]
    async fn rolled_back_rebind_can_be_retried() {
        let store = migrated_store();
        store
            .bundler_account_insert_for_owner(
                OWNER,
                CHAIN_ID,
                OLD_ADDRESS,
                KEY_REF,
                BundlerLifecycle::Active,
            )
            .await
            .unwrap();
        let first = reconcile(
            &store,
            supplied(NEW_ADDRESS, KEY_REF),
            BundlerLifecycle::PendingFunding,
        )
        .await
        .unwrap();
        assert!(rollback_rebound(&store, &first).await.unwrap());
        let rolled_back_accounts = store
            .bundler_account_list_for_owner(OWNER, CHAIN_ID)
            .await
            .unwrap();
        assert_eq!(rolled_back_accounts.len(), 1);
        assert_eq!(rolled_back_accounts[0].address, OLD_ADDRESS);
        assert_eq!(rolled_back_accounts[0].lifecycle, BundlerLifecycle::Active);

        let retried = reconcile(
            &store,
            supplied(NEW_ADDRESS, KEY_REF),
            BundlerLifecycle::PendingFunding,
        )
        .await
        .unwrap();

        assert!(matches!(
            retried.mutation,
            ReconciliationMutation::Rebound { .. }
        ));
        let active = store
            .bundler_account_active_for_owner(OWNER, CHAIN_ID)
            .await
            .unwrap()
            .unwrap();
        assert!(active.address.eq_ignore_ascii_case(NEW_ADDRESS));
        store.shutdown_and_wait().await.unwrap();
    }
}
