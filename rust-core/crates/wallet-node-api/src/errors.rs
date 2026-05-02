use crate::rpc::JsonRpcError;
use serde_json::json;

pub const PARSE_ERROR: i64 = -32700;
pub const INVALID_REQUEST: i64 = -32600;
pub const METHOD_NOT_FOUND: i64 = -32601;
pub const INTERNAL_ERROR: i64 = -32603;
pub const UNAUTHORIZED: i64 = -32001;
pub const NOT_READY: i64 = -32002;
pub const ENTRYPOINT_NOT_ALLOWLISTED: i64 = -32003;
pub const CHAIN_MISMATCH: i64 = -32004;
pub const RATE_LIMITED: i64 = -32005;
pub const POLICY_CAP_EXCEEDED: i64 = -32006;
pub const SIMULATION_FAILED: i64 = -32007;
pub const DUMMY_SIGNATURE_UNSUPPORTED: i64 = -32008;
pub const INSUFFICIENT_SMART_ACCOUNT_BALANCE: i64 = -32009;
pub const HELIOS_STALE: i64 = -32010;
pub const REPLACEMENT_NOT_POSSIBLE: i64 = -32011;
pub const BODY_TOO_LARGE: i64 = -32012;
pub const APIVERSION_MISMATCH: i64 = -32013;
pub const WITHDRAW_AMOUNT_EXCEEDS_RECLAIMABLE: i64 = -32014;
pub const HELIOS_STATE_OVERRIDE_UNSUPPORTED: i64 = -32015;
pub const ACCOUNT_CODE_NOT_ALLOWLISTED: i64 = -32016;
pub const MAX_REQUEST_BODY_BYTES: usize = 262_144;

impl JsonRpcError {
    pub fn method_not_found(method: &str) -> Self {
        Self {
            code: METHOD_NOT_FOUND,
            message: "Method not found".to_string(),
            data: Some(json!({ "method": method })),
        }
    }

    pub fn unauthorized() -> Self {
        Self {
            code: UNAUTHORIZED,
            message: "Unauthorized".to_string(),
            data: None,
        }
    }

    pub fn body_too_large(actual: usize) -> Self {
        Self::body_too_large_with_max(actual, MAX_REQUEST_BODY_BYTES)
    }

    pub fn body_too_large_with_max(actual: usize, max: usize) -> Self {
        Self {
            code: BODY_TOO_LARGE,
            message: "Request body too large".to_string(),
            data: Some(json!({
                "actual": actual,
                "max": max,
            })),
        }
    }

    pub fn parse_error(msg: &str) -> Self {
        Self {
            code: PARSE_ERROR,
            message: format!("Parse error: {}", msg),
            data: None,
        }
    }

    pub fn not_ready(reason: &str) -> Self {
        Self {
            code: NOT_READY,
            message: format!("Not ready: {}", reason),
            data: None,
        }
    }

    pub fn internal() -> Self {
        Self {
            code: INTERNAL_ERROR,
            message: "Internal error".to_string(),
            data: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wallet_node_error_namespace_is_complete_and_stable() {
        let codes = [
            UNAUTHORIZED,
            NOT_READY,
            ENTRYPOINT_NOT_ALLOWLISTED,
            CHAIN_MISMATCH,
            RATE_LIMITED,
            POLICY_CAP_EXCEEDED,
            SIMULATION_FAILED,
            DUMMY_SIGNATURE_UNSUPPORTED,
            INSUFFICIENT_SMART_ACCOUNT_BALANCE,
            HELIOS_STALE,
            REPLACEMENT_NOT_POSSIBLE,
            BODY_TOO_LARGE,
            APIVERSION_MISMATCH,
            WITHDRAW_AMOUNT_EXCEEDS_RECLAIMABLE,
            HELIOS_STATE_OVERRIDE_UNSUPPORTED,
            ACCOUNT_CODE_NOT_ALLOWLISTED,
        ];

        assert_eq!(
            codes,
            [
                -32001, -32002, -32003, -32004, -32005, -32006, -32007, -32008, -32009, -32010,
                -32011, -32012, -32013, -32014, -32015, -32016,
            ]
        );
    }

    #[test]
    fn body_too_large_serializes_actual_and_max() {
        let serialized =
            serde_json::to_value(JsonRpcError::body_too_large(300_000)).expect("serialize error");
        let data = serialized
            .get("data")
            .expect("data field")
            .as_object()
            .expect("data object");

        assert_eq!(data.get("actual").expect("actual"), 300_000);
        assert_eq!(data.get("max").expect("max"), 262_144);
    }
}
