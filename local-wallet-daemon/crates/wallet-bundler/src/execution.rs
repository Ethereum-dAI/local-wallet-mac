use alloy_primitives::{Address, Bytes, U256};
use alloy_sol_types::{sol, SolCall, SolValue};

use crate::reclaimable_entry_point_deposit;

sol! {
    function execute(bytes32 mode, bytes executionCalldata);
    function withdrawTo(address withdrawAddress, uint256 amount);

    struct Execution {
        address target;
        uint256 value;
        bytes callData;
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Erc7579SingleExecution {
    pub target: Address,
    pub value: U256,
    pub call_data: Bytes,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EntryPointWithdrawTo {
    pub withdraw_address: Address,
    pub amount: U256,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EntryPointReclaimBreakGlass {
    pub withdraw_address: Address,
    pub amount: U256,
    pub reclaimable: U256,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EntryPointReclaimBreakGlassError {
    CallDataNotSingleExecution,
    TargetMismatch {
        actual: Address,
    },
    NonZeroValue {
        actual: U256,
    },
    NotEntryPointWithdrawTo,
    WithdrawAddressMismatch {
        actual: Address,
    },
    AmountExceedsReclaimable {
        requested_amount: U256,
        reclaimable: U256,
    },
}

impl EntryPointReclaimBreakGlassError {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::CallDataNotSingleExecution => "call_data_not_single_execution",
            Self::TargetMismatch { .. } => "target_mismatch",
            Self::NonZeroValue { .. } => "non_zero_value",
            Self::NotEntryPointWithdrawTo => "not_entrypoint_withdraw_to",
            Self::WithdrawAddressMismatch { .. } => "withdraw_address_mismatch",
            Self::AmountExceedsReclaimable { .. } => "amount_exceeds_reclaimable",
        }
    }
}

pub fn encode_erc7579_single_execution(target: Address, value: U256, call_data: Bytes) -> Bytes {
    let mode = [0u8; 32];
    let mut execution_calldata = Vec::with_capacity(52 + call_data.len());
    execution_calldata.extend_from_slice(target.as_slice());
    execution_calldata.extend_from_slice(&value.to_be_bytes::<32>());
    execution_calldata.extend_from_slice(&call_data);

    Bytes::from(
        executeCall {
            mode: mode.into(),
            executionCalldata: Bytes::from(execution_calldata),
        }
        .abi_encode(),
    )
}

pub fn decode_erc7579_single_execution(call_data: &[u8]) -> Option<Erc7579SingleExecution> {
    let decoded = executeCall::abi_decode(call_data).ok()?;
    let mode = decoded.mode.as_slice();
    if !is_single_call_mode(mode) {
        return None;
    }
    parse_packed_execution(&decoded.executionCalldata)
}

/// Parses the packed single-execution payload shared by both the strict
/// (`decode_erc7579_single_execution`) and permissive (`decode_erc7579_executions`)
/// decoders: 20 bytes of target, 32 bytes of big-endian value, then the inner
/// call data. Kept as the one place that knows this 52-byte header layout so
/// the two decoders cannot silently drift apart.
fn parse_packed_execution(execution_calldata: &[u8]) -> Option<Erc7579SingleExecution> {
    if execution_calldata.len() < 52 {
        return None;
    }

    let mut target = [0u8; 20];
    target.copy_from_slice(&execution_calldata[..20]);

    Some(Erc7579SingleExecution {
        target: Address::from(target),
        value: U256::from_be_slice(&execution_calldata[20..52]),
        call_data: Bytes::copy_from_slice(&execution_calldata[52..]),
    })
}

/// Headroom suggested for a single ERC-7579 execution when the account-call-gas
/// estimate is unavailable, on top of [`UNESTIMATED_BASE_CALL_GAS_HEADROOM`].
pub const UNESTIMATED_PER_EXECUTION_CALL_GAS_HEADROOM: u64 = 400_000;

/// Fixed headroom applied once per UserOperation, covering Kernel dispatch
/// overhead before any execution runs.
pub const UNESTIMATED_BASE_CALL_GAS_HEADROOM: u64 = 200_000;

/// Decodes both single (`0x00`) and batch (`0x01`) ERC-7579 exec modes.
///
/// This is deliberately separate from [`decode_erc7579_single_execution`], which
/// rejects batch mode because the break-glass validation path depends on that
/// strictness. Returns `None` for delegate/unknown call types and malformed
/// payloads.
pub fn decode_erc7579_executions(call_data: &[u8]) -> Option<Vec<Erc7579SingleExecution>> {
    let decoded = executeCall::abi_decode(call_data).ok()?;
    let mode = decoded.mode.as_slice();
    if !has_canonical_reserved_mode_bytes(mode) {
        return None;
    }

    match mode[0] {
        0x00 => parse_packed_execution(&decoded.executionCalldata).map(|execution| vec![execution]),
        0x01 => {
            let executions = <Vec<Execution>>::abi_decode(&decoded.executionCalldata).ok()?;
            Some(
                executions
                    .into_iter()
                    .map(|execution| Erc7579SingleExecution {
                        target: execution.target,
                        value: execution.value,
                        call_data: execution.callData,
                    })
                    .collect(),
            )
        }
        _ => None,
    }
}

/// Call-gas limit to suggest when estimation is unavailable.
///
/// Scales with the number of sub-executions so a simple transfer stays cheap
/// while a batch gets room, and is clamped to the policy cap. Undecodable
/// calldata falls back to single-execution headroom rather than erroring, so an
/// unknown exec mode still yields a usable suggestion.
///
/// The result is a hard balance floor for the account: EntryPoint charges
/// `required_prefund = (callGasLimit + verificationGasLimit + preVerificationGas) * maxFeePerGas`
/// up front. That is why this is proportional rather than simply the policy cap.
pub fn suggested_unestimated_call_gas_limit(call_data: &[u8], max_call_gas_limit: U256) -> U256 {
    let executions = decode_erc7579_executions(call_data)
        .map(|executions| executions.len().max(1))
        .unwrap_or(1) as u64;
    let raw = U256::from(UNESTIMATED_BASE_CALL_GAS_HEADROOM)
        + U256::from(UNESTIMATED_PER_EXECUTION_CALL_GAS_HEADROOM) * U256::from(executions);
    raw.min(max_call_gas_limit)
}

pub fn encode_entry_point_withdraw_to(withdraw_address: Address, amount: U256) -> Bytes {
    Bytes::from(
        withdrawToCall {
            withdrawAddress: withdraw_address,
            amount,
        }
        .abi_encode(),
    )
}

pub fn decode_entry_point_withdraw_to(call_data: &[u8]) -> Option<EntryPointWithdrawTo> {
    let decoded = withdrawToCall::abi_decode(call_data).ok()?;
    Some(EntryPointWithdrawTo {
        withdraw_address: decoded.withdrawAddress,
        amount: decoded.amount,
    })
}

pub fn validate_entry_point_reclaim_break_glass(
    call_data: &[u8],
    sender: Address,
    entry_point: Address,
    required_prefund: U256,
    entry_point_deposit: U256,
    safety_margin: U256,
) -> std::result::Result<EntryPointReclaimBreakGlass, EntryPointReclaimBreakGlassError> {
    let execution = decode_erc7579_single_execution(call_data)
        .ok_or(EntryPointReclaimBreakGlassError::CallDataNotSingleExecution)?;
    if execution.target != entry_point {
        return Err(EntryPointReclaimBreakGlassError::TargetMismatch {
            actual: execution.target,
        });
    }
    if !execution.value.is_zero() {
        return Err(EntryPointReclaimBreakGlassError::NonZeroValue {
            actual: execution.value,
        });
    }

    let withdraw = decode_entry_point_withdraw_to(&execution.call_data)
        .ok_or(EntryPointReclaimBreakGlassError::NotEntryPointWithdrawTo)?;
    if withdraw.withdraw_address != sender {
        return Err(EntryPointReclaimBreakGlassError::WithdrawAddressMismatch {
            actual: withdraw.withdraw_address,
        });
    }

    let reclaimable =
        reclaimable_entry_point_deposit(entry_point_deposit, required_prefund, safety_margin);
    if withdraw.amount > reclaimable {
        return Err(EntryPointReclaimBreakGlassError::AmountExceedsReclaimable {
            requested_amount: withdraw.amount,
            reclaimable,
        });
    }

    Ok(EntryPointReclaimBreakGlass {
        withdraw_address: withdraw.withdraw_address,
        amount: withdraw.amount,
        reclaimable,
    })
}

fn is_single_call_mode(mode: &[u8]) -> bool {
    has_canonical_reserved_mode_bytes(mode) && mode[0] == 0x00
}

/// True when the exec-mode's non-call-type bytes are canonical: `mode[1]` is
/// one of the two call types this crate understands (single `0x00` / batch
/// `0x01` — `mode[0]` still decides which), and the remaining reserved bytes
/// are all zero. Shared by the strict and permissive decoders so a change to
/// what counts as "reserved" can't drift between them.
fn has_canonical_reserved_mode_bytes(mode: &[u8]) -> bool {
    mode.len() == 32 && matches!(mode[1], 0x00 | 0x01) && mode[2..].iter().all(|byte| *byte == 0)
}

#[cfg(test)]
mod tests {
    use alloy_primitives::address;
    use wallet_addresses::ENTRY_POINT_V07;

    use super::*;

    #[test]
    fn decodes_erc7579_single_execution() {
        let target = ENTRY_POINT_V07;
        let inner = Bytes::from_static(&[0x20, 0x5c, 0x28, 0x78]);
        let call_data = encode_erc7579_single_execution(target, U256::from(7), inner.clone());

        let decoded = decode_erc7579_single_execution(&call_data).unwrap();

        assert_eq!(decoded.target, target);
        assert_eq!(decoded.value, U256::from(7));
        assert_eq!(decoded.call_data, inner);
    }

    #[test]
    fn rejects_batch_or_delegate_modes() {
        let target = ENTRY_POINT_V07;
        let mut mode = [0u8; 32];
        mode[0] = 0x01;
        let mut execution_calldata = Vec::new();
        execution_calldata.extend_from_slice(target.as_slice());
        execution_calldata.extend_from_slice(&U256::ZERO.to_be_bytes::<32>());
        let batch = Bytes::from(
            executeCall {
                mode: mode.into(),
                executionCalldata: Bytes::from(execution_calldata),
            }
            .abi_encode(),
        );

        assert!(decode_erc7579_single_execution(&batch).is_none());

        mode[0] = 0xff;
        let delegate = Bytes::from(
            executeCall {
                mode: mode.into(),
                executionCalldata: Bytes::new(),
            }
            .abi_encode(),
        );
        assert!(decode_erc7579_single_execution(&delegate).is_none());
    }

    #[test]
    fn decodes_entry_point_withdraw_to() {
        let account = address!("d73c7780b1c1da1586a8332d5499f36b7cbb33c2");
        let call_data = encode_entry_point_withdraw_to(account, U256::from(42));

        let decoded = decode_entry_point_withdraw_to(&call_data).unwrap();

        assert_eq!(decoded.withdraw_address, account);
        assert_eq!(decoded.amount, U256::from(42));
    }

    #[test]
    fn validates_bounded_entry_point_reclaim_break_glass() {
        let sender = address!("d73c7780b1c1da1586a8332d5499f36b7cbb33c2");
        let entry_point = ENTRY_POINT_V07;
        let withdraw_call = encode_entry_point_withdraw_to(sender, U256::from(7));
        let call_data = encode_erc7579_single_execution(entry_point, U256::ZERO, withdraw_call);

        let result = validate_entry_point_reclaim_break_glass(
            &call_data,
            sender,
            entry_point,
            U256::from(10),
            U256::from(20),
            U256::from(3),
        )
        .unwrap();

        assert_eq!(result.withdraw_address, sender);
        assert_eq!(result.amount, U256::from(7));
        assert_eq!(result.reclaimable, U256::from(7));
    }

    #[test]
    fn reclaim_break_glass_rejects_non_single_account_execution() {
        let sender = address!("d73c7780b1c1da1586a8332d5499f36b7cbb33c2");
        let entry_point = ENTRY_POINT_V07;

        let error = validate_entry_point_reclaim_break_glass(
            &encode_entry_point_withdraw_to(sender, U256::from(1)),
            sender,
            entry_point,
            U256::ZERO,
            U256::from(10),
            U256::ZERO,
        )
        .unwrap_err();

        assert_eq!(error.as_str(), "call_data_not_single_execution");
    }

    #[test]
    fn reclaim_break_glass_requires_canonical_entry_point_zero_value_and_sender_withdraw() {
        let sender = address!("d73c7780b1c1da1586a8332d5499f36b7cbb33c2");
        let entry_point = ENTRY_POINT_V07;
        let other = address!("1111111111111111111111111111111111111111");
        let withdraw_call = encode_entry_point_withdraw_to(sender, U256::from(1));

        let wrong_target = validate_entry_point_reclaim_break_glass(
            &encode_erc7579_single_execution(other, U256::ZERO, withdraw_call.clone()),
            sender,
            entry_point,
            U256::ZERO,
            U256::from(10),
            U256::ZERO,
        )
        .unwrap_err();
        assert_eq!(wrong_target.as_str(), "target_mismatch");

        let non_zero_value = validate_entry_point_reclaim_break_glass(
            &encode_erc7579_single_execution(entry_point, U256::from(1), withdraw_call),
            sender,
            entry_point,
            U256::ZERO,
            U256::from(10),
            U256::ZERO,
        )
        .unwrap_err();
        assert_eq!(non_zero_value.as_str(), "non_zero_value");

        let wrong_recipient = validate_entry_point_reclaim_break_glass(
            &encode_erc7579_single_execution(
                entry_point,
                U256::ZERO,
                encode_entry_point_withdraw_to(other, U256::from(1)),
            ),
            sender,
            entry_point,
            U256::ZERO,
            U256::from(10),
            U256::ZERO,
        )
        .unwrap_err();
        assert_eq!(wrong_recipient.as_str(), "withdraw_address_mismatch");
    }

    #[test]
    fn reclaim_break_glass_rejects_amount_above_reclaimable() {
        let sender = address!("d73c7780b1c1da1586a8332d5499f36b7cbb33c2");
        let entry_point = ENTRY_POINT_V07;
        let call_data = encode_erc7579_single_execution(
            entry_point,
            U256::ZERO,
            encode_entry_point_withdraw_to(sender, U256::from(8)),
        );

        let error = validate_entry_point_reclaim_break_glass(
            &call_data,
            sender,
            entry_point,
            U256::from(10),
            U256::from(20),
            U256::from(3),
        )
        .unwrap_err();

        assert_eq!(
            error,
            EntryPointReclaimBreakGlassError::AmountExceedsReclaimable {
                requested_amount: U256::from(8),
                reclaimable: U256::from(7),
            }
        );
    }

    fn encode_batch_execution(executions: &[(Address, U256, Bytes)]) -> Bytes {
        use alloy_sol_types::SolValue;

        let mut mode = [0u8; 32];
        mode[0] = 0x01;
        let items: Vec<Execution> = executions
            .iter()
            .map(|(target, value, call_data)| Execution {
                target: *target,
                value: *value,
                callData: call_data.clone(),
            })
            .collect();

        Bytes::from(
            executeCall {
                mode: mode.into(),
                executionCalldata: Bytes::from(items.abi_encode()),
            }
            .abi_encode(),
        )
    }

    #[test]
    fn decodes_single_and_batch_exec_modes() {
        let target = ENTRY_POINT_V07;
        let inner = Bytes::from_static(&[0x11, 0x22, 0x33, 0x44]);

        let single = encode_erc7579_single_execution(target, U256::from(7), inner.clone());
        let decoded = decode_erc7579_executions(&single).expect("single mode decodes");
        assert_eq!(decoded.len(), 1);
        assert_eq!(decoded[0].target, target);
        assert_eq!(decoded[0].value, U256::from(7));
        assert_eq!(decoded[0].call_data, inner);

        let other = address!("d73c7780b1c1da1586a8332d5499f36b7cbb33c2");
        let batch = encode_batch_execution(&[
            (target, U256::from(1), inner.clone()),
            (other, U256::from(2), Bytes::new()),
        ]);
        let decoded = decode_erc7579_executions(&batch).expect("batch mode decodes");
        assert_eq!(decoded.len(), 2);
        assert_eq!(decoded[0].target, target);
        assert_eq!(decoded[0].value, U256::from(1));
        assert_eq!(decoded[0].call_data, inner);
        assert_eq!(decoded[1].target, other);
        assert_eq!(decoded[1].value, U256::from(2));
        assert!(decoded[1].call_data.is_empty());
    }

    #[test]
    fn rejects_delegate_and_unknown_exec_modes() {
        for call_type in [0xffu8, 0x02, 0x7f] {
            let mut mode = [0u8; 32];
            mode[0] = call_type;
            let encoded = Bytes::from(
                executeCall {
                    mode: mode.into(),
                    executionCalldata: Bytes::new(),
                }
                .abi_encode(),
            );
            assert!(
                decode_erc7579_executions(&encoded).is_none(),
                "call type {call_type:#x} must not decode"
            );
        }

        // A non-zero reserved tail is not a mode we understand.
        let mut mode = [0u8; 32];
        mode[31] = 0x01;
        let reserved = Bytes::from(
            executeCall {
                mode: mode.into(),
                executionCalldata: Bytes::new(),
            }
            .abi_encode(),
        );
        assert!(decode_erc7579_executions(&reserved).is_none());
    }

    #[test]
    fn rejects_malformed_execution_payloads() {
        // Not an execute() call at all.
        assert!(decode_erc7579_executions(&[0xde, 0xad, 0xbe, 0xef]).is_none());
        assert!(decode_erc7579_executions(&[]).is_none());

        // Single mode with fewer than the 52 packed header bytes.
        let mode = [0u8; 32];
        let truncated = Bytes::from(
            executeCall {
                mode: mode.into(),
                executionCalldata: Bytes::from(vec![0u8; 51]),
            }
            .abi_encode(),
        );
        assert!(decode_erc7579_executions(&truncated).is_none());

        // Batch mode whose payload is not a valid Execution[].
        let mut batch_mode = [0u8; 32];
        batch_mode[0] = 0x01;
        let garbage = Bytes::from(
            executeCall {
                mode: batch_mode.into(),
                executionCalldata: Bytes::from(vec![0xaa; 33]),
            }
            .abi_encode(),
        );
        assert!(decode_erc7579_executions(&garbage).is_none());
    }

    #[test]
    fn suggests_headroom_proportional_to_execution_count() {
        let cap = U256::from(10_000_000u64);
        let target = ENTRY_POINT_V07;
        let inner = Bytes::from_static(&[0x01]);

        let single = encode_erc7579_single_execution(target, U256::ZERO, inner.clone());
        assert_eq!(
            suggested_unestimated_call_gas_limit(&single, cap),
            U256::from(600_000u64)
        );

        let batch = encode_batch_execution(&[
            (target, U256::ZERO, inner.clone()),
            (target, U256::ZERO, inner.clone()),
            (target, U256::ZERO, inner),
        ]);
        assert_eq!(
            suggested_unestimated_call_gas_limit(&batch, cap),
            U256::from(1_400_000u64)
        );
    }

    #[test]
    fn clamps_suggested_headroom_to_policy_cap() {
        let cap = U256::from(1_000_000u64);
        let target = ENTRY_POINT_V07;
        let inner = Bytes::from_static(&[0x01]);
        let batch = encode_batch_execution(&[
            (target, U256::ZERO, inner.clone()),
            (target, U256::ZERO, inner.clone()),
            (target, U256::ZERO, inner),
        ]);

        // Raw suggestion would be 1_400_000; the cap wins.
        assert_eq!(suggested_unestimated_call_gas_limit(&batch, cap), cap);
    }

    #[test]
    fn falls_back_to_single_execution_headroom_when_undecodable() {
        let cap = U256::from(10_000_000u64);

        // Undecodable calldata must still yield a usable suggestion, not zero.
        assert_eq!(
            suggested_unestimated_call_gas_limit(&[0xde, 0xad, 0xbe, 0xef], cap),
            U256::from(600_000u64)
        );

        // An empty batch decodes fine but must not suggest base-only headroom.
        let empty_batch = encode_batch_execution(&[]);
        assert_eq!(
            suggested_unestimated_call_gas_limit(&empty_batch, cap),
            U256::from(600_000u64)
        );
    }
}
