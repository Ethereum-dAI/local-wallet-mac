use serde_json::{json, Value};

pub fn handle_api_version() -> Value {
    json!({
        "current": wallet_node_api::API_VERSION,
        "supportedMinimum": wallet_node_api::SUPPORTED_MINIMUM_API_VERSION,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn returns_current_and_supported_minimum() {
        let value = handle_api_version();
        let object = value
            .as_object()
            .expect("api version response is an object");

        assert_eq!(object.len(), 2);
        assert_eq!(
            value["current"].as_u64(),
            Some(u64::from(wallet_node_api::API_VERSION))
        );
        assert_eq!(
            value["supportedMinimum"].as_u64(),
            Some(u64::from(wallet_node_api::SUPPORTED_MINIMUM_API_VERSION))
        );
    }
}
