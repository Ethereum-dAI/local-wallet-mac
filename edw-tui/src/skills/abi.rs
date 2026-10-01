//! JSON ↔ ABI values for skill scripts and plans. Numbers travel as decimal strings, so no
//! JSON number ever loses precision on the way.

use alloy_dyn_abi::{DynSolType, DynSolValue};
use alloy_primitives::hex;
use serde_json::Value;

/// One JSON argument as a value of `ty`. Scalars come as strings (or plain JSON numbers and
/// booleans); tuples and arrays as JSON arrays.
pub fn coerce(ty: &DynSolType, value: &Value) -> Result<DynSolValue, String> {
    let items = |expected: Option<usize>| -> Result<&Vec<Value>, String> {
        let items = value
            .as_array()
            .ok_or_else(|| format!("expected a JSON array for {ty}, got {value}"))?;
        match expected {
            Some(n) if items.len() != n => {
                Err(format!("expected {n} items for {ty}, got {}", items.len()))
            }
            _ => Ok(items),
        }
    };
    match ty {
        DynSolType::Tuple(types) => Ok(DynSolValue::Tuple(
            types
                .iter()
                .zip(items(Some(types.len()))?)
                .map(|(t, v)| coerce(t, v))
                .collect::<Result<_, _>>()?,
        )),
        DynSolType::Array(inner) => Ok(DynSolValue::Array(
            items(None)?
                .iter()
                .map(|v| coerce(inner, v))
                .collect::<Result<_, _>>()?,
        )),
        DynSolType::FixedArray(inner, n) => Ok(DynSolValue::FixedArray(
            items(Some(*n))?
                .iter()
                .map(|v| coerce(inner, v))
                .collect::<Result<_, _>>()?,
        )),
        _ => {
            let text = match value {
                Value::String(s) => s.clone(),
                Value::Number(n) => n.to_string(),
                Value::Bool(b) => b.to_string(),
                other => return Err(format!("expected a {ty}, got {other}")),
            };
            ty.coerce_str(&text)
                .map_err(|_| format!("`{text}` is not a valid {ty}"))
        }
    }
}

/// A decoded value as plain JSON: integers as decimal strings, addresses checksummed, bytes
/// as 0x hex, tuples and arrays as JSON arrays.
pub fn to_json(value: &DynSolValue) -> Value {
    match value {
        DynSolValue::Bool(b) => Value::Bool(*b),
        DynSolValue::Int(i, _) => Value::String(i.to_string()),
        DynSolValue::Uint(u, _) => Value::String(u.to_string()),
        DynSolValue::Address(a) => Value::String(a.to_string()),
        DynSolValue::FixedBytes(word, size) => Value::String(hex::encode_prefixed(&word[..*size])),
        DynSolValue::Bytes(bytes) => Value::String(hex::encode_prefixed(bytes)),
        DynSolValue::String(s) => Value::String(s.clone()),
        DynSolValue::Function(f) => Value::String(hex::encode_prefixed(f.as_slice())),
        DynSolValue::Array(items)
        | DynSolValue::FixedArray(items)
        | DynSolValue::Tuple(items)
        | DynSolValue::CustomStruct { tuple: items, .. } => {
            Value::Array(items.iter().map(to_json).collect())
        }
    }
}
