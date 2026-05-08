use serde_json::Value;

use crate::state::DaemonState;

pub fn handle(state: &DaemonState) -> Value {
    Value::String(format!("0x{:x}", state.config.network.chain_id))
}
