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
pub const SERVICE_UNAVAILABLE: i64 = -32099;
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

    pub fn policy_cap_exceeded(field: &str) -> Self {
        Self {
            code: POLICY_CAP_EXCEEDED,
            message: "Policy cap exceeded".to_string(),
            data: Some(json!({ "field": field })),
        }
    }

    pub fn simulation_failed(reason: &str, revert_bytes: Option<&[u8]>) -> Self {
        let mut data = json!({ "reason": reason });
        if let Some(bytes) = revert_bytes {
            data["revertBytes"] = json!(format!("0x{}", hex::encode(bytes)));
        }
        Self {
            code: SIMULATION_FAILED,
            message: "Simulation failed".to_string(),
            data: Some(data),
        }
    }

    pub fn replacement_not_possible(reason: &str) -> Self {
        Self {
            code: REPLACEMENT_NOT_POSSIBLE,
            message: "Replacement not possible".to_string(),
            data: Some(json!({ "reason": reason })),
        }
    }

    pub fn apiversion_mismatch(current: u32, supported_minimum: u32) -> Self {
        Self {
            code: APIVERSION_MISMATCH,
            message: "API version mismatch".to_string(),
            data: Some(json!({
                "current": current,
                "supportedMinimum": supported_minimum,
            })),
        }
    }

    pub fn account_code_not_allowlisted(
        layer: &str,
        module_type: &str,
        address: &str,
        code_hash: &str,
    ) -> Self {
        Self {
            code: ACCOUNT_CODE_NOT_ALLOWLISTED,
            message: "Account code not allowlisted".to_string(),
            data: Some(json!({
                "layer": layer,
                "moduleType": module_type,
                "address": address,
                "codeHash": code_hash,
            })),
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
            SERVICE_UNAVAILABLE,
        ];

        assert_eq!(
            codes,
            [
                -32001, -32002, -32003, -32004, -32005, -32006, -32007, -32008, -32009, -32010,
                -32011, -32012, -32013, -32014, -32015, -32016, -32099,
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

    #[test]
    fn policy_cap_exceeded_serializes_field() {
        let err = JsonRpcError::policy_cap_exceeded("callGasLimit");
        let v = serde_json::to_value(&err).expect("serialize");
        assert_eq!(v["code"], -32006);
        assert_eq!(v["data"]["field"], "callGasLimit");
    }

    #[test]
    fn simulation_failed_serializes_reason_and_optional_revert_bytes() {
        let without = JsonRpcError::simulation_failed("AA23 reverted", None);
        let v = serde_json::to_value(&without).expect("serialize");
        assert_eq!(v["code"], -32007);
        assert_eq!(v["data"]["reason"], "AA23 reverted");
        assert!(v["data"].get("revertBytes").is_none());

        let with = JsonRpcError::simulation_failed("AA23 reverted", Some(&[0xab, 0xcd]));
        let v = serde_json::to_value(&with).expect("serialize");
        assert_eq!(v["data"]["revertBytes"], "0xabcd");
    }

    #[test]
    fn replacement_not_possible_serializes_reason() {
        let err = JsonRpcError::replacement_not_possible("nonce already mined");
        let v = serde_json::to_value(&err).expect("serialize");
        assert_eq!(v["code"], -32011);
        assert_eq!(v["data"]["reason"], "nonce already mined");
    }

    #[test]
    fn apiversion_mismatch_serializes_current_and_supported_minimum() {
        let err = JsonRpcError::apiversion_mismatch(2, 1);
        let v = serde_json::to_value(&err).expect("serialize");
        assert_eq!(v["code"], -32013);
        assert_eq!(v["data"]["current"], 2);
        assert_eq!(v["data"]["supportedMinimum"], 1);
    }

    #[test]
    fn account_code_not_allowlisted_serializes_full_shape() {
        let err = JsonRpcError::account_code_not_allowlisted(
            "implementation",
            "kernel_implementation_slot",
            "0xabc",
            "0xdef",
        );
        let v = serde_json::to_value(&err).expect("serialize");
        assert_eq!(v["code"], -32016);
        assert_eq!(v["data"]["layer"], "implementation");
        assert_eq!(v["data"]["moduleType"], "kernel_implementation_slot");
        assert_eq!(v["data"]["address"], "0xabc");
        assert_eq!(v["data"]["codeHash"], "0xdef");
    }

    #[test]
    fn data_shapes_are_stable() {
        // Pins the exact wire shape of `data` for each public error code.
        // Renumbering or restructuring `data` is a breaking change — this test
        // forces a deliberate decision rather than silent drift.
        let cases: &[(JsonRpcError, &str)] = &[
            (
                JsonRpcError::policy_cap_exceeded("callGasLimit"),
                r#"{"field":"callGasLimit"}"#,
            ),
            (
                JsonRpcError::replacement_not_possible("nonce already mined"),
                r#"{"reason":"nonce already mined"}"#,
            ),
            (
                JsonRpcError::apiversion_mismatch(1, 1),
                r#"{"current":1,"supportedMinimum":1}"#,
            ),
            (
                JsonRpcError::body_too_large(300_000),
                r#"{"actual":300000,"max":262144}"#,
            ),
        ];
        for (err, expected_data) in cases {
            let v = serde_json::to_value(err).expect("serialize");
            let data_str = serde_json::to_string(&v["data"]).expect("data json");
            assert_eq!(
                data_str, *expected_data,
                "data shape drift for code {}",
                v["code"]
            );
        }
    }
}
