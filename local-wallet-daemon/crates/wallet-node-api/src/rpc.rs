use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum JsonRpcId {
    Number(i64),
    String(String),
    Null,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcRequest {
    pub jsonrpc: String,
    pub method: String,
    #[serde(default)]
    pub params: serde_json::Value,
    pub id: JsonRpcId,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcError {
    pub code: i64,
    pub message: String,
    pub data: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcResponse {
    pub jsonrpc: String,
    pub id: JsonRpcId,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<JsonRpcError>,
}

impl JsonRpcResponse {
    pub fn ok(id: JsonRpcId, result: serde_json::Value) -> Self {
        Self {
            jsonrpc: "2.0".to_string(),
            id,
            result: Some(result),
            error: None,
        }
    }

    pub fn err(id: JsonRpcId, error: JsonRpcError) -> Self {
        Self {
            jsonrpc: "2.0".to_string(),
            id,
            result: None,
            error: Some(error),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    #[test]
    fn json_rpc_id_number_round_trips() {
        let id = JsonRpcId::Number(42);
        let serialized = serde_json::to_string(&id).expect("serialize id");
        let deserialized: JsonRpcId = serde_json::from_str(&serialized).expect("deserialize id");

        match deserialized {
            JsonRpcId::Number(value) => assert_eq!(value, 42),
            other => panic!("expected number id, got {other:?}"),
        }
    }

    #[test]
    fn json_rpc_id_string_round_trips() {
        let id = JsonRpcId::String("abc".to_string());
        let serialized = serde_json::to_string(&id).expect("serialize id");
        let deserialized: JsonRpcId = serde_json::from_str(&serialized).expect("deserialize id");

        match deserialized {
            JsonRpcId::String(value) => assert_eq!(value, "abc"),
            other => panic!("expected string id, got {other:?}"),
        }
    }

    #[test]
    fn json_rpc_id_null_round_trips() {
        let id = JsonRpcId::Null;
        let serialized = serde_json::to_string(&id).expect("serialize id");
        let deserialized: JsonRpcId = serde_json::from_str(&serialized).expect("deserialize id");

        match deserialized {
            JsonRpcId::Null => {}
            other => panic!("expected null id, got {other:?}"),
        }
    }

    #[test]
    fn request_missing_params_defaults_to_null() {
        let request: JsonRpcRequest = serde_json::from_value(json!({
            "jsonrpc": "2.0",
            "method": "wallet_health",
            "id": 1
        }))
        .expect("deserialize request");

        assert_eq!(request.params, Value::Null);
    }
}
