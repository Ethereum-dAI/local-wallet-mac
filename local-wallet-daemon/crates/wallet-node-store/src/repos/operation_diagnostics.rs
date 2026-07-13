use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{params, Connection, Error};

use crate::StoreError;

pub(crate) fn diagnostic_set(
    conn: &Connection,
    subject_type: &str,
    subject_id: &str,
    last_error: &str,
) -> Result<(), StoreError> {
    conn.execute(
        "INSERT INTO operation_diagnostics (subject_type, subject_id, last_error, last_error_at) VALUES (?, ?, ?, ?) ON CONFLICT(subject_type, subject_id) DO UPDATE SET last_error = excluded.last_error, last_error_at = excluded.last_error_at",
        params![subject_type, subject_id, sanitize_error(last_error), now_unix_seconds()],
    )?;
    Ok(())
}

pub(crate) fn diagnostic_clear(
    conn: &Connection,
    subject_type: &str,
    subject_id: &str,
) -> Result<(), StoreError> {
    conn.execute(
        "DELETE FROM operation_diagnostics WHERE subject_type = ? AND subject_id = ?",
        params![subject_type, subject_id],
    )?;
    Ok(())
}

pub(crate) fn diagnostic_get(
    conn: &Connection,
    subject_type: &str,
    subject_id: &str,
) -> Result<Option<String>, StoreError> {
    match conn.query_row(
        "SELECT last_error FROM operation_diagnostics WHERE subject_type = ? AND subject_id = ?",
        params![subject_type, subject_id],
        |row| row.get::<_, String>(0),
    ) {
        Ok(value) => Ok(Some(value)),
        Err(Error::QueryReturnedNoRows) => Ok(None),
        Err(err) => Err(err.into()),
    }
}

fn sanitize_error(value: &str) -> String {
    let mut sanitized = value.replace('\n', " ");
    if sanitized.len() > 512 {
        sanitized.truncate(512);
    }
    sanitized
}

fn now_unix_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{db, migrations};

    fn conn() -> Connection {
        let mut conn = db::open_in_memory().unwrap();
        migrations::apply(&mut conn).unwrap();
        conn
    }

    #[test]
    fn diagnostic_set_get_clear_round_trips() {
        let conn = conn();

        diagnostic_set(&conn, "user_operation", "0xop", "receipt_lookup_failed").unwrap();
        assert_eq!(
            diagnostic_get(&conn, "user_operation", "0xop").unwrap(),
            Some("receipt_lookup_failed".to_string())
        );

        diagnostic_clear(&conn, "user_operation", "0xop").unwrap();
        assert_eq!(
            diagnostic_get(&conn, "user_operation", "0xop").unwrap(),
            None
        );
    }

    #[test]
    fn diagnostic_set_overwrites_and_sanitizes() {
        let conn = conn();

        diagnostic_set(&conn, "submitted_transaction", "0xtx", "first").unwrap();
        diagnostic_set(&conn, "submitted_transaction", "0xtx", "second\nline").unwrap();

        assert_eq!(
            diagnostic_get(&conn, "submitted_transaction", "0xtx").unwrap(),
            Some("second line".to_string())
        );
    }
}
