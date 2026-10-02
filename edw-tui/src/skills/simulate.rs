//! A whole plan, simulated as one block with `eth_simulateV1`, and what it would move.
//!
//! Every step runs on the state the previous ones leave (an approval before the call that
//! uses it), which a per-step `eth_estimateGas` cannot do. `traceTransfers` makes ETH moves
//! show up as ERC-20-style `Transfer` logs from [`ETH_PSEUDO`], so one pass over the logs
//! gives every asset change. An RPC without the method fails closed: skill plans are never
//! shown with a weaker check.

use std::collections::BTreeMap;

use alloy_primitives::{Address, B256, Bytes, I256, U256, address, b256, hex};
use reqwest::Url;
use serde_json::{Value, json};

use super::plan::CheckedStep;

/// Where `traceTransfers` reports native ETH moves.
pub const ETH_PSEUDO: Address = address!("0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE");
/// `keccak256("Transfer(address,address,uint256)")`, ERC-20 and ERC-721 alike.
pub const TRANSFER_TOPIC: &str =
    "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
const TRANSFER: B256 = b256!("0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef");
pub const UNSUPPORTED: &str = "this RPC can't simulate multi-step plans (no eth_simulateV1), so skill actions are disabled on it";

#[derive(Clone, Debug)]
pub struct SimLog {
    pub address: Address,
    pub topics: Vec<B256>,
    pub data: Bytes,
}

#[derive(Clone, Debug)]
pub struct CallResult {
    pub ok: bool,
    pub gas_used: u64,
    pub error: Option<String>,
    pub logs: Vec<SimLog>,
}

/// Net changes for one account. ERC-20 amounts are in base units; NFTs as (contract, id).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Deltas {
    pub eth: I256,
    pub erc20: BTreeMap<Address, I256>,
    pub nfts_in: Vec<(Address, U256)>,
    pub nfts_out: Vec<(Address, U256)>,
}

/// Simulates `steps` in order from `from`, at the latest block, without signatures or nonce
/// and balance checks on the sender beyond what the EVM itself does.
pub async fn simulate(
    rpc: &Url,
    from: Address,
    steps: &[CheckedStep],
) -> Result<Vec<CallResult>, String> {
    let calls: Vec<Value> = steps
        .iter()
        .map(|s| {
            json!({
                "from": format!("{from:#x}"),
                "to": format!("{:#x}", s.to),
                "value": format!("{:#x}", s.value),
                "input": hex::encode_prefixed(&s.data),
            })
        })
        .collect();
    let request = json!({
        "jsonrpc": "2.0", "id": 1, "method": "eth_simulateV1",
        "params": [{"blockStateCalls": [{"calls": calls}], "traceTransfers": true, "validation": false}, "latest"],
    });
    let response: Value = reqwest::Client::new()
        .post(rpc.clone())
        .json(&request)
        .send()
        .await
        .map_err(|e| format!("cannot reach the node at {rpc}: {e}"))?
        .json()
        .await
        .map_err(|e| {
            format!("the node at {rpc} answered with something that is not JSON-RPC: {e}")
        })?;
    if let Some(error) = response.get("error") {
        return Err(rpc_error(error));
    }
    let results = parse(response.get("result").unwrap_or(&Value::Null))?;
    if results.len() != steps.len() {
        return Err(format!(
            "the simulation returned {} results for {} steps",
            results.len(),
            steps.len()
        ));
    }
    Ok(results)
}

/// The JSON-RPC error, or [`UNSUPPORTED`] when the node does not know the method.
pub fn rpc_error(error: &Value) -> String {
    let code = error.get("code").and_then(Value::as_i64);
    let message = error
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let lower = message.to_lowercase();
    if code == Some(-32601)
        || lower.contains("method not found")
        || lower.contains("does not exist")
        || lower.contains("not supported")
        || lower.contains("not available")
    {
        return UNSUPPORTED.into();
    }
    format!("the simulation failed: {message}")
}

/// `result` of `eth_simulateV1` with one block: its `calls`, in order.
pub fn parse(result: &Value) -> Result<Vec<CallResult>, String> {
    let calls = result
        .get(0)
        .and_then(|block| block.get("calls"))
        .and_then(Value::as_array)
        .ok_or("the simulation returned no calls")?;
    calls.iter().map(parse_call).collect()
}

fn parse_call(call: &Value) -> Result<CallResult, String> {
    let hex_u64 = |v: Option<&Value>| {
        v.and_then(Value::as_str)
            .and_then(|s| u64::from_str_radix(s.trim_start_matches("0x"), 16).ok())
    };
    let ok = hex_u64(call.get("status")) == Some(1);
    let error = call.get("error").map(|e| {
        e.get("message")
            .and_then(Value::as_str)
            .map_or_else(|| e.to_string(), str::to_owned)
    });
    let logs = call
        .get("logs")
        .and_then(Value::as_array)
        .map(|logs| logs.iter().filter_map(parse_log).collect())
        .unwrap_or_default();
    Ok(CallResult {
        ok,
        gas_used: hex_u64(call.get("gasUsed")).unwrap_or(0),
        error: if ok {
            None
        } else {
            error.or_else(|| Some("reverted".into()))
        },
        logs,
    })
}

fn parse_log(log: &Value) -> Option<SimLog> {
    Some(SimLog {
        address: log.get("address")?.as_str()?.parse().ok()?,
        topics: log
            .get("topics")?
            .as_array()?
            .iter()
            .filter_map(|t| t.as_str()?.parse().ok())
            .collect(),
        data: log
            .get("data")
            .and_then(Value::as_str)
            .and_then(|d| hex::decode(d).ok())
            .unwrap_or_default()
            .into(),
    })
}

/// What `me` gains (positive) and loses (negative) across all successful calls.
pub fn deltas(me: Address, results: &[CallResult]) -> Deltas {
    let mut d = Deltas::default();
    for log in results.iter().filter(|r| r.ok).flat_map(|r| &r.logs) {
        if log.topics.first() != Some(&TRANSFER) {
            continue;
        }
        let party = |i: usize| log.topics.get(i).map(|t| Address::from_word(*t));
        let (Some(from), Some(to)) = (party(1), party(2)) else {
            continue;
        };
        if log.topics.len() == 4 {
            let id = U256::from_be_bytes(log.topics[3].0);
            if to == me {
                d.nfts_in.push((log.address, id));
            }
            if from == me {
                d.nfts_out.push((log.address, id));
            }
            continue;
        }
        if log.topics.len() != 3 || log.data.len() < 32 {
            continue;
        }
        let amount = I256::from_raw(U256::from_be_slice(&log.data[..32]));
        let sign = match (from == me, to == me) {
            (true, false) => -amount,
            (false, true) => amount,
            _ => continue,
        };
        if log.address == ETH_PSEUDO {
            d.eth += sign;
        } else {
            *d.erc20.entry(log.address).or_default() += sign;
        }
    }
    d.erc20.retain(|_, v| !v.is_zero());
    d
}

#[cfg(test)]
mod tests {
    use alloy_primitives::address;
    use serde_json::json;

    use super::*;

    const ANVIL0: Address = address!("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    const BEEF: Address = address!("0x000000000000000000000000000000000000bEEF");
    const USDC: Address = address!("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48");

    fn topic(address: Address) -> String {
        format!("0x{:0>64}", alloy_primitives::hex::encode(address))
    }

    fn word(n: u64) -> String {
        format!("0x{n:064x}")
    }

    #[test]
    fn eth_moves_are_read_from_trace_transfers() {
        let response: Value = serde_json::from_str(include_str!(
            "../../tests/fixtures/simulate_v1_transfer.json"
        ))
        .unwrap();
        let results = parse(&response["result"]).unwrap();
        assert_eq!(results.len(), 2);
        assert!(results.iter().all(|r| r.ok));
        assert_eq!(results[0].gas_used, 21_000);
        let d = deltas(ANVIL0, &results);
        assert_eq!(
            d.eth,
            -I256::try_from(1_000_000_000_000_000_001u128).unwrap()
        );
        assert!(d.erc20.is_empty());
        assert_eq!(
            deltas(BEEF, &results).eth,
            I256::try_from(1_000_000_000_000_000_001u128).unwrap()
        );
    }

    #[test]
    fn erc20_and_nft_transfers_are_netted_per_token() {
        let calls = json!([{
            "status": "0x1", "gasUsed": "0x10", "returnData": "0x",
            "logs": [
                {"address": format!("{USDC:#x}"), "topics": [TRANSFER_TOPIC, topic(ANVIL0), topic(BEEF)], "data": word(100)},
                {"address": format!("{USDC:#x}"), "topics": [TRANSFER_TOPIC, topic(BEEF), topic(ANVIL0)], "data": word(30)},
                {"address": format!("{BEEF:#x}"), "topics": [TRANSFER_TOPIC, topic(Address::ZERO), topic(ANVIL0), word(7)], "data": "0x"},
                {"address": format!("{USDC:#x}"), "topics": ["0x1234", topic(ANVIL0)], "data": word(1)},
            ]
        }]);
        let results = parse(&json!([{ "calls": calls }])).unwrap();
        let d = deltas(ANVIL0, &results);
        assert_eq!(d.erc20[&USDC], I256::try_from(-70).unwrap());
        assert_eq!(d.nfts_in, [(BEEF, U256::from(7u8))]);
        assert!(d.nfts_out.is_empty());
        assert_eq!(d.eth, I256::ZERO);
    }

    #[test]
    fn a_failed_call_carries_its_reason() {
        let results = parse(&json!([{ "calls": [
            {"status": "0x1", "gasUsed": "0x5208", "returnData": "0x", "logs": []},
            {"status": "0x0", "gasUsed": "0x6000", "returnData": "0x", "logs": [],
             "error": {"code": 3, "message": "execution reverted: 26"}}
        ]}]))
        .unwrap();
        assert!(results[0].ok);
        assert!(!results[1].ok);
        assert_eq!(results[1].error.as_deref(), Some("execution reverted: 26"));
    }

    #[test]
    fn an_rpc_without_simulate_v1_fails_closed() {
        for error in [
            json!({"code": -32601, "message": "Method not found"}),
            json!({"code": -32000, "message": "the method eth_simulateV1 does not exist/is not available"}),
        ] {
            assert_eq!(rpc_error(&error), UNSUPPORTED);
        }
        assert!(
            rpc_error(&json!({"code": -32000, "message": "header not found"}))
                .contains("header not found")
        );
    }
}
