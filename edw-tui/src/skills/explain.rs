//! What a signed Safe call would do, read from its raw calldata by the harness itself.
//!
//! A skill's own summary is a convenience; the review must not depend on it. This decodes the
//! `data` of a Safe transaction for the selectors people actually use (token transfers and
//! approvals, MultiSend batches, Safe owner and module changes, CoW pre-signing) and says so
//! plainly when it does not recognise a call. Nothing here is trusted to make a transaction safe;
//! it is there so the person confirming can see what the owners signed.

use alloy_primitives::{Address, U256, address};
use alloy_sol_types::{SolCall, sol};

use super::plan::one_line;
use crate::interim::guards::format_units;

sol! {
    function transfer(address to, uint256 amount);
    function approve(address spender, uint256 amount);
    function transferFrom(address from, address to, uint256 amount);
    function multiSend(bytes transactions);
    function addOwnerWithThreshold(address owner, uint256 _threshold);
    function removeOwner(address prevOwner, address owner, uint256 _threshold);
    function swapOwner(address prevOwner, address oldOwner, address newOwner);
    function changeThreshold(uint256 _threshold);
    function enableModule(address module);
    function disableModule(address prevModule, address module);
    function setGuard(address guard);
    function setFallbackHandler(address handler);
    function setPreSignature(bytes orderUid, bool signed);
}

/// Safe's own MultiSend deployments, the one delegatecall a Safe makes all the time.
const MULTISEND: [Address; 6] = [
    address!("0x40A2aCCbd92BCA938b02010E17A5b8929b49130D"),
    address!("0x9641d764fc13c8B624c04430C7356C1C7C8102e2"),
    address!("0xA238CBeb142c10Ef7Ad8442C6D1f9E89e07e7761"),
    address!("0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526"),
    address!("0x218543288004CD07832472D464648173c77D7eB7"),
    address!("0xA83c336B20401Af773B6219BA5027174338D1836"),
];
const COW_SETTLEMENT: Address = address!("0x9008D19f58AAbD9eD0D60971565AA8510560ab41");

/// (symbol, address, decimals) for mainnet tokens a Safe moves most.
const TOKENS: [(&str, Address, u8); 5] = [
    (
        "USDC",
        address!("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"),
        6,
    ),
    (
        "USDT",
        address!("0xdAC17F958D2ee523a2206206994597C13D831ec7"),
        6,
    ),
    (
        "DAI",
        address!("0x6B175474E89094C44Da98b954EedeAC495271d0F"),
        18,
    ),
    (
        "WETH",
        address!("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"),
        18,
    ),
    (
        "COW",
        address!("0xDEf1CA1fb7FBcDC777520aa7f396b4E015F497aB"),
        18,
    ),
];

/// Shows at most this many calls of a batch.
const BATCH_LINES: usize = 8;

fn who(address: Address) -> String {
    format!("{address}")
}

fn token(address: Address) -> Option<(&'static str, u8)> {
    TOKENS
        .iter()
        .find(|(_, a, _)| *a == address)
        .map(|(s, _, d)| (*s, *d))
}

fn amount_of(token_address: Address, raw: U256) -> String {
    if raw >= U256::from(1u8) << 255 {
        return "UNLIMITED".into();
    }
    match token(token_address) {
        Some((symbol, decimals)) => format!("{} {symbol} ({raw})", format_units(raw, decimals)),
        None => format!("{raw} base units"),
    }
}

fn on(to: Address) -> String {
    match token(to) {
        Some((symbol, _)) => format!("{symbol} {}", who(to)),
        None => who(to),
    }
}

/// One line for one call (a Safe's `to`, `value`, `data`), then nothing else.
fn line(to: Address, value: U256, data: &[u8], safe: Address) -> String {
    if data.is_empty() {
        return if value.is_zero() && to == safe {
            "an empty call to the Safe itself: a rejection, it only uses up the nonce".into()
        } else {
            format!("sends {} ETH to {}", format_units(value, 18), who(to))
        };
    }
    let eth = if value.is_zero() {
        String::new()
    } else {
        format!(" with {} ETH", format_units(value, 18))
    };
    let text = if let Ok(c) = transferCall::abi_decode(data) {
        format!(
            "{}.transfer: {} to {}",
            on(to),
            amount_of(to, c.amount),
            who(c.to)
        )
    } else if let Ok(c) = approveCall::abi_decode(data) {
        format!(
            "{}.approve: {} for {}",
            on(to),
            amount_of(to, c.amount),
            who(c.spender)
        )
    } else if let Ok(c) = transferFromCall::abi_decode(data) {
        format!(
            "{}.transferFrom: {} from {} to {}",
            on(to),
            amount_of(to, c.amount),
            who(c.from),
            who(c.to)
        )
    } else if let Ok(c) = addOwnerWithThresholdCall::abi_decode(data) {
        format!(
            "CHANGES WHO CONTROLS THE SAFE: adds owner {}, threshold {}",
            who(c.owner),
            c._threshold
        )
    } else if let Ok(c) = removeOwnerCall::abi_decode(data) {
        format!(
            "CHANGES WHO CONTROLS THE SAFE: removes owner {}, threshold {}",
            who(c.owner),
            c._threshold
        )
    } else if let Ok(c) = swapOwnerCall::abi_decode(data) {
        format!(
            "CHANGES WHO CONTROLS THE SAFE: replaces owner {} with {}",
            who(c.oldOwner),
            who(c.newOwner)
        )
    } else if let Ok(c) = changeThresholdCall::abi_decode(data) {
        format!(
            "CHANGES WHO CONTROLS THE SAFE: threshold becomes {}",
            c._threshold
        )
    } else if let Ok(c) = enableModuleCall::abi_decode(data) {
        format!(
            "ENABLES A MODULE that can move the Safe's funds without owners signing: {}",
            who(c.module)
        )
    } else if let Ok(c) = disableModuleCall::abi_decode(data) {
        format!("disables module {}", who(c.module))
    } else if let Ok(c) = setGuardCall::abi_decode(data) {
        format!("sets the transaction guard to {}", who(c.guard))
    } else if let Ok(c) = setFallbackHandlerCall::abi_decode(data) {
        format!("sets the fallback handler to {}", who(c.handler))
    } else if let Ok(c) = setPreSignatureCall::abi_decode(data) {
        let verb = if c.signed { "authorises" } else { "cancels" };
        let cow = if to == COW_SETTLEMENT {
            "CoW Protocol order"
        } else {
            "order"
        };
        format!("{verb} {cow} 0x{}… on {}", hex_prefix(&c.orderUid), who(to))
    } else {
        format!(
            "UNKNOWN CALL: selector 0x{}, {} bytes of data, to {}",
            hex_prefix(&data[..data.len().min(4)]),
            data.len(),
            who(to)
        )
    };
    format!("{text}{eth}")
}

fn hex_prefix(bytes: &[u8]) -> String {
    alloy_primitives::hex::encode(&bytes[..bytes.len().min(10)])
}

/// The calls inside a MultiSend `transactions` blob: operation, to, value, data.
/// One call of a MultiSend batch: operation, target, value, data.
type Inner = (u8, Address, U256, Vec<u8>);

fn unpack(blob: &[u8]) -> Option<Vec<Inner>> {
    let mut out = Vec::new();
    let mut at = 0;
    while at < blob.len() {
        let head = blob.get(at..at + 85)?;
        let operation = head[0];
        let to = Address::from_slice(&head[1..21]);
        let value = U256::from_be_slice(&head[21..53]);
        let length: usize = U256::from_be_slice(&head[53..85]).try_into().ok()?;
        let data = blob.get(at + 85..at + 85 + length)?.to_vec();
        out.push((operation, to, value, data));
        at += 85 + length;
    }
    Some(out)
}

/// What a signed `execTransaction(to, value, data, operation, ...)` does, one line each, for
/// the review. `operation` 1 is a delegatecall: the target's code runs as the Safe.
pub fn describe(
    safe: Address,
    to: Address,
    value: U256,
    data: &[u8],
    operation: u8,
) -> Vec<String> {
    let mut lines = Vec::new();
    if operation == 1 {
        if MULTISEND.contains(&to) {
            match multiSendCall::abi_decode(data)
                .ok()
                .and_then(|c| unpack(&c.transactions))
            {
                Some(calls) => {
                    lines.push(format!(
                        "a batch of {} calls (Safe's own MultiSend):",
                        calls.len()
                    ));
                    for (index, (op, target, v, d)) in calls.iter().enumerate() {
                        if index == BATCH_LINES {
                            lines.push(format!("  … and {} more", calls.len() - BATCH_LINES));
                            break;
                        }
                        let delegate = if *op == 1 { "DELEGATECALL: " } else { "" };
                        lines.push(format!(
                            "  {}. {delegate}{}",
                            index + 1,
                            line(*target, *v, d, safe)
                        ));
                    }
                }
                None => lines.push("UNREADABLE BATCH: the MultiSend data does not decode".into()),
            }
        } else {
            lines.push(format!(
                "DELEGATECALL to {}: that contract's code runs AS THE SAFE and can do anything with it",
                who(to)
            ));
        }
    } else {
        lines.push(line(to, value, data, safe));
    }
    lines.into_iter().map(|l| one_line(&l)).collect()
}

/// One line on the signatures of a Safe `execTransaction`: how many of each kind, and whether
/// the sender's own approval is among them (it counts because the sender is the one sending).
/// `Err` for a shape the review cannot explain.
pub fn signatures(blob: &[u8], sender: Address) -> Result<String, String> {
    if blob.is_empty() || !blob.len().is_multiple_of(65) {
        return Err(
            "the signatures are not 65-byte entries; contract signatures are not supported".into(),
        );
    }
    let (mut signed, mut approved, mut own) = (0, 0, 0);
    for chunk in blob.chunks(65) {
        match chunk[64] {
            27 | 28 | 31 | 32 => signed += 1,
            1 => {
                approved += 1;
                if Address::from_slice(&chunk[12..32]) == sender {
                    own += 1;
                }
            }
            other => {
                return Err(format!(
                    "a signature of type {other} cannot be explained here"
                ));
            }
        }
    }
    let mut text = format!(
        "{} signatures: {signed} signed, {approved} approved on chain",
        blob.len() / 65
    );
    if own > 0 {
        text.push_str(", one of them YOURS (your approval counts because you are the one sending)");
    }
    Ok(text)
}

#[cfg(test)]
mod tests {
    use alloy_primitives::hex;

    use super::*;

    const SAFE: Address = address!("0xA03be496e67Ec29bC62F01a428683D7F9c204930");
    const BOB: Address = address!("0x6C9F86423e5F36D6E42FbC1BAf966d3c1E0B5711");
    const USDC: Address = address!("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48");

    fn multisend(calls: &[Inner]) -> Vec<u8> {
        let mut blob = Vec::new();
        for (op, to, value, data) in calls {
            blob.push(*op);
            blob.extend_from_slice(to.as_slice());
            blob.extend_from_slice(&value.to_be_bytes::<32>());
            blob.extend_from_slice(&U256::from(data.len()).to_be_bytes::<32>());
            blob.extend_from_slice(data);
        }
        multiSendCall {
            transactions: blob.into(),
        }
        .abi_encode()
    }

    #[test]
    fn a_token_transfer_names_the_token_the_amount_and_the_recipient() {
        let data = transferCall {
            to: BOB,
            amount: U256::from(1_500_000u64),
        }
        .abi_encode();
        let lines = describe(SAFE, USDC, U256::ZERO, &data, 0);
        assert_eq!(lines.len(), 1);
        assert!(
            lines[0].contains("USDC") && lines[0].contains("1.5 USDC (1500000)"),
            "{lines:?}"
        );
        assert!(lines[0].contains(&BOB.to_string()), "{lines:?}");
    }

    #[test]
    fn an_unlimited_approval_is_shouted() {
        let data = approveCall {
            spender: BOB,
            amount: U256::MAX,
        }
        .abi_encode();
        assert!(describe(SAFE, USDC, U256::ZERO, &data, 0)[0].contains("UNLIMITED"));
    }

    #[test]
    fn a_multisend_batch_is_unpacked_call_by_call() {
        let pay = |amount: u64| {
            (
                0u8,
                USDC,
                U256::ZERO,
                transferCall {
                    to: BOB,
                    amount: U256::from(amount),
                }
                .abi_encode(),
            )
        };
        let data = multisend(&[
            pay(1_000_000),
            pay(2_000_000),
            (0, BOB, U256::from(10u64).pow(U256::from(18)), vec![]),
        ]);
        let lines = describe(SAFE, MULTISEND[0], U256::ZERO, &data, 1);
        assert_eq!(lines[0], "a batch of 3 calls (Safe's own MultiSend):");
        assert!(
            lines[1].contains("1 USDC") && lines[2].contains("2 USDC"),
            "{lines:?}"
        );
        assert!(lines[3].contains("sends 1 ETH to"), "{lines:?}");
    }

    #[test]
    fn a_batch_hides_nothing_it_cannot_show() {
        // An owner change smuggled into a batch is still named.
        let data = multisend(&[(
            0,
            SAFE,
            U256::ZERO,
            addOwnerWithThresholdCall {
                owner: BOB,
                _threshold: U256::from(1),
            }
            .abi_encode(),
        )]);
        let lines = describe(SAFE, MULTISEND[0], U256::ZERO, &data, 1);
        assert!(
            lines[1].contains("CHANGES WHO CONTROLS THE SAFE"),
            "{lines:?}"
        );
        // A nested delegatecall is marked, and a batch that does not decode says so.
        let nested = multisend(&[(1, BOB, U256::ZERO, vec![0xde, 0xad, 0xbe, 0xef])]);
        assert!(describe(SAFE, MULTISEND[0], U256::ZERO, &nested, 1)[1].contains("DELEGATECALL"));
        assert!(describe(SAFE, MULTISEND[0], U256::ZERO, &[1, 2, 3], 1)[0].contains("UNREADABLE"));
    }

    #[test]
    fn a_big_batch_is_cut_off_with_a_count() {
        let calls: Vec<_> = (0..12)
            .map(|_| (0u8, BOB, U256::from(1u8), vec![]))
            .collect();
        let lines = describe(SAFE, MULTISEND[0], U256::ZERO, &multisend(&calls), 1);
        assert_eq!(lines.len(), 1 + 8 + 1);
        assert!(lines[9].contains("4 more"));
    }

    #[test]
    fn a_delegatecall_elsewhere_and_unknown_calls_are_flagged() {
        let lines = describe(SAFE, BOB, U256::ZERO, &[1, 2, 3, 4, 5], 1);
        assert!(lines[0].contains("AS THE SAFE"), "{lines:?}");
        let lines = describe(
            SAFE,
            BOB,
            U256::ZERO,
            &hex::decode("deadbeef00").unwrap(),
            0,
        );
        assert!(
            lines[0].starts_with("UNKNOWN CALL: selector 0xdeadbeef, 5 bytes"),
            "{lines:?}"
        );
    }

    #[test]
    fn plain_eth_and_rejections_read_plainly() {
        assert!(
            describe(SAFE, BOB, U256::from(10).pow(U256::from(17)), &[], 0)[0]
                .contains("sends 0.1 ETH")
        );
        assert!(describe(SAFE, SAFE, U256::ZERO, &[], 0)[0].contains("rejection"));
    }

    #[test]
    fn signatures_are_counted_and_the_senders_own_approval_is_named() {
        let mut blob = vec![0u8; 65 * 3];
        blob[64] = 27;
        blob[65 + 64] = 31;
        blob[130 + 12..130 + 32].copy_from_slice(BOB.as_slice());
        blob[130 + 64] = 1;
        let text = signatures(&blob, BOB).unwrap();
        assert!(
            text.starts_with("3 signatures: 2 signed, 1 approved on chain"),
            "{text}"
        );
        assert!(text.contains("YOURS"), "{text}");
        assert!(!signatures(&blob, SAFE).unwrap().contains("YOURS"));
        assert!(signatures(&blob[..64], BOB).is_err());
        blob[64] = 0;
        assert!(signatures(&blob, BOB).unwrap_err().contains("type 0"));
    }
}
