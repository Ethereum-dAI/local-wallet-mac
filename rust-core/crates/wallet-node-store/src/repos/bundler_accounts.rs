use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{params, Connection};

use crate::{BundlerAccount, BundlerLifecycle, StoreError};

const TABLE: &str = "bundler_accounts";

pub(crate) fn bundler_account_insert(
    conn: &Connection,
    chain_id: u64,
    address: &str,
    key_ref: &str,
) -> Result<(), StoreError> {
    let created_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;

    conn.execute(
        "INSERT INTO bundler_accounts (chain_id, address, key_ref, lifecycle, created_at) VALUES (?, ?, ?, 'active', ?)",
        params![chain_id, address, key_ref, created_at],
    )?;
    Ok(())
}

pub(crate) fn bundler_account_active(
    conn: &Connection,
    chain_id: u64,
) -> Result<Option<BundlerAccount>, StoreError> {
    let accounts = query_accounts(
        conn,
        "SELECT chain_id, address, key_ref, lifecycle, created_at FROM bundler_accounts WHERE chain_id = ? AND lifecycle = 'active'",
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

pub(crate) fn bundler_account_set_lifecycle(
    conn: &Connection,
    chain_id: u64,
    address: &str,
    new_state: BundlerLifecycle,
) -> Result<(), StoreError> {
    conn.execute(
        "UPDATE bundler_accounts SET lifecycle = ? WHERE chain_id = ? AND address = ?",
        params![new_state.as_str(), chain_id, address],
    )?;
    Ok(())
}

pub(crate) fn bundler_account_list(
    conn: &Connection,
    chain_id: u64,
) -> Result<Vec<BundlerAccount>, StoreError> {
    query_accounts(
        conn,
        "SELECT chain_id, address, key_ref, lifecycle, created_at FROM bundler_accounts WHERE chain_id = ? ORDER BY created_at",
        chain_id,
    )
}

fn query_accounts(
    conn: &Connection,
    sql: &str,
    chain_id: u64,
) -> Result<Vec<BundlerAccount>, StoreError> {
    let mut stmt = conn.prepare(sql)?;
    let rows = stmt.query_map(params![chain_id], |row| {
        Ok((
            row.get::<_, u64>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, String>(3)?,
            row.get::<_, i64>(4)?,
        ))
    })?;

    let mut accounts = Vec::new();
    for row in rows {
        let (chain_id, address, key_ref, lifecycle, created_at) = row?;
        accounts.push(BundlerAccount {
            chain_id,
            address,
            key_ref,
            lifecycle: BundlerLifecycle::from_str(&lifecycle, TABLE)?,
            created_at,
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
        assert_eq!(account.address, "0xabc");
        assert_eq!(account.key_ref, "bundler-eoa:1");
        assert_eq!(account.lifecycle, BundlerLifecycle::Active);
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
        bundler_account_insert(&conn, 1, "0xbbb", "bundler-eoa:1b").unwrap();
        bundler_account_insert(&conn, 2, "0xccc", "bundler-eoa:2").unwrap();

        let accounts = bundler_account_list(&conn, 1).unwrap();

        assert_eq!(accounts.len(), 2);
        assert!(accounts.iter().all(|account| account.chain_id == 1));
        assert_eq!(accounts[0].address, "0xaaa");
        assert_eq!(accounts[1].address, "0xbbb");
    }

    #[test]
    fn multiple_active_rows_returns_data_integrity_error() {
        let conn = migrated_in_memory_conn();

        conn.execute(
            "INSERT INTO bundler_accounts (chain_id, address, key_ref, lifecycle, created_at) VALUES (?, ?, ?, 'active', ?)",
            params![1_u64, "0xaaa", "bundler-eoa:1a", 1_i64],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO bundler_accounts (chain_id, address, key_ref, lifecycle, created_at) VALUES (?, ?, ?, 'active', ?)",
            params![1_u64, "0xbbb", "bundler-eoa:1b", 2_i64],
        )
        .unwrap();

        match bundler_account_active(&conn, 1).unwrap_err() {
            StoreError::DataIntegrity { table, reason } => {
                assert_eq!(table, TABLE);
                assert_eq!(reason, "multiple active rows");
            }
            other => panic!("expected DataIntegrity, got {other:?}"),
        }
    }
}
