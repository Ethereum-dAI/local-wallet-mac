use rusqlite::{params, Connection};

use crate::{RelayerKeyAuditEvent, StoreError};

pub(crate) fn insert(conn: &Connection, event: &RelayerKeyAuditEvent) -> Result<(), StoreError> {
    conn.execute(
        "INSERT INTO relayer_key_audit_events (event_type, owner_scope, chain_id, key_ref, address, previous_lifecycle, new_lifecycle, admin_action_id, result, failure_reason, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        params![
            event.event_type,
            event.owner_scope,
            event.chain_id,
            event.key_ref,
            event.address,
            event.previous_lifecycle,
            event.new_lifecycle,
            event.admin_action_id,
            event.result,
            event.failure_reason,
            event.created_at
        ],
    )?;
    Ok(())
}

pub(crate) fn list(
    conn: &Connection,
    owner_scope: &str,
    chain_id: u64,
    limit: u64,
) -> Result<Vec<RelayerKeyAuditEvent>, StoreError> {
    let mut stmt = conn.prepare(
        "SELECT id, event_type, owner_scope, chain_id, key_ref, address, previous_lifecycle, new_lifecycle, admin_action_id, result, failure_reason, created_at FROM relayer_key_audit_events WHERE owner_scope = ? AND chain_id = ? ORDER BY created_at DESC, id DESC LIMIT ?",
    )?;
    let rows = stmt.query_map(params![owner_scope, chain_id, limit], |row| {
        Ok(RelayerKeyAuditEvent {
            id: row.get(0)?,
            event_type: row.get(1)?,
            owner_scope: row.get(2)?,
            chain_id: row.get(3)?,
            key_ref: row.get(4)?,
            address: row.get(5)?,
            previous_lifecycle: row.get(6)?,
            new_lifecycle: row.get(7)?,
            admin_action_id: row.get(8)?,
            result: row.get(9)?,
            failure_reason: row.get(10)?,
            created_at: row.get(11)?,
        })
    })?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(StoreError::from)
}
