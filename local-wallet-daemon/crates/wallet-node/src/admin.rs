use std::{collections::BTreeSet, path::PathBuf};

use bytes::Bytes;
use clap::{Args, Subcommand, ValueEnum};
use serde_json::{json, Value};
use thiserror::Error;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

#[derive(Debug, Args)]
pub struct AdminArgs {
    #[arg(long, value_name = "URL", conflicts_with = "socket")]
    pub http: Option<String>,

    #[arg(long, value_name = "PATH", conflicts_with = "http")]
    pub socket: Option<PathBuf>,

    #[arg(long, conflicts_with = "token_file")]
    pub token: Option<String>,

    #[arg(long, value_name = "PATH", conflicts_with = "token")]
    pub token_file: Option<PathBuf>,

    #[arg(long)]
    pub json: bool,

    #[command(subcommand)]
    pub command: AdminCommand,
}

#[derive(Debug, Subcommand)]
pub(crate) enum AdminCommand {
    Audit(AdminAuditArgs),
    AuditHistory(AdminAuditHistoryArgs),
    AuditReport(AdminAuditReportArgs),
    Repair(AdminRepairArgs),
    Pending,
}

#[derive(Debug, Args)]
pub(crate) struct AdminAuditArgs {
    #[arg(long)]
    pub persist: bool,
}

#[derive(Debug, Args)]
pub(crate) struct AdminAuditHistoryArgs {
    #[arg(long, default_value_t = 20)]
    pub limit: u64,
}

#[derive(Debug, Args)]
pub(crate) struct AdminAuditReportArgs {
    #[arg(long)]
    pub run_id: i64,
}

#[derive(Debug, Args)]
pub(crate) struct AdminRepairArgs {
    #[arg(long, value_enum)]
    pub action: AdminRepairAction,

    #[arg(long)]
    pub tx_hash: Option<String>,

    #[arg(long)]
    pub user_op_hash: Option<String>,

    #[arg(long)]
    pub chain_id: Option<u64>,

    #[arg(long)]
    pub bundler_address: Option<String>,

    #[arg(long)]
    pub nonce: Option<u64>,

    #[arg(long, conflicts_with = "dry_run")]
    pub confirm: bool,

    #[arg(long)]
    pub dry_run: bool,

    #[arg(long)]
    pub verify_after_repair: bool,
}

#[derive(Clone, Debug, ValueEnum)]
pub(crate) enum AdminRepairAction {
    MarkSubmittedTxFailed,
    AbandonNonceReservation,
    ClearTentativeReceipt,
    MarkTxDropped,
    RebuildUserOpFromReceipt,
    RebuildReceiptFromChain,
}

#[derive(Debug, Error)]
pub(crate) enum AdminError {
    #[error("admin command requires --http or --socket")]
    MissingEndpoint,

    #[error("admin command requires --token or --token-file")]
    MissingToken,

    #[error("repair command requires an exact subject for the selected action")]
    MissingRepairSubject,

    #[error("admin HTTP endpoint must be an http:// URL")]
    InvalidHttpEndpoint,

    #[error("admin token file read failed: {0}")]
    TokenFile(std::io::Error),

    #[error("admin transport failed: {0}")]
    Transport(std::io::Error),

    #[error("admin response was not valid UTF-8 or JSON")]
    InvalidResponse,
}

pub(crate) async fn run(args: &AdminArgs) -> Result<(), AdminError> {
    let token = read_token(args)?;
    let request = build_admin_request(args)?;
    let body = serde_json::to_vec(&request).map_err(|_| AdminError::InvalidResponse)?;
    let response = if let Some(http) = args.http.as_deref() {
        send_http(http, &token, &body).await?
    } else if let Some(socket) = args.socket.as_ref() {
        send_unix(socket, &token, &body).await?
    } else {
        return Err(AdminError::MissingEndpoint);
    };
    let value = parse_http_json_response(&response)?;
    print_admin_response(&value, args.json);
    Ok(())
}

pub(crate) fn build_admin_request(args: &AdminArgs) -> Result<Value, AdminError> {
    if args.http.is_none() && args.socket.is_none() {
        return Err(AdminError::MissingEndpoint);
    }
    if args.token.is_none() && args.token_file.is_none() {
        return Err(AdminError::MissingToken);
    }

    let (method, params) = match &args.command {
        AdminCommand::Audit(audit) => ("wallet_auditStore", json!([{ "persist": audit.persist }])),
        AdminCommand::AuditHistory(history) => {
            ("wallet_auditHistory", json!([{ "limit": history.limit }]))
        }
        AdminCommand::AuditReport(report) => {
            ("wallet_auditReport", json!([{ "runId": report.run_id }]))
        }
        AdminCommand::Repair(repair) => {
            validate_repair_subject(repair)?;
            let mut body = serde_json::Map::new();
            body.insert("action".to_string(), json!(repair.action.as_wire()));
            body.insert("confirm".to_string(), json!(repair.confirm));
            body.insert(
                "verifyAfterRepair".to_string(),
                json!(repair.verify_after_repair),
            );
            if let Some(value) = &repair.tx_hash {
                body.insert("txHash".to_string(), json!(value));
            }
            if let Some(value) = &repair.user_op_hash {
                body.insert("userOpHash".to_string(), json!(value));
            }
            if let Some(value) = repair.chain_id {
                body.insert("chainId".to_string(), json!(value));
            }
            if let Some(value) = &repair.bundler_address {
                body.insert("bundlerAddress".to_string(), json!(value));
            }
            if let Some(value) = repair.nonce {
                body.insert("nonce".to_string(), json!(value));
            }
            (
                "wallet_repairStore",
                Value::Array(vec![Value::Object(body)]),
            )
        }
        AdminCommand::Pending => ("wallet_pendingOperations", json!([])),
    };

    Ok(json!({
        "jsonrpc": "2.0",
        "method": method,
        "params": params,
        "id": 1,
    }))
}

pub(crate) fn render_admin_table(value: &Value) -> String {
    if let Some(result) = value.get("result") {
        if let Some(items) = result.as_array() {
            if let Some(table) = render_object_table(items) {
                return table;
            }
            return items
                .iter()
                .map(compact_json)
                .collect::<Vec<_>>()
                .join("\n");
        }
        return compact_json(result);
    }
    compact_json(value)
}

fn render_object_table(items: &[Value]) -> Option<String> {
    let objects = items
        .iter()
        .map(Value::as_object)
        .collect::<Option<Vec<_>>>()?;
    let columns = objects
        .iter()
        .flat_map(|object| object.keys())
        .cloned()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect::<Vec<_>>();
    if columns.is_empty() {
        return Some(String::new());
    }

    let rows = objects
        .iter()
        .map(|object| {
            columns
                .iter()
                .map(|column| {
                    object
                        .get(column)
                        .map(table_cell)
                        .unwrap_or_else(String::new)
                })
                .collect::<Vec<_>>()
        })
        .collect::<Vec<_>>();
    let widths = columns
        .iter()
        .enumerate()
        .map(|(index, column)| {
            rows.iter()
                .map(|row| row[index].len())
                .max()
                .unwrap_or(0)
                .max(column.len())
        })
        .collect::<Vec<_>>();

    let mut lines = Vec::with_capacity(rows.len() + 1);
    lines.push(format_table_row(&columns, &widths));
    lines.extend(rows.iter().map(|row| format_table_row(row, &widths)));
    Some(lines.join("\n"))
}

fn table_cell(value: &Value) -> String {
    match value {
        Value::Null => String::new(),
        Value::String(value) => value.clone(),
        Value::Bool(value) => value.to_string(),
        Value::Number(value) => value.to_string(),
        _ => compact_json(value),
    }
}

fn format_table_row(row: &[String], widths: &[usize]) -> String {
    row.iter()
        .enumerate()
        .map(|(index, value)| format!("{value:<width$}", width = widths[index]))
        .collect::<Vec<_>>()
        .join(" | ")
        .trim_end()
        .to_string()
}

fn validate_repair_subject(repair: &AdminRepairArgs) -> Result<(), AdminError> {
    let ok = match repair.action {
        AdminRepairAction::MarkSubmittedTxFailed | AdminRepairAction::MarkTxDropped => {
            repair.tx_hash.is_some()
        }
        AdminRepairAction::ClearTentativeReceipt
        | AdminRepairAction::RebuildUserOpFromReceipt
        | AdminRepairAction::RebuildReceiptFromChain => repair.user_op_hash.is_some(),
        AdminRepairAction::AbandonNonceReservation => {
            repair.bundler_address.is_some() && repair.nonce.is_some()
        }
    };
    if ok {
        Ok(())
    } else {
        Err(AdminError::MissingRepairSubject)
    }
}

fn read_token(args: &AdminArgs) -> Result<String, AdminError> {
    if let Some(token) = args.token.as_ref() {
        return Ok(token.clone());
    }
    let Some(path) = args.token_file.as_ref() else {
        return Err(AdminError::MissingToken);
    };
    std::fs::read_to_string(path)
        .map(|value| value.trim().to_string())
        .map_err(AdminError::TokenFile)
}

async fn send_http(endpoint: &str, token: &str, body: &[u8]) -> Result<Bytes, AdminError> {
    let uri = endpoint
        .parse::<hyper::Uri>()
        .map_err(|_| AdminError::InvalidHttpEndpoint)?;
    if uri.scheme_str() != Some("http") {
        return Err(AdminError::InvalidHttpEndpoint);
    }
    let authority = uri
        .authority()
        .ok_or(AdminError::InvalidHttpEndpoint)?
        .to_string();
    let path = uri
        .path_and_query()
        .map(|path| path.as_str())
        .unwrap_or("/");
    let mut stream = tokio::net::TcpStream::connect(&authority)
        .await
        .map_err(AdminError::Transport)?;
    write_http_request(&mut stream, &authority, path, token, body).await?;
    read_http_response(&mut stream).await
}

async fn send_unix(path: &PathBuf, token: &str, body: &[u8]) -> Result<Bytes, AdminError> {
    let mut stream = tokio::net::UnixStream::connect(path)
        .await
        .map_err(AdminError::Transport)?;
    write_http_request(&mut stream, "localhost", "/", token, body).await?;
    read_http_response(&mut stream).await
}

async fn write_http_request<S>(
    stream: &mut S,
    host: &str,
    path: &str,
    token: &str,
    body: &[u8],
) -> Result<(), AdminError>
where
    S: AsyncWrite + Unpin,
{
    let header = format!(
        "POST {path} HTTP/1.1\r\nHost: {host}\r\nContent-Type: application/json\r\nAuthorization: Bearer {token}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream
        .write_all(header.as_bytes())
        .await
        .map_err(AdminError::Transport)?;
    stream
        .write_all(body)
        .await
        .map_err(AdminError::Transport)?;
    Ok(())
}

async fn read_http_response<S>(stream: &mut S) -> Result<Bytes, AdminError>
where
    S: AsyncRead + Unpin,
{
    let mut response = Vec::new();
    stream
        .read_to_end(&mut response)
        .await
        .map_err(AdminError::Transport)?;
    Ok(Bytes::from(response))
}

fn parse_http_json_response(response: &[u8]) -> Result<Value, AdminError> {
    let split = response
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .ok_or(AdminError::InvalidResponse)?
        + 4;
    serde_json::from_slice(&response[split..]).map_err(|_| AdminError::InvalidResponse)
}

fn print_admin_response(value: &Value, json_output: bool) {
    if json_output {
        println!(
            "{}",
            serde_json::to_string_pretty(value).unwrap_or_else(|_| "{}".to_string())
        );
    } else {
        println!("{}", render_admin_table(value));
    }
}

fn compact_json(value: &Value) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "{}".to_string())
}

impl AdminRepairAction {
    fn as_wire(&self) -> &'static str {
        match self {
            Self::MarkSubmittedTxFailed => "markSubmittedTxFailed",
            Self::AbandonNonceReservation => "abandonNonceReservation",
            Self::ClearTentativeReceipt => "clearTentativeReceipt",
            Self::MarkTxDropped => "markTxDropped",
            Self::RebuildUserOpFromReceipt => "rebuildUserOpFromReceipt",
            Self::RebuildReceiptFromChain => "rebuildReceiptFromChain",
        }
    }
}

#[cfg(test)]
mod tests {
    use clap::Parser;

    use crate::cli::{Cli, CliCommand};

    use super::*;

    fn admin(args: &[&str]) -> AdminArgs {
        let cli = Cli::try_parse_from(args).unwrap();
        match cli.command.unwrap() {
            CliCommand::Admin(admin) => admin,
        }
    }

    #[test]
    fn admin_audit_request_shape_includes_persist() {
        let args = admin(&[
            "wallet-node",
            "admin",
            "--http",
            "http://127.0.0.1:1234",
            "--token",
            "secret",
            "audit",
            "--persist",
        ]);

        let request = build_admin_request(&args).unwrap();

        assert_eq!(request["method"], "wallet_auditStore");
        assert_eq!(request["params"][0]["persist"], true);
    }

    #[test]
    fn admin_repair_request_defaults_to_dry_run() {
        let args = admin(&[
            "wallet-node",
            "admin",
            "--socket",
            "/tmp/wallet.sock",
            "--token",
            "secret",
            "repair",
            "--action",
            "mark-submitted-tx-failed",
            "--tx-hash",
            "0xtx",
        ]);

        let request = build_admin_request(&args).unwrap();

        assert_eq!(request["method"], "wallet_repairStore");
        assert_eq!(request["params"][0]["confirm"], false);
        assert_eq!(request["params"][0]["txHash"], "0xtx");
    }

    #[test]
    fn admin_repair_requires_exact_subject() {
        let args = admin(&[
            "wallet-node",
            "admin",
            "--http",
            "http://127.0.0.1:1234",
            "--token",
            "secret",
            "repair",
            "--action",
            "mark-submitted-tx-failed",
        ]);

        assert!(matches!(
            build_admin_request(&args),
            Err(AdminError::MissingRepairSubject)
        ));
    }

    #[test]
    fn admin_pending_request_shape() {
        let args = admin(&[
            "wallet-node",
            "admin",
            "--http",
            "http://127.0.0.1:1234",
            "--token",
            "secret",
            "pending",
        ]);

        let request = build_admin_request(&args).unwrap();

        assert_eq!(request["method"], "wallet_pendingOperations");
    }

    #[test]
    fn admin_audit_history_request_shape() {
        let args = admin(&[
            "wallet-node",
            "admin",
            "--http",
            "http://127.0.0.1:1234",
            "--token",
            "secret",
            "audit-history",
            "--limit",
            "7",
        ]);

        let request = build_admin_request(&args).unwrap();

        assert_eq!(request["method"], "wallet_auditHistory");
        assert_eq!(request["params"][0]["limit"], 7);
    }

    #[test]
    fn admin_audit_report_request_shape() {
        let args = admin(&[
            "wallet-node",
            "admin",
            "--http",
            "http://127.0.0.1:1234",
            "--token",
            "secret",
            "audit-report",
            "--run-id",
            "42",
        ]);

        let request = build_admin_request(&args).unwrap();

        assert_eq!(request["method"], "wallet_auditReport");
        assert_eq!(request["params"][0]["runId"], 42);
    }

    #[test]
    fn admin_requires_endpoint_and_token_source() {
        let missing_endpoint = admin(&["wallet-node", "admin", "--token", "secret", "pending"]);
        let missing_token = admin(&[
            "wallet-node",
            "admin",
            "--http",
            "http://127.0.0.1:1234",
            "pending",
        ]);

        assert!(matches!(
            build_admin_request(&missing_endpoint),
            Err(AdminError::MissingEndpoint)
        ));
        assert!(matches!(
            build_admin_request(&missing_token),
            Err(AdminError::MissingToken)
        ));
    }

    #[test]
    fn admin_json_flag_parses() {
        let args = admin(&[
            "wallet-node",
            "admin",
            "--http",
            "http://127.0.0.1:1234",
            "--token",
            "secret",
            "--json",
            "pending",
        ]);

        assert!(args.json);
    }

    #[test]
    fn admin_table_rendering_is_stable() {
        let rendered = render_admin_table(&json!({
            "result": [
                { "code": "one", "severity": "warning" },
                { "code": "two", "severity": "error" }
            ]
        }));

        assert_eq!(
            rendered,
            "code | severity\none  | warning\ntwo  | error".to_string()
        );
    }

    #[test]
    fn admin_errors_do_not_print_token() {
        let err = AdminError::MissingEndpoint.to_string();

        assert!(!err.contains("secret"));
        assert!(!err.contains("Bearer"));
    }
}
