use serde::de::{Error as DeError, MapAccess, Visitor};
use serde::ser::SerializeMap;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::collections::BTreeMap;
use std::fmt;

pub use alloy_primitives::{Address, Bytes, B256, U256};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum BlockTag {
    Latest,
    Finalized,
    Earliest,
    Number(u64),
    Hash(B256),
}

impl Serialize for BlockTag {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        match self {
            Self::Latest => serializer.serialize_str("latest"),
            Self::Finalized => serializer.serialize_str("finalized"),
            Self::Earliest => serializer.serialize_str("earliest"),
            Self::Number(number) => serializer.serialize_str(&format!("0x{number:x}")),
            Self::Hash(hash) => {
                let mut map = serializer.serialize_map(Some(1))?;
                map.serialize_entry("blockHash", &format!("{hash:#x}"))?;
                map.end()
            }
        }
    }
}

impl<'de> Deserialize<'de> for BlockTag {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        deserializer.deserialize_any(BlockTagVisitor)
    }
}

struct BlockTagVisitor;

impl<'de> Visitor<'de> for BlockTagVisitor {
    type Value = BlockTag;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .write_str("a block tag string, hex block number, block hash, or EIP-1898 block object")
    }

    fn visit_str<E>(self, value: &str) -> Result<Self::Value, E>
    where
        E: DeError,
    {
        parse_block_tag_str(value)
    }

    fn visit_string<E>(self, value: String) -> Result<Self::Value, E>
    where
        E: DeError,
    {
        self.visit_str(&value)
    }

    fn visit_u64<E>(self, value: u64) -> Result<Self::Value, E>
    where
        E: DeError,
    {
        Ok(BlockTag::Number(value))
    }

    fn visit_map<A>(self, mut map: A) -> Result<Self::Value, A::Error>
    where
        A: MapAccess<'de>,
    {
        let mut block_hash = None;
        let mut block_number = None;

        while let Some(key) = map.next_key::<String>()? {
            match key.as_str() {
                "blockHash" => {
                    block_hash = Some(parse_block_hash_str(&map.next_value::<String>()?)?)
                }
                "blockNumber" => {
                    let value = map.next_value::<serde_json::Value>()?;
                    block_number = Some(parse_block_number_value(value)?);
                }
                _ => {
                    let _ = map.next_value::<serde_json::Value>()?;
                }
            }
        }

        match (block_hash, block_number) {
            (Some(hash), None) => Ok(BlockTag::Hash(hash)),
            (None, Some(number)) => Ok(BlockTag::Number(number)),
            (Some(_), Some(_)) => Err(DeError::custom(
                "block object cannot contain both blockHash and blockNumber",
            )),
            (None, None) => Err(DeError::custom(
                "block object must contain blockHash or blockNumber",
            )),
        }
    }
}

fn parse_block_tag_str<E>(value: &str) -> Result<BlockTag, E>
where
    E: DeError,
{
    match value {
        "latest" => Ok(BlockTag::Latest),
        "finalized" => Ok(BlockTag::Finalized),
        "earliest" => Ok(BlockTag::Earliest),
        value if value.starts_with("0x") && value.len() == 66 => value
            .parse::<B256>()
            .map(BlockTag::Hash)
            .map_err(|error| DeError::custom(format!("invalid block hash: {error}"))),
        value if value.starts_with("0x") => u64::from_str_radix(&value[2..], 16)
            .map(BlockTag::Number)
            .map_err(|error| DeError::custom(format!("invalid block number: {error}"))),
        _ => Err(DeError::custom(format!("unsupported block tag: {value}"))),
    }
}

fn parse_block_hash_str<E>(value: &str) -> Result<B256, E>
where
    E: DeError,
{
    value
        .parse::<B256>()
        .map_err(|error| DeError::custom(format!("invalid block hash: {error}")))
}

fn parse_block_number_value<E>(value: serde_json::Value) -> Result<u64, E>
where
    E: DeError,
{
    match value {
        serde_json::Value::String(value) => match parse_block_tag_str::<E>(&value)? {
            BlockTag::Number(number) => Ok(number),
            _ => Err(DeError::custom("blockNumber must be a hex quantity")),
        },
        serde_json::Value::Number(number) => number
            .as_u64()
            .ok_or_else(|| DeError::custom("blockNumber must fit in u64")),
        _ => Err(DeError::custom("blockNumber must be a string or integer")),
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CallRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<Address>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub to: Option<Address>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gas: Option<U256>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gas_price: Option<U256>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_fee_per_gas: Option<U256>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_priority_fee_per_gas: Option<U256>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<U256>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<Bytes>,
    #[serde(
        default,
        with = "quantity_u64::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub nonce: Option<u64>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountOverride {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub balance: Option<U256>,
    #[serde(
        default,
        with = "quantity_u64::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub nonce: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<Bytes>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state: Option<BTreeMap<B256, B256>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state_diff: Option<BTreeMap<B256, B256>>,
}

pub type StateOverride = BTreeMap<Address, AccountOverride>;

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TransactionReceipt {
    pub transaction_hash: B256,
    #[serde(
        default,
        with = "quantity_u64::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub transaction_index: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub block_hash: Option<B256>,
    #[serde(
        default,
        with = "quantity_u64::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub block_number: Option<u64>,
    pub from: Address,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub to: Option<Address>,
    #[serde(with = "quantity_u64")]
    pub cumulative_gas_used: u64,
    #[serde(
        default,
        with = "quantity_u64::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub gas_used: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub contract_address: Option<Address>,
    #[serde(default)]
    pub logs: Vec<Log>,
    #[serde(
        default,
        with = "quantity_u64::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub status: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effective_gas_price: Option<U256>,
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Log {
    pub address: Address,
    #[serde(default)]
    pub topics: Vec<B256>,
    pub data: Bytes,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub block_hash: Option<B256>,
    #[serde(
        default,
        with = "quantity_u64::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub block_number: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transaction_hash: Option<B256>,
    #[serde(
        default,
        with = "quantity_u64::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub transaction_index: Option<u64>,
    #[serde(
        default,
        with = "quantity_u64::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub log_index: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub removed: Option<bool>,
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Block {
    #[serde(flatten)]
    pub header: BlockHeader,
    #[serde(default)]
    pub transactions: Vec<BlockTransaction>,
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum BlockTransaction {
    Hash(B256),
    Full(Transaction),
}

impl Serialize for BlockTransaction {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        match self {
            Self::Hash(hash) => serializer.serialize_str(&format!("{hash:#x}")),
            Self::Full(transaction) => transaction.serialize(serializer),
        }
    }
}

impl<'de> Deserialize<'de> for BlockTransaction {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = serde_json::Value::deserialize(deserializer)?;
        if let Some(hash) = value.as_str() {
            return parse_block_hash_str(hash).map(Self::Hash);
        }
        serde_json::from_value(value)
            .map(Self::Full)
            .map_err(|error| DeError::custom(format!("invalid transaction object: {error}")))
    }
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Transaction {
    pub hash: B256,
    #[serde(
        default,
        with = "quantity_u64::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub nonce: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub block_hash: Option<B256>,
    #[serde(
        default,
        with = "quantity_u64::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub block_number: Option<u64>,
    #[serde(
        default,
        with = "quantity_u64::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub transaction_index: Option<u64>,
    pub from: Address,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub to: Option<Address>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<U256>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input: Option<Bytes>,
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BlockHeader {
    #[serde(with = "quantity_u64")]
    pub number: u64,
    pub hash: B256,
    pub parent_hash: B256,
    #[serde(with = "quantity_u64")]
    pub timestamp: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state_root: Option<B256>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transactions_root: Option<B256>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub receipts_root: Option<B256>,
    #[serde(
        default,
        with = "quantity_u64::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub gas_used: Option<u64>,
    #[serde(
        default,
        with = "quantity_u64::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub gas_limit: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_fee_per_gas: Option<U256>,
}

mod quantity_u64 {
    use serde::de::Error as DeError;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S>(value: &u64, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&format!("0x{value:x}"))
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<u64, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = serde_json::Value::deserialize(deserializer)?;
        parse_value(value)
    }

    fn parse_value<E>(value: serde_json::Value) -> Result<u64, E>
    where
        E: DeError,
    {
        match value {
            serde_json::Value::String(value) => {
                let value = value
                    .strip_prefix("0x")
                    .ok_or_else(|| DeError::custom("quantity must start with 0x"))?;
                if value.is_empty() {
                    return Ok(0);
                }
                u64::from_str_radix(value, 16)
                    .map_err(|error| DeError::custom(format!("invalid hex quantity: {error}")))
            }
            serde_json::Value::Number(value) => value
                .as_u64()
                .ok_or_else(|| DeError::custom("quantity must fit in u64")),
            _ => Err(DeError::custom("quantity must be a hex string or number")),
        }
    }

    pub mod option {
        use super::{parse_value, serialize as serialize_quantity};
        use serde::{Deserialize, Deserializer, Serializer};

        pub fn serialize<S>(value: &Option<u64>, serializer: S) -> Result<S::Ok, S::Error>
        where
            S: Serializer,
        {
            match value {
                Some(value) => serialize_quantity(value, serializer),
                None => serializer.serialize_none(),
            }
        }

        pub fn deserialize<'de, D>(deserializer: D) -> Result<Option<u64>, D::Error>
        where
            D: Deserializer<'de>,
        {
            Option::<serde_json::Value>::deserialize(deserializer)?
                .map(parse_value)
                .transpose()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn block_tag_serializes_standard_tags_and_numbers() {
        assert_eq!(
            serde_json::to_value(BlockTag::Latest).unwrap(),
            json!("latest")
        );
        assert_eq!(
            serde_json::to_value(BlockTag::Number(26)).unwrap(),
            json!("0x1a")
        );
    }

    #[test]
    fn block_tag_serializes_hash_as_eip1898_object() {
        let hash = B256::from([7; 32]);
        assert_eq!(
            serde_json::to_value(BlockTag::Hash(hash)).unwrap(),
            json!({ "blockHash": format!("{hash:#x}") })
        );
    }

    #[test]
    fn block_tag_deserializes_hash_and_number_objects() {
        let hash = B256::from([9; 32]);
        assert_eq!(
            serde_json::from_value::<BlockTag>(json!({ "blockHash": format!("{hash:#x}") }))
                .unwrap(),
            BlockTag::Hash(hash)
        );
        assert_eq!(
            serde_json::from_value::<BlockTag>(json!({ "blockNumber": "0x2a" })).unwrap(),
            BlockTag::Number(42)
        );
    }

    #[test]
    fn call_request_uses_camel_case_fields() {
        let request = CallRequest {
            max_fee_per_gas: Some(U256::from(1)),
            max_priority_fee_per_gas: Some(U256::from(2)),
            ..CallRequest::default()
        };

        let value = serde_json::to_value(request).unwrap();
        assert!(value.get("maxFeePerGas").is_some());
        assert!(value.get("maxPriorityFeePerGas").is_some());
    }

    #[test]
    fn call_request_uses_ethereum_hex_wire_shapes() {
        let request = CallRequest {
            from: Some(Address::from([0x11; 20])),
            to: Some(Address::from([0x22; 20])),
            value: Some(U256::from(26)),
            data: Some(Bytes::from_static(&[0xab, 0xcd])),
            nonce: Some(15),
            ..CallRequest::default()
        };

        let value = serde_json::to_value(request).unwrap();
        assert_eq!(
            value,
            json!({
                "from": "0x1111111111111111111111111111111111111111",
                "to": "0x2222222222222222222222222222222222222222",
                "value": "0x1a",
                "data": "0xabcd",
                "nonce": "0xf",
            })
        );
    }

    #[test]
    fn block_header_uses_ethereum_hex_quantity_wire_shapes() {
        let hash = B256::from([0x55; 32]);
        let parent_hash = B256::from([0x66; 32]);
        let header = BlockHeader {
            number: 26,
            hash,
            parent_hash,
            timestamp: 1234,
            state_root: None,
            transactions_root: None,
            receipts_root: None,
            gas_used: Some(21_000),
            gas_limit: Some(60_000_000),
            base_fee_per_gas: Some(U256::from(7)),
        };

        let encoded = serde_json::to_value(&header).unwrap();
        assert_eq!(
            encoded,
            json!({
                "number": "0x1a",
                "hash": format!("{hash:#x}"),
                "parentHash": format!("{parent_hash:#x}"),
                "timestamp": "0x4d2",
                "gasUsed": "0x5208",
                "gasLimit": "0x3938700",
                "baseFeePerGas": "0x7",
            })
        );

        assert_eq!(
            serde_json::from_value::<BlockHeader>(encoded).unwrap(),
            header
        );
    }

    #[test]
    fn account_override_state_maps_use_hex_keys_and_values() {
        let key = B256::from([0x33; 32]);
        let value = B256::from([0x44; 32]);
        let mut state = BTreeMap::new();
        state.insert(key, value);
        let override_value = AccountOverride {
            state: Some(state),
            ..AccountOverride::default()
        };

        let encoded = serde_json::to_value(override_value).unwrap();
        assert_eq!(
            encoded,
            json!({
                "state": {
                    format!("{key:#x}"): format!("{value:#x}")
                }
            })
        );
        assert_eq!(
            serde_json::from_value::<AccountOverride>(encoded)
                .unwrap()
                .state
                .unwrap()
                .get(&key),
            Some(&value)
        );
    }
}
