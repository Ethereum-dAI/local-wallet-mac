use rusqlite::Connection;
use rusqlite_migration::{Migrations, M};

use crate::{
    schema::{SCHEMA_V1, SCHEMA_V2, SCHEMA_V3, SCHEMA_V4, SCHEMA_V5, SCHEMA_V6, SCHEMA_V7},
    StoreError,
};

pub const HIGHEST_MIGRATION: u32 = 7;

pub fn apply(conn: &mut Connection) -> Result<(), StoreError> {
    let db_version = conn.pragma_query_value(None, "user_version", |row| row.get::<_, u32>(0))?;
    if db_version > HIGHEST_MIGRATION {
        return Err(StoreError::SchemaTooNew {
            db_version,
            binary_version: HIGHEST_MIGRATION,
        });
    }

    Migrations::new(vec![
        M::up(SCHEMA_V1),
        M::up(SCHEMA_V2),
        M::up(SCHEMA_V3),
        M::up(SCHEMA_V4),
        M::up(SCHEMA_V5),
        M::up(SCHEMA_V6),
        M::up(SCHEMA_V7),
    ])
    .to_latest(conn)?;
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
        assert_eq!(user_version, HIGHEST_MIGRATION);

        for table in [
            "daemon_meta",
            "bundler_accounts",
            "nonce_reservations",
            "user_operations",
            "submitted_transactions",
            "user_operation_receipts",
            "operation_diagnostics",
            "audit_runs",
            "audit_findings",
            "relayer_key_audit_events",
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
                assert_eq!(binary_version, HIGHEST_MIGRATION);
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
        assert_eq!(user_version, HIGHEST_MIGRATION);
    }

    #[test]
    fn v7_adds_recovery_attempts_column() {
        let mut conn = Connection::open_in_memory().unwrap();

        apply(&mut conn).unwrap();

        let exists: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('submitted_transactions') WHERE name = 'recovery_attempts'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        let user_version: u32 = conn
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .unwrap();
        assert_eq!(exists, 1);
        assert_eq!(user_version, HIGHEST_MIGRATION);
    }

    #[test]
    fn migrates_v1_database_to_v2_preserving_rows() {
        let mut conn = Connection::open_in_memory().unwrap();
        Migrations::new(vec![M::up(SCHEMA_V1)])
            .to_latest(&mut conn)
            .unwrap();
        conn.execute(
            "INSERT INTO user_operations (user_op_hash, chain_id, entry_point, sender, nonce, user_op_json, status, created_at, updated_at) VALUES ('0xop', 1, '0xentry', '0xsender', '0x1', '{}', 'submitted', 1, 1)",
            [],
        )
        .unwrap();

        apply(&mut conn).unwrap();

        let user_version: u32 = conn
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .unwrap();
        let op_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM user_operations", [], |row| row.get(0))
            .unwrap();
        let diagnostics_exists: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'operation_diagnostics'",
                [],
                |row| row.get(0),
            )
            .unwrap();

        assert_eq!(user_version, HIGHEST_MIGRATION);
        assert_eq!(op_count, 1);
        assert_eq!(diagnostics_exists, 1);
    }

    #[test]
    fn migrates_v2_database_to_v3_preserving_rows() {
        let mut conn = Connection::open_in_memory().unwrap();
        Migrations::new(vec![M::up(SCHEMA_V1), M::up(SCHEMA_V2)])
            .to_latest(&mut conn)
            .unwrap();
        conn.execute(
            "INSERT INTO operation_diagnostics (subject_type, subject_id, last_error, last_error_at) VALUES ('user_operation', '0xop', 'failed', 1)",
            [],
        )
        .unwrap();

        apply(&mut conn).unwrap();

        let user_version: u32 = conn
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .unwrap();
        let diagnostic_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM operation_diagnostics", [], |row| {
                row.get(0)
            })
            .unwrap();
        let audit_runs_exists: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'audit_runs'",
                [],
                |row| row.get(0),
            )
            .unwrap();

        assert_eq!(user_version, HIGHEST_MIGRATION);
        assert_eq!(diagnostic_count, 1);
        assert_eq!(audit_runs_exists, 1);
    }

    #[test]
    fn migrates_v3_database_to_v4_backfills_owner_scope_and_invariant() {
        let mut conn = Connection::open_in_memory().unwrap();
        Migrations::new(vec![M::up(SCHEMA_V1), M::up(SCHEMA_V2), M::up(SCHEMA_V3)])
            .to_latest(&mut conn)
            .unwrap();
        conn.execute(
            "INSERT INTO bundler_accounts (chain_id, address, key_ref, lifecycle, created_at) VALUES (1, '0xabc', 'bundler-eoa:1', 'active', 1)",
            [],
        )
        .unwrap();

        apply(&mut conn).unwrap();

        let owner_scope: String = conn
            .query_row(
                "SELECT owner_scope FROM bundler_accounts WHERE address = '0xabc'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(owner_scope, "default");
        let duplicate = conn.execute(
            "INSERT INTO bundler_accounts (chain_id, address, key_ref, lifecycle, created_at, owner_scope) VALUES (1, '0xdef', 'bundler-eoa:2', 'active', 2, 'default')",
            [],
        );
        assert!(duplicate.is_err());
    }

    #[test]
    fn migrates_v4_database_to_v5_preserving_rows_and_owner_scoped_primary_key() {
        let mut conn = Connection::open_in_memory().unwrap();
        Migrations::new(vec![
            M::up(SCHEMA_V1),
            M::up(SCHEMA_V2),
            M::up(SCHEMA_V3),
            M::up(SCHEMA_V4),
        ])
        .to_latest(&mut conn)
        .unwrap();
        conn.execute(
            "INSERT INTO bundler_accounts (owner_scope, chain_id, address, key_ref, lifecycle, created_at) VALUES ('default', 1, '0xabc', 'bundler-eoa:1', 'active', 1)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO nonce_reservations (chain_id, bundler_address, nonce, status, created_at, updated_at) VALUES (1, '0xabc', 0, 'reserved', 1, 1)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO user_operations (user_op_hash, chain_id, entry_point, sender, nonce, user_op_json, status, created_at, updated_at) VALUES ('0xop', 1, '0xentry', '0xsender', '0x1', '{}', 'submitted', 1, 1)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO submitted_transactions (tx_hash, user_op_hash, chain_id, bundler_address, nonce, raw_tx, max_fee_per_gas, max_priority_fee_per_gas, status, created_at, updated_at) VALUES ('0xtx', '0xop', 1, '0xabc', 0, '0x02', '0x1', '0x1', 'submitted', 1, 1)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO user_operation_receipts (user_op_hash, tx_hash, success, receipt_json, tentative, created_at) VALUES ('0xop', '0xtx', 1, '{}', 0, 1)",
            [],
        )
        .unwrap();

        apply(&mut conn).unwrap();

        let user_version: u32 = conn
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .unwrap();
        assert_eq!(user_version, HIGHEST_MIGRATION);
        let account_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM bundler_accounts", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(account_count, 1);

        conn.execute(
            "INSERT INTO bundler_accounts (owner_scope, chain_id, address, key_ref, lifecycle, created_at) VALUES ('tenant-b', 1, '0xabc', 'bundler-eoa:1b', 'active', 2)",
            [],
        )
        .unwrap();
        let duplicate_same_owner = conn.execute(
            "INSERT INTO bundler_accounts (owner_scope, chain_id, address, key_ref, lifecycle, created_at) VALUES ('default', 1, '0xabc', 'bundler-eoa:dup', 'retired', 3)",
            [],
        );
        assert!(duplicate_same_owner.is_err());
    }

    #[test]
    fn migrates_v4_database_to_v5_quarantines_non_canonical_lifecycle() {
        let mut conn = Connection::open_in_memory().unwrap();
        Migrations::new(vec![
            M::up(SCHEMA_V1),
            M::up(SCHEMA_V2),
            M::up(SCHEMA_V3),
            M::up(SCHEMA_V4),
        ])
        .to_latest(&mut conn)
        .unwrap();
        conn.execute(
            "INSERT INTO bundler_accounts (owner_scope, chain_id, address, key_ref, lifecycle, created_at) VALUES ('default', 1, '0xabc', 'bundler-eoa:1', 'legacy_weird', 1)",
            [],
        )
        .unwrap();

        apply(&mut conn).unwrap();

        let account_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM bundler_accounts", [], |row| {
                row.get(0)
            })
            .unwrap();
        let quarantine: (String, String) = conn
            .query_row(
                "SELECT column_name, original_value FROM bundler_accounts_v4_quarantine WHERE address = '0xabc'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();

        assert_eq!(account_count, 0);
        assert_eq!(
            quarantine,
            ("lifecycle".to_string(), "legacy_weird".to_string())
        );
    }

    #[test]
    fn migrates_v4_database_to_v5_coerces_retiring_lifecycle_to_deleted() {
        let mut conn = Connection::open_in_memory().unwrap();
        Migrations::new(vec![
            M::up(SCHEMA_V1),
            M::up(SCHEMA_V2),
            M::up(SCHEMA_V3),
            M::up(SCHEMA_V4),
        ])
        .to_latest(&mut conn)
        .unwrap();
        conn.execute(
            "INSERT INTO bundler_accounts (owner_scope, chain_id, address, key_ref, lifecycle, created_at) VALUES ('default', 1, '0xabc', 'bundler-eoa:1', 'retiring', 1)",
            [],
        )
        .unwrap();

        apply(&mut conn).unwrap();

        let lifecycle: String = conn
            .query_row(
                "SELECT lifecycle FROM bundler_accounts WHERE address = '0xabc'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        let account_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM bundler_accounts", [], |row| {
                row.get(0)
            })
            .unwrap();
        let quarantine_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM bundler_accounts_v4_quarantine",
                [],
                |row| row.get(0),
            )
            .unwrap();

        assert_eq!(lifecycle, "deleted");
        assert_eq!(account_count, 1);
        assert_eq!(quarantine_count, 0);
    }

    #[test]
    fn migrates_v4_database_to_v5_coerces_retired_lifecycle_to_deleted() {
        let mut conn = Connection::open_in_memory().unwrap();
        Migrations::new(vec![
            M::up(SCHEMA_V1),
            M::up(SCHEMA_V2),
            M::up(SCHEMA_V3),
            M::up(SCHEMA_V4),
        ])
        .to_latest(&mut conn)
        .unwrap();
        conn.execute(
            "INSERT INTO bundler_accounts (owner_scope, chain_id, address, key_ref, lifecycle, created_at) VALUES ('default', 1, '0xabc', 'bundler-eoa:1', 'retired', 1)",
            [],
        )
        .unwrap();

        apply(&mut conn).unwrap();

        let lifecycle: String = conn
            .query_row(
                "SELECT lifecycle FROM bundler_accounts WHERE address = '0xabc'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        let account_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM bundler_accounts", [], |row| {
                row.get(0)
            })
            .unwrap();
        let quarantine_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM bundler_accounts_v4_quarantine",
                [],
                |row| row.get(0),
            )
            .unwrap();

        assert_eq!(lifecycle, "deleted");
        assert_eq!(account_count, 1);
        assert_eq!(quarantine_count, 0);
    }

    #[test]
    fn v5_constraints_reject_invalid_status_and_boolean_values() {
        let mut conn = Connection::open_in_memory().unwrap();
        apply(&mut conn).unwrap();

        assert!(conn
            .execute(
                "INSERT INTO bundler_accounts (owner_scope, chain_id, address, key_ref, lifecycle, created_at) VALUES ('default', 1, '0xabc', 'key', 'unknown', 1)",
                [],
            )
            .is_err());
        assert!(conn
            .execute(
                "INSERT INTO nonce_reservations (chain_id, bundler_address, nonce, status, created_at, updated_at) VALUES (1, '0xabc', 0, 'unknown', 1, 1)",
                [],
            )
            .is_err());
        assert!(conn
            .execute(
                "INSERT INTO user_operations (user_op_hash, chain_id, entry_point, sender, nonce, user_op_json, status, created_at, updated_at) VALUES ('0xop', 1, '0xentry', '0xsender', '0x1', '{}', 'unknown', 1, 1)",
                [],
            )
            .is_err());
        assert!(conn
            .execute(
                "INSERT INTO submitted_transactions (tx_hash, user_op_hash, chain_id, bundler_address, nonce, raw_tx, max_fee_per_gas, max_priority_fee_per_gas, status, created_at, updated_at) VALUES ('0xtx', '0xop', 1, '0xabc', 0, '0x02', '0x1', '0x1', 'unknown', 1, 1)",
                [],
            )
            .is_err());
        assert!(conn
            .execute(
                "INSERT INTO user_operation_receipts (user_op_hash, tx_hash, success, receipt_json, tentative, created_at) VALUES ('0xop', '0xtx', 2, '{}', 0, 1)",
                [],
            )
            .is_err());
        assert!(conn
            .execute(
                "INSERT INTO user_operation_receipts (user_op_hash, tx_hash, success, receipt_json, tentative, created_at) VALUES ('0xop2', '0xtx2', 1, '{}', 2, 1)",
                [],
            )
            .is_err());
    }
}
