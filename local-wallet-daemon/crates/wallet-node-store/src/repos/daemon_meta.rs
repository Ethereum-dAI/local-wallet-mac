use rusqlite::{params, Connection, Error};

use crate::StoreError;

pub(crate) fn meta_get(conn: &Connection, key: &str) -> Result<Option<String>, StoreError> {
    match conn.query_row(
        "SELECT value FROM daemon_meta WHERE key = ?",
        params![key],
        |row| row.get(0),
    ) {
        Ok(value) => Ok(Some(value)),
        Err(Error::QueryReturnedNoRows) => Ok(None),
        Err(err) => Err(err.into()),
    }
}

pub(crate) fn meta_set(conn: &Connection, key: &str, value: &str) -> Result<(), StoreError> {
    conn.execute(
        "INSERT INTO daemon_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![key, value],
    )?;
    Ok(())
}

pub(crate) fn meta_delete(conn: &Connection, key: &str) -> Result<(), StoreError> {
    conn.execute("DELETE FROM daemon_meta WHERE key = ?", params![key])?;
    Ok(())
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
    fn get_returns_none_for_missing_key() {
        let conn = migrated_in_memory_conn();

        assert_eq!(meta_get(&conn, "missing").unwrap(), None);
    }

    #[test]
    fn set_then_get_round_trips() {
        let conn = migrated_in_memory_conn();

        meta_set(&conn, "k", "v").unwrap();

        assert_eq!(meta_get(&conn, "k").unwrap(), Some("v".to_owned()));
    }

    #[test]
    fn set_overwrites_existing() {
        let conn = migrated_in_memory_conn();

        meta_set(&conn, "k", "v1").unwrap();
        meta_set(&conn, "k", "v2").unwrap();

        assert_eq!(meta_get(&conn, "k").unwrap(), Some("v2".to_owned()));
    }

    #[test]
    fn delete_removes_row() {
        let conn = migrated_in_memory_conn();

        meta_set(&conn, "k", "v").unwrap();
        meta_delete(&conn, "k").unwrap();

        assert_eq!(meta_get(&conn, "k").unwrap(), None);
    }

    #[test]
    fn delete_missing_key_is_noop() {
        let conn = migrated_in_memory_conn();

        meta_delete(&conn, "missing").unwrap();

        assert_eq!(meta_get(&conn, "missing").unwrap(), None);
    }
}
