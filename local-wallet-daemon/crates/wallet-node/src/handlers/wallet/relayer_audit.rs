use wallet_node_store::{BundlerAccount, RelayerKeyAuditEvent};

use crate::state::DaemonState;

pub(crate) async fn record(
    state: &DaemonState,
    event_type: &str,
    account: &BundlerAccount,
    admin_action_id: Option<&str>,
    result: &str,
    failure_reason: Option<&str>,
) -> Result<(), wallet_node_api::JsonRpcError> {
    state
        .store
        .relayer_key_audit_insert(RelayerKeyAuditEvent {
            id: None,
            event_type: event_type.to_string(),
            owner_scope: account.owner_scope.clone(),
            chain_id: account.chain_id,
            key_ref: Some(account.key_ref.clone()),
            address: Some(account.address.clone()),
            previous_lifecycle: None,
            new_lifecycle: Some(account.lifecycle.as_str().to_string()),
            admin_action_id: admin_action_id.map(str::to_string),
            result: result.to_string(),
            failure_reason: failure_reason.map(str::to_string),
            created_at: now_unix_seconds(),
        })
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())
}

fn now_unix_seconds() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}
