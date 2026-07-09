use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::Connection;

use crate::StoreError;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AuditFindingSeverity {
    Info,
    #[default]
    Warning,
    Error,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AuditFindingSource {
    #[default]
    Store,
    Chain,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StoreAuditFinding {
    pub source: AuditFindingSource,
    pub severity: AuditFindingSeverity,
    pub code: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub table: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subject: Option<String>,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub suggested_action: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recommended_repair_action: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StoreAuditSummary {
    pub info: usize,
    pub warning: usize,
    pub error: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StoreAuditReport {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audit_run_id: Option<i64>,
    pub generated_at: i64,
    pub summary: StoreAuditSummary,
    pub findings: Vec<StoreAuditFinding>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StoreAuditRunSummary {
    pub id: i64,
    pub generated_at: i64,
    pub chain_id: u64,
    pub synced: bool,
    pub summary: StoreAuditSummary,
}

impl StoreAuditReport {
    pub fn new(findings: Vec<StoreAuditFinding>) -> Self {
        Self {
            audit_run_id: None,
            generated_at: now_unix_seconds(),
            summary: StoreAuditSummary::from_findings(&findings),
            findings,
        }
    }

    pub fn with_additional_findings(
        mut self,
        findings: impl IntoIterator<Item = StoreAuditFinding>,
    ) -> Self {
        self.findings.extend(findings);
        self.summary = StoreAuditSummary::from_findings(&self.findings);
        self
    }

    pub fn with_audit_run_id(mut self, audit_run_id: i64) -> Self {
        self.audit_run_id = Some(audit_run_id);
        self
    }
}

impl StoreAuditSummary {
    pub fn from_findings(findings: &[StoreAuditFinding]) -> Self {
        let mut summary = Self::default();
        for finding in findings {
            match finding.severity {
                AuditFindingSeverity::Info => summary.info += 1,
                AuditFindingSeverity::Warning => summary.warning += 1,
                AuditFindingSeverity::Error => summary.error += 1,
            }
        }
        summary
    }
}

pub fn audit_store(conn: &Connection) -> Result<StoreAuditReport, StoreError> {
    let mut findings = Vec::new();

    check_multiple_active_bundler_accounts(conn, &mut findings)?;
    check_submitted_txs_missing_user_ops(conn, &mut findings)?;
    check_receipts_missing_user_ops(conn, &mut findings)?;
    check_invalidated_receipts(conn, &mut findings)?;
    check_receipts_for_non_terminal_user_ops(conn, &mut findings)?;
    check_terminal_user_ops_with_pending_txs(conn, &mut findings)?;
    check_terminal_nonces_with_pending_txs(conn, &mut findings)?;
    check_missing_replacement_targets(conn, &mut findings)?;
    check_replacement_cycles(conn, &mut findings)?;
    check_duplicate_non_terminal_nonces(conn, &mut findings)?;
    check_pending_user_ops_without_submitted_tx(conn, &mut findings)?;
    check_migration_quarantine_rows(conn, &mut findings)?;

    Ok(StoreAuditReport::new(findings))
}

pub fn finding(
    source: AuditFindingSource,
    severity: AuditFindingSeverity,
    code: impl Into<String>,
    table: Option<&str>,
    subject: Option<String>,
    message: impl Into<String>,
    suggested_action: Option<&str>,
) -> StoreAuditFinding {
    finding_with_repair_action(
        source,
        severity,
        code,
        table,
        subject,
        message,
        suggested_action,
        None,
    )
}

#[allow(clippy::too_many_arguments)]
pub fn finding_with_repair_action(
    source: AuditFindingSource,
    severity: AuditFindingSeverity,
    code: impl Into<String>,
    table: Option<&str>,
    subject: Option<String>,
    message: impl Into<String>,
    suggested_action: Option<&str>,
    recommended_repair_action: Option<&str>,
) -> StoreAuditFinding {
    StoreAuditFinding {
        source,
        severity,
        code: code.into(),
        table: table.map(str::to_owned),
        subject,
        message: message.into(),
        suggested_action: suggested_action.map(str::to_owned),
        recommended_repair_action: recommended_repair_action.map(str::to_owned),
    }
}

pub fn recommended_repair_action_for_code(code: &str) -> Option<&'static str> {
    match code {
        "pending_tx_nonce_advanced_without_receipt" => Some("markTxDropped"),
        "receipt_for_non_terminal_user_op_tentative" => Some("clearTentativeReceipt"),
        "chain_receipt_status_conflicts_with_local_tx"
        | "chain_user_op_event_conflicts_with_local_status"
        | "deep_reorg_suspected"
        | "local_receipt_invalidated"
        | "local_receipt_stale" => Some("rebuildReceiptFromChain"),
        _ => None,
    }
}

fn check_migration_quarantine_rows(
    conn: &Connection,
    findings: &mut Vec<StoreAuditFinding>,
) -> Result<(), StoreError> {
    let mut stmt = conn.prepare(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE '%_v4_quarantine' ORDER BY name",
    )?;
    let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
    for row in rows {
        let table_name = row?;
        let count: i64 =
            conn.query_row(&format!("SELECT COUNT(*) FROM {table_name}"), [], |row| {
                row.get(0)
            })?;
        if count == 0 {
            continue;
        }
        findings.push(finding(
            AuditFindingSource::Store,
            AuditFindingSeverity::Warning,
            "migration_quarantine_rows",
            Some(&table_name),
            Some(table_name.clone()),
            format!("{count} row(s) were quarantined during the V5 schema migration"),
            Some("Inspect the quarantine table and either repair the source data manually or archive the quarantined rows after confirming they are obsolete."),
        ));
    }
    Ok(())
}

fn store_error(
    severity: AuditFindingSeverity,
    code: &'static str,
    table: &'static str,
    subject: impl Into<String>,
    message: impl Into<String>,
    suggested_action: &'static str,
) -> StoreAuditFinding {
    finding(
        AuditFindingSource::Store,
        severity,
        code,
        Some(table),
        Some(subject.into()),
        message,
        Some(suggested_action),
    )
}

fn check_multiple_active_bundler_accounts(
    conn: &Connection,
    findings: &mut Vec<StoreAuditFinding>,
) -> Result<(), StoreError> {
    let mut stmt = conn.prepare(
        "SELECT owner_scope, chain_id, COUNT(*) FROM bundler_accounts WHERE lifecycle = 'active' GROUP BY owner_scope, chain_id HAVING COUNT(*) > 1",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, u64>(1)?,
            row.get::<_, i64>(2)?,
        ))
    })?;
    for row in rows {
        let (owner_scope, chain_id, count) = row?;
        findings.push(store_error(
            AuditFindingSeverity::Error,
            "multiple_active_bundler_accounts",
            "bundler_accounts",
            format!("owner_scope:{owner_scope}:chain_id:{chain_id}"),
            format!(
                "owner {owner_scope} chain {chain_id} has {count} active bundler EOAs"
            ),
            "Retire all but one active bundler EOA for this owner/profile and chain before submitting new operations.",
        ));
    }
    Ok(())
}

fn check_submitted_txs_missing_user_ops(
    conn: &Connection,
    findings: &mut Vec<StoreAuditFinding>,
) -> Result<(), StoreError> {
    let mut stmt = conn.prepare(
        "SELECT s.tx_hash, s.user_op_hash FROM submitted_transactions s LEFT JOIN user_operations u ON u.user_op_hash = s.user_op_hash WHERE u.user_op_hash IS NULL",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    })?;
    for row in rows {
        let (tx_hash, user_op_hash) = row?;
        findings.push(store_error(
            AuditFindingSeverity::Error,
            "submitted_tx_missing_user_op",
            "submitted_transactions",
            tx_hash,
            format!("submitted transaction points to missing user operation {user_op_hash}"),
            "Inspect the row and mark the transaction failed or restore the missing user operation record.",
        ));
    }
    Ok(())
}

fn check_receipts_missing_user_ops(
    conn: &Connection,
    findings: &mut Vec<StoreAuditFinding>,
) -> Result<(), StoreError> {
    let mut stmt = conn.prepare(
        "SELECT r.user_op_hash, r.tx_hash FROM user_operation_receipts r LEFT JOIN user_operations u ON u.user_op_hash = r.user_op_hash WHERE u.user_op_hash IS NULL",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    })?;
    for row in rows {
        let (user_op_hash, tx_hash) = row?;
        findings.push(store_error(
            AuditFindingSeverity::Error,
            "receipt_missing_user_op",
            "user_operation_receipts",
            user_op_hash,
            format!("receipt for tx {tx_hash} points to a missing user operation"),
            "Inspect the receipt and restore or clear the orphaned local receipt.",
        ));
    }
    Ok(())
}

fn check_invalidated_receipts(
    conn: &Connection,
    findings: &mut Vec<StoreAuditFinding>,
) -> Result<(), StoreError> {
    let mut stmt = conn.prepare(
        "SELECT user_op_hash, tx_hash FROM user_operation_receipts WHERE invalidated = 1",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    })?;
    for row in rows {
        let (user_op_hash, tx_hash) = row?;
        findings.push(finding_with_repair_action(
            AuditFindingSource::Store,
            AuditFindingSeverity::Warning,
            "local_receipt_invalidated",
            Some("user_operation_receipts"),
            Some(user_op_hash),
            format!("stored receipt for tx {tx_hash} was invalidated after verified chain reconciliation"),
            Some("Rebuild the local receipt from the verified chain receipt."),
            recommended_repair_action_for_code("local_receipt_invalidated"),
        ));
    }
    Ok(())
}

fn check_receipts_for_non_terminal_user_ops(
    conn: &Connection,
    findings: &mut Vec<StoreAuditFinding>,
) -> Result<(), StoreError> {
    let mut stmt = conn.prepare(
        "SELECT r.user_op_hash, u.status, r.tentative FROM user_operation_receipts r JOIN user_operations u ON u.user_op_hash = r.user_op_hash WHERE u.status IN ('received', 'simulated', 'submitted', 'pending') AND r.invalidated = 0",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, bool>(2)?,
        ))
    })?;
    for row in rows {
        let (user_op_hash, status, tentative) = row?;
        let code = if tentative {
            "receipt_for_non_terminal_user_op_tentative"
        } else {
            "receipt_for_non_terminal_user_op"
        };
        findings.push(finding_with_repair_action(
            AuditFindingSource::Store,
            AuditFindingSeverity::Warning,
            code,
            Some("user_operation_receipts"),
            Some(user_op_hash),
            format!("receipt exists while user operation status is {status}"),
            Some("Rebuild the user operation status from the verified receipt or clear an invalid tentative receipt."),
            recommended_repair_action_for_code(code),
        ));
    }
    Ok(())
}

fn check_terminal_user_ops_with_pending_txs(
    conn: &Connection,
    findings: &mut Vec<StoreAuditFinding>,
) -> Result<(), StoreError> {
    let mut stmt = conn.prepare(
        "SELECT u.user_op_hash, u.status, s.tx_hash, s.status FROM user_operations u JOIN submitted_transactions s ON s.user_op_hash = u.user_op_hash WHERE u.status IN ('included', 'reverted', 'failed') AND s.status IN ('submitting', 'submitted')",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, String>(3)?,
        ))
    })?;
    for row in rows {
        let (user_op_hash, user_op_status, tx_hash, tx_status) = row?;
        findings.push(store_error(
            AuditFindingSeverity::Warning,
            "terminal_user_op_has_pending_tx",
            "user_operations",
            user_op_hash,
            format!("terminal user operation status {user_op_status} has pending tx {tx_hash} with status {tx_status}"),
            "Mark the transaction terminal or rebuild both statuses from chain receipts.",
        ));
    }
    Ok(())
}

fn check_terminal_nonces_with_pending_txs(
    conn: &Connection,
    findings: &mut Vec<StoreAuditFinding>,
) -> Result<(), StoreError> {
    let mut stmt = conn.prepare(
        "SELECT n.chain_id, n.bundler_address, n.nonce, n.status, s.tx_hash, s.status FROM nonce_reservations n JOIN submitted_transactions s ON s.tx_hash = n.tx_hash WHERE n.status IN ('included', 'failed', 'replaced', 'abandoned') AND s.status IN ('submitting', 'submitted')",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, u64>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, u64>(2)?,
            row.get::<_, String>(3)?,
            row.get::<_, String>(4)?,
            row.get::<_, String>(5)?,
        ))
    })?;
    for row in rows {
        let (chain_id, bundler, nonce, nonce_status, tx_hash, tx_status) = row?;
        findings.push(store_error(
            AuditFindingSeverity::Warning,
            "terminal_nonce_has_pending_tx",
            "nonce_reservations",
            format!("{chain_id}:{bundler}:{nonce}"),
            format!("terminal nonce status {nonce_status} points to pending tx {tx_hash} with status {tx_status}"),
            "Reconcile the submitted transaction and nonce reservation from chain state.",
        ));
    }
    Ok(())
}

fn check_missing_replacement_targets(
    conn: &Connection,
    findings: &mut Vec<StoreAuditFinding>,
) -> Result<(), StoreError> {
    let mut stmt = conn.prepare(
        "SELECT s.tx_hash, s.replacement_of FROM submitted_transactions s LEFT JOIN submitted_transactions old ON old.tx_hash = s.replacement_of WHERE s.replacement_of IS NOT NULL AND old.tx_hash IS NULL",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    })?;
    for row in rows {
        let (tx_hash, replacement_of) = row?;
        findings.push(store_error(
            AuditFindingSeverity::Warning,
            "replacement_target_missing",
            "submitted_transactions",
            tx_hash,
            format!("replacement_of points to missing transaction {replacement_of}"),
            "Inspect the replacement chain and restore or clear the broken replacement link.",
        ));
    }
    Ok(())
}

fn check_replacement_cycles(
    conn: &Connection,
    findings: &mut Vec<StoreAuditFinding>,
) -> Result<(), StoreError> {
    let mut stmt = conn.prepare(
        "SELECT tx_hash, replacement_of FROM submitted_transactions WHERE replacement_of IS NOT NULL",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    })?;
    let mut replacements = BTreeMap::new();
    for row in rows {
        let (tx_hash, replacement_of) = row?;
        replacements.insert(tx_hash, replacement_of);
    }

    let mut reported = BTreeSet::new();
    for start in replacements.keys() {
        let mut seen = HashSet::new();
        let mut current = start.as_str();
        while let Some(next) = replacements.get(current) {
            if !seen.insert(current.to_owned()) {
                if reported.insert(start.clone()) {
                    findings.push(store_error(
                        AuditFindingSeverity::Error,
                        "replacement_chain_cycle",
                        "submitted_transactions",
                        start.clone(),
                        "submitted transaction replacement chain contains a cycle",
                        "Break the replacement link cycle before running repair actions.",
                    ));
                }
                break;
            }
            current = next;
        }
    }
    Ok(())
}

fn check_duplicate_non_terminal_nonces(
    conn: &Connection,
    findings: &mut Vec<StoreAuditFinding>,
) -> Result<(), StoreError> {
    let mut stmt = conn.prepare(
        "SELECT chain_id, bundler_address, nonce, COUNT(*) FROM nonce_reservations WHERE status IN ('reserved', 'submitted') GROUP BY chain_id, bundler_address, nonce HAVING COUNT(*) > 1",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, u64>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, u64>(2)?,
            row.get::<_, i64>(3)?,
        ))
    })?;
    for row in rows {
        let (chain_id, bundler, nonce, count) = row?;
        findings.push(store_error(
            AuditFindingSeverity::Error,
            "duplicate_non_terminal_nonce_reservation",
            "nonce_reservations",
            format!("{chain_id}:{bundler}:{nonce}"),
            format!("{count} non-terminal nonce reservations share the same nonce"),
            "Manually inspect duplicate nonce rows and abandon the invalid reservation.",
        ));
    }
    Ok(())
}

fn check_pending_user_ops_without_submitted_tx(
    conn: &Connection,
    findings: &mut Vec<StoreAuditFinding>,
) -> Result<(), StoreError> {
    let mut stmt = conn.prepare(
        "SELECT u.user_op_hash, u.status FROM user_operations u LEFT JOIN submitted_transactions s ON s.user_op_hash = u.user_op_hash WHERE u.status IN ('submitted', 'pending') AND s.tx_hash IS NULL",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    })?;
    for row in rows {
        let (user_op_hash, status) = row?;
        findings.push(store_error(
            AuditFindingSeverity::Warning,
            "pending_user_op_missing_submitted_tx",
            "user_operations",
            user_op_hash,
            format!("user operation status is {status} but no submitted transaction exists"),
            "Retry submission if safe, or mark the user operation failed after confirming no tx exists on chain.",
        ));
    }
    Ok(())
}

fn now_unix_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

#[cfg(test)]
mod tests {
    use rusqlite::params;
    use rusqlite::Connection;
    use serde_json::json;

    use super::*;
    use crate::{db, migrations};

    fn conn() -> Connection {
        let mut conn = db::open_in_memory().unwrap();
        migrations::apply(&mut conn).unwrap();
        conn
    }

    fn insert_user_op(conn: &Connection, hash: &str, status: &str) {
        conn.execute(
            "INSERT INTO user_operations (user_op_hash, chain_id, entry_point, sender, nonce, user_op_json, status, created_at, updated_at) VALUES (?, 1, '0xentry', '0x1000000000000000000000000000000000000000', '0x1', '{}', ?, 1, 1)",
            params![hash, status],
        )
        .unwrap();
    }

    fn insert_tx(
        conn: &Connection,
        tx_hash: &str,
        user_op_hash: &str,
        status: &str,
        nonce: u64,
        replacement_of: Option<&str>,
    ) {
        conn.execute(
            "INSERT INTO submitted_transactions (tx_hash, user_op_hash, chain_id, bundler_address, nonce, raw_tx, max_fee_per_gas, max_priority_fee_per_gas, status, replacement_of, submitted_at_block, created_at, updated_at) VALUES (?, ?, 1, '0xbeef000000000000000000000000000000000000', ?, '0x02', '0x64', '0x01', ?, ?, 100, 1, 1)",
            params![tx_hash, user_op_hash, nonce, status, replacement_of],
        )
        .unwrap();
    }

    fn insert_nonce(conn: &Connection, nonce: u64, status: &str, tx_hash: Option<&str>) {
        conn.execute(
            "INSERT INTO nonce_reservations (chain_id, bundler_address, nonce, status, user_op_hash, tx_hash, created_at, updated_at) VALUES (1, '0xbeef000000000000000000000000000000000000', ?, ?, NULL, ?, 1, 1)",
            params![nonce, status, tx_hash],
        )
        .unwrap();
    }

    fn codes(report: &StoreAuditReport) -> BTreeSet<String> {
        report
            .findings
            .iter()
            .map(|finding| finding.code.clone())
            .collect()
    }

    #[test]
    fn severity_serializes_as_snake_case() {
        assert_eq!(
            serde_json::to_value(AuditFindingSeverity::Warning).unwrap(),
            json!("warning")
        );
    }

    #[test]
    fn report_summary_counts_findings() {
        let report = StoreAuditReport::new(vec![
            finding(
                AuditFindingSource::Store,
                AuditFindingSeverity::Info,
                "info_code",
                None,
                None,
                "info",
                None,
            ),
            finding(
                AuditFindingSource::Store,
                AuditFindingSeverity::Warning,
                "warning_code",
                None,
                None,
                "warning",
                None,
            ),
            finding(
                AuditFindingSource::Store,
                AuditFindingSeverity::Error,
                "error_code",
                None,
                None,
                "error",
                None,
            ),
        ]);

        assert_eq!(report.summary.info, 1);
        assert_eq!(report.summary.warning, 1);
        assert_eq!(report.summary.error, 1);
    }

    #[test]
    fn finding_json_shape_is_stable() {
        let value = serde_json::to_value(finding(
            AuditFindingSource::Store,
            AuditFindingSeverity::Error,
            "submitted_tx_missing_user_op",
            Some("submitted_transactions"),
            Some("0xtx".to_string()),
            "submitted transaction points to missing user operation",
            Some("Inspect the row."),
        ))
        .unwrap();

        assert_eq!(
            value,
            json!({
                "source": "store",
                "severity": "error",
                "code": "submitted_tx_missing_user_op",
                "table": "submitted_transactions",
                "subject": "0xtx",
                "message": "submitted transaction points to missing user operation",
                "suggestedAction": "Inspect the row."
            })
        );
    }

    #[test]
    fn finding_json_shape_includes_recommended_repair_action_when_present() {
        let value = serde_json::to_value(finding_with_repair_action(
            AuditFindingSource::Chain,
            AuditFindingSeverity::Warning,
            "pending_tx_nonce_advanced_without_receipt",
            Some("submitted_transactions"),
            Some("0xtx".to_string()),
            "nonce advanced",
            Some("mark dropped"),
            Some("markTxDropped"),
        ))
        .unwrap();

        assert_eq!(value["recommendedRepairAction"], "markTxDropped");
        assert_eq!(value["suggestedAction"], "mark dropped");
    }

    #[test]
    fn recommended_repair_action_mapping_is_stable() {
        assert_eq!(
            recommended_repair_action_for_code("pending_tx_nonce_advanced_without_receipt"),
            Some("markTxDropped")
        );
        assert_eq!(
            recommended_repair_action_for_code("receipt_for_non_terminal_user_op_tentative"),
            Some("clearTentativeReceipt")
        );
        assert_eq!(
            recommended_repair_action_for_code("chain_receipt_status_conflicts_with_local_tx"),
            Some("rebuildReceiptFromChain")
        );
        assert_eq!(
            recommended_repair_action_for_code("local_receipt_invalidated"),
            Some("rebuildReceiptFromChain")
        );
        assert_eq!(
            recommended_repair_action_for_code("submitted_tx_missing_user_op"),
            None
        );
    }

    #[test]
    fn empty_healthy_db_has_no_findings() {
        let conn = conn();

        let report = audit_store(&conn).unwrap();

        assert!(report.findings.is_empty());
        assert_eq!(report.summary, StoreAuditSummary::default());
    }

    #[test]
    fn healthy_pending_send_has_no_findings() {
        let conn = conn();
        insert_user_op(&conn, "0xop", "submitted");
        insert_tx(&conn, "0xtx", "0xop", "submitted", 7, None);
        insert_nonce(&conn, 7, "submitted", Some("0xtx"));

        let report = audit_store(&conn).unwrap();

        assert!(report.findings.is_empty(), "{:?}", report.findings);
    }

    #[test]
    fn active_bundler_account_invariant_allows_distinct_owner_scopes() {
        let conn = conn();
        conn.execute(
            "INSERT INTO bundler_accounts (owner_scope, chain_id, address, key_ref, lifecycle, created_at) VALUES ('default', 1, '0x1', 'k1', 'active', 1), ('profile2', 1, '0x2', 'k2', 'active', 1)",
            [],
        )
        .unwrap();

        let report = audit_store(&conn).unwrap();

        assert!(!codes(&report).contains("multiple_active_bundler_accounts"));
    }

    #[test]
    fn detects_submitted_tx_missing_user_op() {
        let conn = conn();
        insert_tx(&conn, "0xorphantx", "0xmissing", "submitted", 7, None);

        let report = audit_store(&conn).unwrap();

        assert!(codes(&report).contains("submitted_tx_missing_user_op"));
    }

    #[test]
    fn detects_receipt_missing_user_op() {
        let conn = conn();
        conn.execute(
            "INSERT INTO user_operation_receipts (user_op_hash, tx_hash, success, receipt_json, tentative, created_at) VALUES ('0xmissingreceiptop', '0xtx', 1, '{}', 0, 1)",
            [],
        )
        .unwrap();

        let report = audit_store(&conn).unwrap();

        assert!(codes(&report).contains("receipt_missing_user_op"));
    }

    #[test]
    fn detects_receipt_for_non_terminal_user_op() {
        let conn = conn();
        insert_user_op(&conn, "0xpending", "submitted");
        conn.execute(
            "INSERT INTO user_operation_receipts (user_op_hash, tx_hash, success, receipt_json, tentative, created_at) VALUES ('0xpending', '0xtx', 1, '{}', 0, 1)",
            [],
        )
        .unwrap();

        let report = audit_store(&conn).unwrap();

        assert!(codes(&report).contains("receipt_for_non_terminal_user_op"));
    }

    #[test]
    fn detects_tentative_receipt_for_non_terminal_user_op_with_repair_action() {
        let conn = conn();
        insert_user_op(&conn, "0xpending", "submitted");
        conn.execute(
            "INSERT INTO user_operation_receipts (user_op_hash, tx_hash, success, receipt_json, tentative, created_at) VALUES ('0xpending', '0xtx', 1, '{}', 1, 1)",
            [],
        )
        .unwrap();

        let report = audit_store(&conn).unwrap();
        let finding = report
            .findings
            .iter()
            .find(|finding| finding.code == "receipt_for_non_terminal_user_op_tentative")
            .unwrap();

        assert_eq!(
            finding.recommended_repair_action.as_deref(),
            Some("clearTentativeReceipt")
        );
    }

    #[test]
    fn ignores_invalidated_receipt_for_non_terminal_user_op() {
        let conn = conn();
        insert_user_op(&conn, "0xpending", "submitted");
        conn.execute(
            "INSERT INTO user_operation_receipts (user_op_hash, tx_hash, success, receipt_json, tentative, invalidated, created_at) VALUES ('0xpending', '0xtx', 1, '{}', 0, 1, 1)",
            [],
        )
        .unwrap();

        let report = audit_store(&conn).unwrap();

        assert!(!report.findings.iter().any(|finding| {
            finding.code == "receipt_for_non_terminal_user_op"
                && finding.subject.as_deref() == Some("0xpending")
        }));
    }

    #[test]
    fn detects_invalidated_receipt_with_repair_action() {
        let conn = conn();
        insert_user_op(&conn, "0xpending", "submitted");
        conn.execute(
            "INSERT INTO user_operation_receipts (user_op_hash, tx_hash, success, receipt_json, tentative, invalidated, created_at) VALUES ('0xpending', '0xtx', 1, '{}', 0, 1, 1)",
            [],
        )
        .unwrap();

        let report = audit_store(&conn).unwrap();
        let finding = report
            .findings
            .iter()
            .find(|finding| {
                finding.code == "local_receipt_invalidated"
                    && finding.subject.as_deref() == Some("0xpending")
            })
            .unwrap();

        assert_eq!(
            finding.recommended_repair_action.as_deref(),
            Some("rebuildReceiptFromChain")
        );
    }

    #[test]
    fn detects_terminal_user_op_with_pending_tx() {
        let conn = conn();
        insert_user_op(&conn, "0xterminal", "included");
        insert_tx(&conn, "0xpendingtx", "0xterminal", "submitted", 8, None);

        let report = audit_store(&conn).unwrap();

        assert!(codes(&report).contains("terminal_user_op_has_pending_tx"));
    }

    #[test]
    fn detects_terminal_nonce_with_pending_tx() {
        let conn = conn();
        insert_user_op(&conn, "0xop", "submitted");
        insert_tx(&conn, "0xpendingtx", "0xop", "submitted", 8, None);
        insert_nonce(&conn, 8, "included", Some("0xpendingtx"));

        let report = audit_store(&conn).unwrap();

        assert!(codes(&report).contains("terminal_nonce_has_pending_tx"));
    }

    #[test]
    fn detects_missing_replacement_target() {
        let conn = conn();
        insert_user_op(&conn, "0xop", "submitted");
        insert_tx(
            &conn,
            "0xbrokenreplacement",
            "0xop",
            "submitted",
            7,
            Some("0xmissing"),
        );

        let report = audit_store(&conn).unwrap();

        assert!(codes(&report).contains("replacement_target_missing"));
    }

    #[test]
    fn detects_replacement_chain_cycle() {
        let conn = conn();
        insert_user_op(&conn, "0xop", "submitted");
        insert_tx(&conn, "0xcyclea", "0xop", "submitted", 8, Some("0xcycleb"));
        insert_tx(&conn, "0xcycleb", "0xop", "submitted", 9, Some("0xcyclea"));

        let report = audit_store(&conn).unwrap();

        assert!(codes(&report).contains("replacement_chain_cycle"));
    }

    #[test]
    fn duplicate_non_terminal_nonce_reservations_are_prevented_by_schema() {
        let conn = conn();
        insert_nonce(&conn, 7, "reserved", None);

        let duplicate = conn.execute(
            "INSERT INTO nonce_reservations (chain_id, bundler_address, nonce, status, user_op_hash, tx_hash, created_at, updated_at) VALUES (1, '0xbeef000000000000000000000000000000000000', 7, 'submitted', NULL, NULL, 1, 1)",
            [],
        );

        assert!(duplicate.is_err());
        let report = audit_store(&conn).unwrap();
        assert!(!codes(&report).contains("duplicate_non_terminal_nonce_reservation"));
    }

    #[test]
    fn detects_pending_user_op_without_submitted_tx() {
        let conn = conn();
        insert_user_op(&conn, "0xpending", "pending");

        let report = audit_store(&conn).unwrap();

        assert!(codes(&report).contains("pending_user_op_missing_submitted_tx"));
    }

    #[test]
    fn detects_orphaned_rows_and_status_conflicts() {
        let conn = conn();
        insert_user_op(&conn, "0xterminal", "included");
        insert_user_op(&conn, "0xpending", "submitted");
        insert_tx(&conn, "0xorphantx", "0xmissing", "submitted", 7, None);
        insert_tx(&conn, "0xpendingtx", "0xterminal", "submitted", 8, None);
        insert_nonce(&conn, 8, "included", Some("0xpendingtx"));
        conn.execute(
            "INSERT INTO user_operation_receipts (user_op_hash, tx_hash, success, receipt_json, tentative, created_at) VALUES ('0xmissingreceiptop', '0xtx', 1, '{}', 0, 1), ('0xpending', '0xtx2', 1, '{}', 0, 1)",
            [],
        )
        .unwrap();

        let report = audit_store(&conn).unwrap();
        let codes = codes(&report);

        assert!(codes.contains("submitted_tx_missing_user_op"));
        assert!(codes.contains("receipt_missing_user_op"));
        assert!(codes.contains("receipt_for_non_terminal_user_op"));
        assert!(codes.contains("terminal_user_op_has_pending_tx"));
        assert!(codes.contains("terminal_nonce_has_pending_tx"));
    }

    #[test]
    fn detects_replacement_issues_and_pending_user_op_without_tx() {
        let conn = conn();
        insert_user_op(&conn, "0xpending", "pending");
        insert_user_op(&conn, "0xop", "submitted");
        insert_tx(
            &conn,
            "0xbrokenreplacement",
            "0xop",
            "submitted",
            7,
            Some("0xmissing"),
        );
        insert_tx(&conn, "0xcyclea", "0xop", "submitted", 8, Some("0xcycleb"));
        insert_tx(&conn, "0xcycleb", "0xop", "submitted", 9, Some("0xcyclea"));

        let report = audit_store(&conn).unwrap();
        let codes = codes(&report);

        assert!(codes.contains("replacement_target_missing"));
        assert!(codes.contains("replacement_chain_cycle"));
        assert!(codes.contains("pending_user_op_missing_submitted_tx"));
    }
}
