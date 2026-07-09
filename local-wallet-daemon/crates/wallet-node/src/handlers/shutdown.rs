use serde_json::{json, Value};

use crate::state::DaemonState;

pub async fn handle(state: &DaemonState) -> Value {
    if let Err(err) = state.shutdown_tx.send(true) {
        tracing::warn!("failed to signal wallet-node shutdown: {err}");
    }

    json!({ "ok": true })
}
