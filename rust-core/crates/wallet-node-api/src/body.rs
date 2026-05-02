use crate::errors::{INVALID_REQUEST, MAX_REQUEST_BODY_BYTES};
use crate::rpc::{JsonRpcError, JsonRpcRequest};

pub fn parse_body(bytes: &[u8]) -> Result<JsonRpcRequest, JsonRpcError> {
    parse_body_with_max(bytes, MAX_REQUEST_BODY_BYTES)
}

pub fn parse_body_with_max(bytes: &[u8], max: usize) -> Result<JsonRpcRequest, JsonRpcError> {
    if bytes.len() > max {
        return Err(JsonRpcError::body_too_large_with_max(bytes.len(), max));
    }

    serde_json::from_slice::<JsonRpcRequest>(bytes).map_err(|e| JsonRpcError {
        code: INVALID_REQUEST,
        message: format!("Invalid request: {}", e),
        data: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::errors::{BODY_TOO_LARGE, MAX_REQUEST_BODY_BYTES};

    fn padded_wallet_health_payload(len: usize) -> Vec<u8> {
        let prefix = br#"{"jsonrpc":"2.0","method":"wallet_health","params":{"padding":""#;
        let suffix = br#""},"id":1}"#;
        let padding_len = len
            .checked_sub(prefix.len() + suffix.len())
            .expect("requested payload length should fit fixed JSON");

        let mut payload = Vec::with_capacity(len);
        payload.extend_from_slice(prefix);
        payload.extend(std::iter::repeat(b'a').take(padding_len));
        payload.extend_from_slice(suffix);
        payload
    }

    #[test]
    fn oversized_payload_returns_body_too_large() {
        let payload = vec![b' '; 300_001];
        let error = parse_body(&payload).expect_err("oversized payload should fail");

        assert_eq!(error.code, BODY_TOO_LARGE);
    }

    #[test]
    fn valid_json_rpc_payload_returns_ok() {
        let payload = br#"{"jsonrpc":"2.0","method":"wallet_health","params":null,"id":1}"#;
        let request = parse_body(payload).expect("valid payload");

        assert_eq!(request.jsonrpc, "2.0");
        assert_eq!(request.method, "wallet_health");
    }

    #[test]
    fn exactly_max_bytes_succeeds() {
        let payload = padded_wallet_health_payload(MAX_REQUEST_BODY_BYTES);
        assert_eq!(payload.len(), MAX_REQUEST_BODY_BYTES);

        let request = parse_body(&payload).expect("max-sized valid payload should parse");

        assert_eq!(request.jsonrpc, "2.0");
        assert_eq!(request.method, "wallet_health");
    }

    #[test]
    fn exactly_max_plus_one_fails_with_body_too_large() {
        let payload = padded_wallet_health_payload(MAX_REQUEST_BODY_BYTES + 1);
        let error = parse_body(&payload).expect_err("payload one byte over max should fail");

        assert_eq!(error.code, BODY_TOO_LARGE);
    }

    #[test]
    fn custom_max_is_used_for_body_too_large_error() {
        let payload = padded_wallet_health_payload(256);
        let error =
            parse_body_with_max(&payload, 128).expect_err("payload over custom max should fail");

        assert_eq!(error.code, BODY_TOO_LARGE);
        assert_eq!(error.data.expect("error data")["max"], 128);
    }

    #[test]
    fn malformed_json_returns_invalid_request() {
        let error = parse_body(br#"{"jsonrpc":"2.0","#).expect_err("malformed json should fail");

        assert_eq!(error.code, INVALID_REQUEST);
    }

    #[test]
    fn empty_body_documents_behavior() {
        let error = parse_body(b"").expect_err("empty body should fail");

        assert_eq!(error.code, INVALID_REQUEST);
    }

    #[test]
    fn non_json_body_fails_with_invalid_request() {
        let error = parse_body(b"this is not json").expect_err("non-json body should fail");

        assert_eq!(error.code, INVALID_REQUEST);
    }

    #[test]
    fn missing_jsonrpc_field_returns_invalid_request() {
        let payload = br#"{"method":"wallet_health","params":null,"id":1}"#;
        let error = parse_body(payload).expect_err("missing jsonrpc should fail");

        assert_eq!(error.code, INVALID_REQUEST);
    }

    #[test]
    fn parse_body_rejects_batch_request() {
        let payload = br#"[{"jsonrpc":"2.0","method":"eth_chainId","id":1}]"#;
        let error = parse_body(payload).expect_err("batch request should fail");

        assert_eq!(error.code, INVALID_REQUEST);
    }

    #[test]
    fn parse_body_rejects_notification() {
        let payload = br#"{"jsonrpc":"2.0","method":"eth_chainId"}"#;
        let error = parse_body(payload).expect_err("notification should fail");

        assert_eq!(error.code, INVALID_REQUEST);
    }
}
