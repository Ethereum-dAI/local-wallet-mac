use std::path::Path;

use rusqlite::{Connection, OpenFlags};

use crate::StoreError;

pub fn open(path: &Path) -> Result<Connection, StoreError> {
    if let Some(parent) = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    {
        std::fs::create_dir_all(parent)?;
    }

    let conn = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_CREATE,
    )?;
    apply_pragmas(&conn, "WAL")?;
    Ok(conn)
}

pub fn open_in_memory() -> Result<Connection, StoreError> {
    let conn = Connection::open_in_memory()?;

    // In-memory SQLite databases do not support WAL because there is no
    // separate persistent write-ahead log file. MEMORY is the closest mode.
    if let Err(err) = apply_pragmas(&conn, "WAL") {
        match err {
            StoreError::Sqlite(_) => apply_pragmas(&conn, "MEMORY")?,
            other => return Err(other),
        }
    }

    Ok(conn)
}

fn apply_pragmas(conn: &Connection, journal_mode: &str) -> Result<(), StoreError> {
    conn.pragma_update(None, "journal_mode", journal_mode)?;
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    conn.pragma_update(None, "busy_timeout", 5000_i64)?;
    conn.pragma_update(None, "foreign_keys", "ON")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opens_in_memory_with_pragmas() {
        let conn = open_in_memory().unwrap();

        let journal_mode: String = conn
            .query_row("PRAGMA journal_mode", [], |row| row.get(0))
            .unwrap();
        assert!(matches!(journal_mode.as_str(), "wal" | "memory"));

        let synchronous: i64 = conn
            .query_row("PRAGMA synchronous", [], |row| row.get(0))
            .unwrap();
        assert_eq!(synchronous, 1);

        let busy_timeout: i64 = conn
            .query_row("PRAGMA busy_timeout", [], |row| row.get(0))
            .unwrap();
        assert_eq!(busy_timeout, 5000);

        let foreign_keys: i64 = conn
            .query_row("PRAGMA foreign_keys", [], |row| row.get(0))
            .unwrap();
        assert_eq!(foreign_keys, 1);
    }
}
