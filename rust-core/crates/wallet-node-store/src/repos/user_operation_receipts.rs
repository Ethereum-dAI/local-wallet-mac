use rusqlite::{params, Connection, Error};

use crate::{StoreError, UserOperationReceipt};

const INSERT_SQL: &str = "INSERT INTO user_operation_receipts (user_op_hash, tx_hash, success, actual_gas_cost, actual_gas_used, revert_reason, receipt_json, tentative, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)";
const SELECT_COLUMNS: &str = "user_op_hash, tx_hash, success, actual_gas_cost, actual_gas_used, revert_reason, receipt_json, tentative, created_at";

pub(crate) fn receipt_insert(
    conn: &Connection,
    receipt: UserOperationReceipt,
) -> Result<(), StoreError> {
    // rusqlite's ToSql for bool does this automatically, but bind explicit
    // integers so the on-disk representation stays obvious.
    let success = if receipt.success { 1_i64 } else { 0_i64 };
    let tentative = if receipt.tentative { 1_i64 } else { 0_i64 };

    conn.execute(
        INSERT_SQL,
        params![
            &receipt.user_op_hash,
            &receipt.tx_hash,
            success,
            &receipt.actual_gas_cost,
            &receipt.actual_gas_used,
            &receipt.revert_reason,
            &receipt.receipt_json,
            tentative,
            receipt.created_at,
        ],
    )?;
    Ok(())
}

pub(crate) fn receipt_get(
    conn: &Connection,
    user_op_hash: &str,
) -> Result<Option<UserOperationReceipt>, StoreError> {
    match conn.query_row(
        &format!("SELECT {SELECT_COLUMNS} FROM user_operation_receipts WHERE user_op_hash = ?"),
        params![user_op_hash],
        |row| {
            Ok(UserOperationReceipt {
                user_op_hash: row.get::<_, String>(0)?,
                tx_hash: row.get::<_, String>(1)?,
                success: row.get::<_, i64>(2)? != 0,
                actual_gas_cost: row.get::<_, Option<String>>(3)?,
                actual_gas_used: row.get::<_, Option<String>>(4)?,
                revert_reason: row.get::<_, Option<String>>(5)?,
                receipt_json: row.get::<_, String>(6)?,
                tentative: row.get::<_, i64>(7)? != 0,
                created_at: row.get::<_, i64>(8)?,
            })
        },
    ) {
        Ok(receipt) => Ok(Some(receipt)),
        Err(Error::QueryReturnedNoRows) => Ok(None),
        Err(err) => Err(err.into()),
    }
}

pub(crate) fn receipts_clear_tentative(conn: &Connection) -> Result<usize, StoreError> {
    Ok(conn.execute(
        "DELETE FROM user_operation_receipts WHERE tentative = 1",
        [],
    )?)
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

    fn receipt(
        user_op_hash: &str,
        tx_hash: &str,
        success: bool,
        tentative: bool,
    ) -> UserOperationReceipt {
        UserOperationReceipt {
            user_op_hash: user_op_hash.to_owned(),
            tx_hash: tx_hash.to_owned(),
            success,
            actual_gas_cost: Some("0x5208".to_owned()),
            actual_gas_used: Some("0x100".to_owned()),
            revert_reason: Some("0xdeadbeef".to_owned()),
            receipt_json: format!(r#"{{"userOpHash":"{user_op_hash}","txHash":"{tx_hash}"}}"#),
            tentative,
            created_at: 1,
        }
    }

    fn assert_receipt_eq(actual: &UserOperationReceipt, expected: &UserOperationReceipt) {
        assert_eq!(actual.user_op_hash, expected.user_op_hash);
        assert_eq!(actual.tx_hash, expected.tx_hash);
        assert_eq!(actual.success, expected.success);
        assert_eq!(actual.actual_gas_cost, expected.actual_gas_cost);
        assert_eq!(actual.actual_gas_used, expected.actual_gas_used);
        assert_eq!(actual.revert_reason, expected.revert_reason);
        assert_eq!(actual.receipt_json, expected.receipt_json);
        assert_eq!(actual.tentative, expected.tentative);
        assert_eq!(actual.created_at, expected.created_at);
    }

    #[test]
    fn insert_get_round_trips_with_tentative_false() {
        let conn = migrated_in_memory_conn();
        let receipt = receipt("0xuserop1", "0xtx1", true, false);

        receipt_insert(&conn, receipt.clone()).unwrap();
        let stored = receipt_get(&conn, "0xuserop1").unwrap().unwrap();

        assert_receipt_eq(&stored, &receipt);
    }

    #[test]
    fn insert_get_round_trips_with_tentative_true() {
        let conn = migrated_in_memory_conn();
        let receipt = receipt("0xuserop1", "0xtx1", true, true);

        receipt_insert(&conn, receipt.clone()).unwrap();
        let stored = receipt_get(&conn, "0xuserop1").unwrap().unwrap();

        assert_receipt_eq(&stored, &receipt);
    }

    #[test]
    fn insert_get_round_trips_with_optional_fields_none() {
        let conn = migrated_in_memory_conn();
        let receipt = UserOperationReceipt {
            actual_gas_cost: None,
            actual_gas_used: None,
            revert_reason: None,
            ..receipt("0xuserop1", "0xtx1", true, false)
        };

        receipt_insert(&conn, receipt.clone()).unwrap();
        let stored = receipt_get(&conn, "0xuserop1").unwrap().unwrap();

        assert_receipt_eq(&stored, &receipt);
    }

    #[test]
    fn insert_get_round_trips_with_optional_fields_some() {
        let conn = migrated_in_memory_conn();
        let receipt = UserOperationReceipt {
            actual_gas_cost: Some("0x1234".to_owned()),
            actual_gas_used: Some("0x5678".to_owned()),
            revert_reason: Some("execution reverted".to_owned()),
            ..receipt("0xuserop1", "0xtx1", false, false)
        };

        receipt_insert(&conn, receipt.clone()).unwrap();
        let stored = receipt_get(&conn, "0xuserop1").unwrap().unwrap();

        assert_receipt_eq(&stored, &receipt);
    }

    #[test]
    fn clear_tentative_only_removes_flagged() {
        let conn = migrated_in_memory_conn();
        for idx in 0..3 {
            receipt_insert(
                &conn,
                receipt(
                    &format!("0xtentative{idx}"),
                    &format!("0xtx{idx}"),
                    true,
                    true,
                ),
            )
            .unwrap();
        }
        for idx in 0..2 {
            receipt_insert(
                &conn,
                receipt(
                    &format!("0xconfirmed{idx}"),
                    &format!("0xconfirmedtx{idx}"),
                    true,
                    false,
                ),
            )
            .unwrap();
        }

        let deleted = receipts_clear_tentative(&conn).unwrap();
        let remaining: i64 = conn
            .query_row("SELECT COUNT(*) FROM user_operation_receipts", [], |row| {
                row.get(0)
            })
            .unwrap();

        assert_eq!(deleted, 3);
        assert_eq!(remaining, 2);
    }

    #[test]
    fn clear_tentative_on_empty_db_returns_zero() {
        let conn = migrated_in_memory_conn();

        assert_eq!(receipts_clear_tentative(&conn).unwrap(), 0);
    }

    #[test]
    fn success_field_round_trips_both_values() {
        let conn = migrated_in_memory_conn();
        receipt_insert(&conn, receipt("0xsuccess", "0xtx1", true, false)).unwrap();
        receipt_insert(&conn, receipt("0xfailure", "0xtx2", false, false)).unwrap();

        let success = receipt_get(&conn, "0xsuccess").unwrap().unwrap();
        let failure = receipt_get(&conn, "0xfailure").unwrap().unwrap();

        assert!(success.success);
        assert!(!failure.success);
    }
}
