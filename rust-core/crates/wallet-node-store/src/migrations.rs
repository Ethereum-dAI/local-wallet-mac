use rusqlite::Connection;
use rusqlite_migration::{Migrations, M};

use crate::{schema::SCHEMA_V1, StoreError};

pub const HIGHEST_MIGRATION: u32 = 1;

pub fn apply(conn: &mut Connection) -> Result<(), StoreError> {
    let db_version = conn.pragma_query_value(None, "user_version", |row| row.get::<_, u32>(0))?;
    if db_version > HIGHEST_MIGRATION {
        return Err(StoreError::SchemaTooNew {
            db_version,
            binary_version: HIGHEST_MIGRATION,
        });
    }

    Migrations::new(vec![M::up(SCHEMA_V1)]).to_latest(conn)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn applies_v1_to_fresh_db() {
        let mut conn = Connection::open_in_memory().unwrap();

        apply(&mut conn).unwrap();

        let user_version: u32 = conn
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .unwrap();
        assert_eq!(user_version, 1);

        for table in [
            "daemon_meta",
            "bundler_accounts",
            "nonce_reservations",
            "user_operations",
            "submitted_transactions",
            "user_operation_receipts",
        ] {
            let exists: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
                    [table],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(exists, 1, "missing table {table}");
        }
    }

    #[test]
    fn refuses_to_open_newer_db() {
        let mut conn = Connection::open_in_memory().unwrap();
        conn.pragma_update(None, "user_version", 99_u32).unwrap();

        let err = apply(&mut conn).unwrap_err();

        match err {
            StoreError::SchemaTooNew {
                db_version,
                binary_version,
            } => {
                assert_eq!(db_version, 99);
                assert_eq!(binary_version, 1);
            }
            other => panic!("expected SchemaTooNew, got {other:?}"),
        }
    }

    #[test]
    fn reapply_is_idempotent() {
        let mut conn = Connection::open_in_memory().unwrap();

        apply(&mut conn).unwrap();
        apply(&mut conn).unwrap();

        let user_version: u32 = conn
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .unwrap();
        assert_eq!(user_version, 1);
    }
}
