use alloy_primitives::Address;
use serde_json::Value;

pub fn load() -> Value {
    serde_json::from_str(include_str!("../../testdata/permission/permission.json"))
        .expect("permission fixture is valid JSON")
}

pub fn hex_bytes(value: &str) -> Vec<u8> {
    hex::decode(value.strip_prefix("0x").unwrap_or(value)).expect("fixture hex is valid")
}

pub fn hex_array<const N: usize>(value: &str) -> [u8; N] {
    hex_bytes(value)
        .try_into()
        .unwrap_or_else(|_| panic!("fixture hex is not {N} bytes"))
}

pub fn meta_address(value: &Value, key: &str) -> Address {
    value["meta"][key]
        .as_str()
        .unwrap_or_else(|| panic!("fixture has meta address {key}"))
        .parse()
        .unwrap_or_else(|_| panic!("fixture meta {key} is an address"))
}
