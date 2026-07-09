use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};

use crate::{
    StoreAuditFinding, StoreAuditReport, StoreAuditRunSummary, StoreAuditSummary, StoreError,
};

const RETENTION_RUNS: i64 = 100;

pub(crate) fn audit_report_persist(
    conn: &mut Connection,
    chain_id: u64,
    synced: bool,
    report: &StoreAuditReport,
) -> Result<i64, StoreError> {
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    tx.execute(
        "INSERT INTO audit_runs (generated_at, chain_id, synced, summary_json) VALUES (?, ?, ?, ?)",
        params![
            report.generated_at,
            chain_id,
            synced,
            serde_json::to_string(&report.summary).unwrap_or_else(|_| "{}".to_string())
        ],
    )?;
    let run_id = tx.last_insert_rowid();

    for finding in &report.findings {
        tx.execute(
            "INSERT INTO audit_findings (run_id, source, severity, code, table_name, subject, message, suggested_action, recommended_repair_action) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            params![
                run_id,
                enum_wire_value(&finding.source),
                enum_wire_value(&finding.severity),
                sanitize_audit_text(&finding.code),
                finding.table.as_deref().map(sanitize_audit_text),
                finding.subject.as_deref().map(sanitize_audit_text),
                sanitize_audit_text(&finding.message),
                finding.suggested_action.as_deref().map(sanitize_audit_text),
                finding.recommended_repair_action.as_deref().map(sanitize_audit_text),
            ],
        )?;
    }

    tx.execute(
        "DELETE FROM audit_findings WHERE run_id IN (SELECT id FROM audit_runs ORDER BY generated_at DESC, id DESC LIMIT -1 OFFSET ?)",
        params![RETENTION_RUNS],
    )?;
    tx.execute(
        "DELETE FROM audit_runs WHERE id IN (SELECT id FROM audit_runs ORDER BY generated_at DESC, id DESC LIMIT -1 OFFSET ?)",
        params![RETENTION_RUNS],
    )?;
    tx.commit()?;

    Ok(run_id)
}

pub(crate) fn audit_history_list(
    conn: &Connection,
    limit: u64,
) -> Result<Vec<StoreAuditRunSummary>, StoreError> {
    let limit = limit.clamp(1, RETENTION_RUNS as u64);
    let mut stmt = conn.prepare(
        "SELECT id, generated_at, chain_id, synced, summary_json FROM audit_runs ORDER BY generated_at DESC, id DESC LIMIT ?",
    )?;
    let rows = stmt.query_map(params![limit], audit_run_from_row)?;

    let mut runs = Vec::new();
    for row in rows {
        runs.push(row?);
    }
    Ok(runs)
}

pub(crate) fn audit_report_get(
    conn: &Connection,
    run_id: i64,
) -> Result<Option<StoreAuditReport>, StoreError> {
    let run = conn
        .query_row(
            "SELECT id, generated_at, chain_id, synced, summary_json FROM audit_runs WHERE id = ?",
            params![run_id],
            audit_run_from_row,
        )
        .optional()?;
    let Some(run) = run else {
        return Ok(None);
    };

    let mut stmt = conn.prepare(
        "SELECT source, severity, code, table_name, subject, message, suggested_action, recommended_repair_action FROM audit_findings WHERE run_id = ? ORDER BY rowid",
    )?;
    let rows = stmt.query_map(params![run_id], |row| {
        Ok(StoreAuditFinding {
            source: parse_wire_enum(row.get::<_, String>(0)?),
            severity: parse_wire_enum(row.get::<_, String>(1)?),
            code: row.get(2)?,
            table: row.get(3)?,
            subject: row.get(4)?,
            message: row.get(5)?,
            suggested_action: row.get(6)?,
            recommended_repair_action: row.get(7)?,
        })
    })?;

    let mut findings = Vec::new();
    for row in rows {
        findings.push(row?);
    }

    Ok(Some(StoreAuditReport {
        audit_run_id: Some(run.id),
        generated_at: run.generated_at,
        summary: StoreAuditSummary::from_findings(&findings),
        findings,
    }))
}

fn audit_run_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<StoreAuditRunSummary> {
    let summary_json: String = row.get(4)?;
    let summary = serde_json::from_str(&summary_json).unwrap_or_default();
    Ok(StoreAuditRunSummary {
        id: row.get(0)?,
        generated_at: row.get(1)?,
        chain_id: row.get(2)?,
        synced: row.get::<_, bool>(3)?,
        summary,
    })
}

fn enum_wire_value<T: serde::Serialize>(value: &T) -> String {
    serde_json::to_value(value)
        .ok()
        .and_then(|value| value.as_str().map(str::to_owned))
        .unwrap_or_else(|| "unknown".to_string())
}

fn parse_wire_enum<T>(value: String) -> T
where
    T: for<'de> serde::Deserialize<'de> + Default,
{
    serde_json::from_value(serde_json::Value::String(value)).unwrap_or_default()
}

fn sanitize_audit_text(value: &str) -> String {
    let lower = value.to_ascii_lowercase();
    if lower.contains("bearer")
        || lower.contains("raw_tx")
        || lower.contains("signature")
        || lower.contains("0x020304")
    {
        return "[redacted]".to_string();
    }

    let mut sanitized = value.replace('\n', " ");
    if sanitized.len() > 1024 {
        sanitized.truncate(1024);
    }
    sanitized
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{audit, db, migrations};
    use crate::{AuditFindingSeverity, AuditFindingSource};

    fn conn() -> Connection {
        let mut conn = db::open_in_memory().unwrap();
        migrations::apply(&mut conn).unwrap();
        conn
    }

    #[test]
    fn audit_report_persist_and_read_back_round_trips() {
        let mut conn = conn();
        let report = StoreAuditReport::new(vec![audit::finding_with_repair_action(
            AuditFindingSource::Chain,
            AuditFindingSeverity::Warning,
            "pending_tx_nonce_advanced_without_receipt",
            Some("submitted_transactions"),
            Some("0xtx".to_string()),
            "nonce advanced",
            Some("mark dropped"),
            Some("markTxDropped"),
        )]);

        let run_id = audit_report_persist(&mut conn, 1, true, &report).unwrap();
        let stored = audit_report_get(&conn, run_id).unwrap().unwrap();

        assert_eq!(stored.audit_run_id, Some(run_id));
        assert_eq!(stored.findings.len(), 1);
        assert_eq!(
            stored.findings[0].recommended_repair_action.as_deref(),
            Some("markTxDropped")
        );
        assert_eq!(audit_history_list(&conn, 10).unwrap().len(), 1);
    }

    #[test]
    fn audit_history_retention_keeps_latest_100_runs() {
        let mut conn = conn();
        let report = StoreAuditReport::new(vec![]);

        for _ in 0..105 {
            audit_report_persist(&mut conn, 1, true, &report).unwrap();
        }

        let runs = audit_history_list(&conn, 200).unwrap();
        let run_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM audit_runs", [], |row| row.get(0))
            .unwrap();

        assert_eq!(runs.len(), 100);
        assert_eq!(run_count, 100);
    }

    #[test]
    fn audit_history_redacts_secret_like_text() {
        let mut conn = conn();
        let report = StoreAuditReport::new(vec![audit::finding(
            AuditFindingSource::Chain,
            AuditFindingSeverity::Warning,
            "chain_audit_receipt_lookup_failed",
            Some("submitted_transactions"),
            Some("Bearer token raw_tx 0x020304 signature".to_string()),
            "provider returned Bearer token raw_tx 0x020304 signature",
            Some("retry"),
        )]);

        let run_id = audit_report_persist(&mut conn, 1, true, &report).unwrap();
        let stored = audit_report_get(&conn, run_id).unwrap().unwrap();

        assert_eq!(stored.findings[0].subject.as_deref(), Some("[redacted]"));
        assert_eq!(stored.findings[0].message, "[redacted]");
    }
}
