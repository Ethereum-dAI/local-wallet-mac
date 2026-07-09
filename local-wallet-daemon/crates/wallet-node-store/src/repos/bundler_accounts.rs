use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{params, Connection};

#[cfg(test)]
use crate::DEFAULT_OWNER_SCOPE;
use crate::{BundlerAccount, BundlerLifecycle, StoreError};

const TABLE: &str = "bundler_accounts";

#[cfg(test)]
pub(crate) fn bundler_account_insert(
    conn: &Connection,
    chain_id: u64,
    address: &str,
    key_ref: &str,
) -> Result<(), StoreError> {
    bundler_account_insert_for_owner(
        conn,
        DEFAULT_OWNER_SCOPE,
        chain_id,
        address,
        key_ref,
        BundlerLifecycle::Active,
    )
}

pub(crate) fn bundler_account_insert_for_owner(
    conn: &Connection,
    owner_scope: &str,
    chain_id: u64,
    address: &str,
    key_ref: &str,
    lifecycle: BundlerLifecycle,
) -> Result<(), StoreError> {
    let created_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;

    conn.execute(
        "INSERT INTO bundler_accounts (owner_scope, chain_id, address, key_ref, lifecycle, created_at, activated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
        params![
            owner_scope,
            chain_id,
            address,
            key_ref,
            lifecycle.as_str(),
            created_at,
            if lifecycle == BundlerLifecycle::Active {
                Some(created_at)
            } else {
                None
            }
        ],
    )?;
    Ok(())
}

#[cfg(test)]
pub(crate) fn bundler_account_active(
    conn: &Connection,
    chain_id: u64,
) -> Result<Option<BundlerAccount>, StoreError> {
    bundler_account_active_for_owner(conn, DEFAULT_OWNER_SCOPE, chain_id)
}

pub(crate) fn bundler_account_active_for_owner(
    conn: &Connection,
    owner_scope: &str,
    chain_id: u64,
) -> Result<Option<BundlerAccount>, StoreError> {
    let accounts = query_accounts(
        conn,
        "SELECT owner_scope, chain_id, address, key_ref, lifecycle, created_at, activated_at, retired_at, deleted_at, last_used_at, last_exported_at, compromise_status FROM bundler_accounts WHERE owner_scope = ? AND chain_id = ? AND lifecycle = 'active'",
        owner_scope,
        chain_id,
    )?;

    match accounts.len() {
        0 => Ok(None),
        1 => Ok(accounts.into_iter().next()),
        _ => Err(StoreError::DataIntegrity {
            table: TABLE,
            reason: "multiple active rows",
        }),
    }
}

#[cfg(test)]
pub(crate) fn bundler_account_set_lifecycle(
    conn: &Connection,
    chain_id: u64,
    address: &str,
    new_state: BundlerLifecycle,
) -> Result<(), StoreError> {
    bundler_account_set_lifecycle_for_owner(conn, DEFAULT_OWNER_SCOPE, chain_id, address, new_state)
}

pub(crate) fn bundler_account_set_lifecycle_for_owner(
    conn: &Connection,
    owner_scope: &str,
    chain_id: u64,
    address: &str,
    new_state: BundlerLifecycle,
) -> Result<(), StoreError> {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    conn.execute(
        "UPDATE bundler_accounts SET lifecycle = ?, activated_at = CASE WHEN ? = 'active' THEN COALESCE(activated_at, ?) ELSE activated_at END, retired_at = CASE WHEN ? = 'retired' THEN COALESCE(retired_at, ?) ELSE retired_at END, deleted_at = CASE WHEN ? = 'deleted' THEN COALESCE(deleted_at, ?) ELSE deleted_at END WHERE owner_scope = ? AND chain_id = ? AND address = ?",
        params![
            new_state.as_str(),
            new_state.as_str(),
            now,
            new_state.as_str(),
            now,
            new_state.as_str(),
            now,
            owner_scope,
            chain_id,
            address
        ],
    )?;
    Ok(())
}

#[cfg(test)]
pub(crate) fn bundler_account_list(
    conn: &Connection,
    chain_id: u64,
) -> Result<Vec<BundlerAccount>, StoreError> {
    bundler_account_list_for_owner(conn, DEFAULT_OWNER_SCOPE, chain_id)
}

pub(crate) fn bundler_account_list_for_owner(
    conn: &Connection,
    owner_scope: &str,
    chain_id: u64,
) -> Result<Vec<BundlerAccount>, StoreError> {
    query_accounts(
        conn,
        "SELECT owner_scope, chain_id, address, key_ref, lifecycle, created_at, activated_at, retired_at, deleted_at, last_used_at, last_exported_at, compromise_status FROM bundler_accounts WHERE owner_scope = ? AND chain_id = ? ORDER BY created_at",
        owner_scope,
        chain_id,
    )
}

pub(crate) fn bundler_account_pending_funding(
    conn: &Connection,
    owner_scope: &str,
    chain_id: u64,
) -> Result<Option<BundlerAccount>, StoreError> {
    let accounts = query_accounts(
        conn,
        "SELECT owner_scope, chain_id, address, key_ref, lifecycle, created_at, activated_at, retired_at, deleted_at, last_used_at, last_exported_at, compromise_status FROM bundler_accounts WHERE owner_scope = ? AND chain_id = ? AND lifecycle = 'pending_funding'",
        owner_scope,
        chain_id,
    )?;

    match accounts.len() {
        0 => Ok(None),
        1 => Ok(accounts.into_iter().next()),
        _ => Err(StoreError::DataIntegrity {
            table: TABLE,
            reason: "multiple pending_funding rows",
        }),
    }
}

pub(crate) fn bundler_account_activate_pending(
    conn: &mut Connection,
    owner_scope: &str,
    chain_id: u64,
    pending_address: &str,
) -> Result<(), StoreError> {
    let tx = conn.transaction()?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    tx.execute(
        "UPDATE bundler_accounts SET lifecycle = 'retiring' WHERE owner_scope = ? AND chain_id = ? AND lifecycle = 'active'",
        params![owner_scope, chain_id],
    )?;
    let updated = tx.execute(
        "UPDATE bundler_accounts SET lifecycle = 'active', activated_at = COALESCE(activated_at, ?) WHERE owner_scope = ? AND chain_id = ? AND address = ? AND lifecycle = 'pending_funding'",
        params![now, owner_scope, chain_id, pending_address],
    )?;
    if updated != 1 {
        return Err(StoreError::DataIntegrity {
            table: TABLE,
            reason: "pending_funding row not found for activation",
        });
    }
    tx.commit()?;
    Ok(())
}

pub(crate) fn bundler_account_replace_active_for_owner(
    conn: &mut Connection,
    owner_scope: &str,
    chain_id: u64,
    old_address: &str,
    new_address: &str,
    new_key_ref: &str,
) -> Result<(), StoreError> {
    let tx = conn.transaction()?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;

    let retired = tx.execute(
        "UPDATE bundler_accounts
            SET lifecycle = 'retired',
                retired_at = COALESCE(retired_at, ?),
                deleted_at = NULL
          WHERE owner_scope = ?
            AND chain_id = ?
            AND address = ?
            AND lifecycle = 'active'",
        params![now, owner_scope, chain_id, old_address],
    )?;
    if retired != 1 {
        return Err(StoreError::DataIntegrity {
            table: TABLE,
            reason: "active row not found for replacement",
        });
    }

    let activated = tx.execute(
        "INSERT INTO bundler_accounts (
             owner_scope, chain_id, address, key_ref, lifecycle, created_at, activated_at
         )
         VALUES (?, ?, ?, ?, 'active', ?, ?)
         ON CONFLICT(owner_scope, chain_id, address) DO UPDATE SET
             key_ref = excluded.key_ref,
             lifecycle = 'active',
             activated_at = COALESCE(bundler_accounts.activated_at, excluded.activated_at),
             retired_at = NULL,
             deleted_at = NULL
         WHERE bundler_accounts.key_ref = excluded.key_ref",
        params![owner_scope, chain_id, new_address, new_key_ref, now, now],
    )?;
    if activated != 1 {
        return Err(StoreError::DataIntegrity {
            table: TABLE,
            reason: "replacement row did not match supplied key_ref",
        });
    }

    tx.commit()?;
    Ok(())
}

pub(crate) fn bundler_account_mark_used(
    conn: &Connection,
    owner_scope: &str,
    chain_id: u64,
    address: &str,
) -> Result<(), StoreError> {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    conn.execute(
        "UPDATE bundler_accounts SET last_used_at = ? WHERE owner_scope = ? AND chain_id = ? AND address = ?",
        params![now, owner_scope, chain_id, address],
    )?;
    Ok(())
}

fn query_accounts(
    conn: &Connection,
    sql: &str,
    owner_scope: &str,
    chain_id: u64,
) -> Result<Vec<BundlerAccount>, StoreError> {
    let mut stmt = conn.prepare(sql)?;
    let rows = stmt.query_map(params![owner_scope, chain_id], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, u64>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, String>(3)?,
            row.get::<_, String>(4)?,
            row.get::<_, i64>(5)?,
            row.get::<_, Option<i64>>(6)?,
            row.get::<_, Option<i64>>(7)?,
            row.get::<_, Option<i64>>(8)?,
            row.get::<_, Option<i64>>(9)?,
            row.get::<_, Option<i64>>(10)?,
            row.get::<_, Option<String>>(11)?,
        ))
    })?;

    let mut accounts = Vec::new();
    for row in rows {
        let (
            owner_scope,
            chain_id,
            address,
            key_ref,
            lifecycle,
            created_at,
            activated_at,
            retired_at,
            deleted_at,
            last_used_at,
            last_exported_at,
            compromise_status,
        ) = row?;
        accounts.push(BundlerAccount {
            owner_scope,
            chain_id,
            address,
            key_ref,
            lifecycle: BundlerLifecycle::from_str(&lifecycle, TABLE)?,
            created_at,
            activated_at,
            retired_at,
            deleted_at,
            last_used_at,
            last_exported_at,
            compromise_status,
        });
    }

    Ok(accounts)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{db, migrations};

    fn migrated_in_memory_conn() -> rusqlite::Connection {
        let mut conn = db::open_in_memory().unwrap();
        migrations::apply(&mut conn).unwrap();
        conn
    }

    #[test]
    fn insert_then_active_returns_some() {
        let conn = migrated_in_memory_conn();

        bundler_account_insert(&conn, 1, "0xabc", "bundler-eoa:1").unwrap();
        let account = bundler_account_active(&conn, 1).unwrap().unwrap();

        assert_eq!(account.chain_id, 1);
        assert_eq!(account.owner_scope, DEFAULT_OWNER_SCOPE);
        assert_eq!(account.address, "0xabc");
        assert_eq!(account.key_ref, "bundler-eoa:1");
        assert_eq!(account.lifecycle, BundlerLifecycle::Active);
        assert!(account.activated_at.is_some());
    }

    #[test]
    fn active_returns_none_when_no_rows() {
        let conn = migrated_in_memory_conn();

        assert!(bundler_account_active(&conn, 1).unwrap().is_none());
    }

    #[test]
    fn set_lifecycle_transitions_active_to_retiring() {
        let conn = migrated_in_memory_conn();

        bundler_account_insert(&conn, 1, "0xabc", "bundler-eoa:1").unwrap();
        bundler_account_set_lifecycle(&conn, 1, "0xabc", BundlerLifecycle::Retiring).unwrap();
        let accounts = bundler_account_list(&conn, 1).unwrap();

        assert_eq!(accounts.len(), 1);
        assert_eq!(accounts[0].lifecycle, BundlerLifecycle::Retiring);
    }

    #[test]
    fn list_returns_all_in_chain_id_filtered() {
        let conn = migrated_in_memory_conn();

        bundler_account_insert(&conn, 1, "0xaaa", "bundler-eoa:1a").unwrap();
        bundler_account_insert_for_owner(
            &conn,
            DEFAULT_OWNER_SCOPE,
            1,
            "0xbbb",
            "bundler-eoa:1b",
            BundlerLifecycle::PendingFunding,
        )
        .unwrap();
        bundler_account_insert(&conn, 2, "0xccc", "bundler-eoa:2").unwrap();

        let accounts = bundler_account_list(&conn, 1).unwrap();

        assert_eq!(accounts.len(), 2);
        assert!(accounts.iter().all(|account| account.chain_id == 1));
        assert_eq!(accounts[0].address, "0xaaa");
        assert_eq!(accounts[1].address, "0xbbb");
    }

    #[test]
    fn duplicate_active_rows_are_rejected_by_schema() {
        let conn = migrated_in_memory_conn();

        conn.execute(
            "INSERT INTO bundler_accounts (owner_scope, chain_id, address, key_ref, lifecycle, created_at) VALUES (?, ?, ?, ?, 'active', ?)",
            params![DEFAULT_OWNER_SCOPE, 1_u64, "0xaaa", "bundler-eoa:1a", 1_i64],
        )
        .unwrap();

        let duplicate = conn.execute(
            "INSERT INTO bundler_accounts (owner_scope, chain_id, address, key_ref, lifecycle, created_at) VALUES (?, ?, ?, ?, 'active', ?)",
            params![DEFAULT_OWNER_SCOPE, 1_u64, "0xbbb", "bundler-eoa:1b", 2_i64],
        );
        assert!(duplicate.is_err());
    }

    #[test]
    fn same_address_can_exist_under_different_owner_scopes() {
        let conn = migrated_in_memory_conn();

        bundler_account_insert_for_owner(
            &conn,
            DEFAULT_OWNER_SCOPE,
            1,
            "0xabc",
            "bundler-eoa:default",
            BundlerLifecycle::Active,
        )
        .unwrap();
        bundler_account_insert_for_owner(
            &conn,
            "tenant-b",
            1,
            "0xabc",
            "bundler-eoa:tenant-b",
            BundlerLifecycle::Active,
        )
        .unwrap();

        let default_active = bundler_account_active_for_owner(&conn, DEFAULT_OWNER_SCOPE, 1)
            .unwrap()
            .unwrap();
        let tenant_active = bundler_account_active_for_owner(&conn, "tenant-b", 1)
            .unwrap()
            .unwrap();

        assert_eq!(default_active.address, "0xabc");
        assert_eq!(tenant_active.address, "0xabc");
        assert_ne!(default_active.owner_scope, tenant_active.owner_scope);
    }

    #[test]
    fn activate_pending_retires_previous_active_atomically() {
        let mut conn = migrated_in_memory_conn();
        bundler_account_insert(&conn, 1, "0xaaa", "bundler-eoa:1a").unwrap();
        bundler_account_insert_for_owner(
            &conn,
            DEFAULT_OWNER_SCOPE,
            1,
            "0xbbb",
            "bundler-eoa:1b",
            BundlerLifecycle::PendingFunding,
        )
        .unwrap();

        bundler_account_activate_pending(&mut conn, DEFAULT_OWNER_SCOPE, 1, "0xbbb").unwrap();

        let active = bundler_account_active(&conn, 1).unwrap().unwrap();
        assert_eq!(active.address, "0xbbb");
        let accounts = bundler_account_list(&conn, 1).unwrap();
        assert!(accounts
            .iter()
            .any(|account| account.address == "0xaaa"
                && account.lifecycle == BundlerLifecycle::Retiring));
    }

    #[test]
    fn replace_active_retires_old_and_activates_supplied_key() {
        let mut conn = migrated_in_memory_conn();
        bundler_account_insert(&conn, 1, "0xaaa", "bundler-eoa:1").unwrap();

        bundler_account_replace_active_for_owner(
            &mut conn,
            DEFAULT_OWNER_SCOPE,
            1,
            "0xaaa",
            "0xbbb",
            "bundler-eoa:1",
        )
        .unwrap();

        let active = bundler_account_active(&conn, 1).unwrap().unwrap();
        assert_eq!(active.address, "0xbbb");
        assert_eq!(active.key_ref, "bundler-eoa:1");
        let accounts = bundler_account_list(&conn, 1).unwrap();
        assert!(accounts
            .iter()
            .any(|account| account.address == "0xaaa"
                && account.lifecycle == BundlerLifecycle::Retired));
    }

    #[test]
    fn replace_active_rolls_back_when_existing_replacement_key_ref_differs() {
        let mut conn = migrated_in_memory_conn();
        bundler_account_insert(&conn, 1, "0xaaa", "bundler-eoa:1").unwrap();
        bundler_account_insert_for_owner(
            &conn,
            DEFAULT_OWNER_SCOPE,
            1,
            "0xbbb",
            "bundler-eoa:other",
            BundlerLifecycle::Retired,
        )
        .unwrap();

        let err = bundler_account_replace_active_for_owner(
            &mut conn,
            DEFAULT_OWNER_SCOPE,
            1,
            "0xaaa",
            "0xbbb",
            "bundler-eoa:1",
        )
        .unwrap_err();
        assert!(matches!(
            err,
            StoreError::DataIntegrity {
                table: "bundler_accounts",
                reason: "replacement row did not match supplied key_ref"
            }
        ));

        let active = bundler_account_active(&conn, 1).unwrap().unwrap();
        assert_eq!(active.address, "0xaaa");
    }
}
