use alloy_primitives::{Address, Bytes, U256};
use alloy_sol_types::{sol, SolCall};

use crate::reclaimable_entry_point_deposit;

sol! {
    function execute(bytes32 mode, bytes executionCalldata);
    function withdrawTo(address withdrawAddress, uint256 amount);
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
    if !is_single_call_mode(mode) || decoded.executionCalldata.len() < 52 {
        return None;
    }

    let mut target = [0u8; 20];
    target.copy_from_slice(&decoded.executionCalldata[..20]);

    Some(Erc7579SingleExecution {
        target: Address::from(target),
        value: U256::from_be_slice(&decoded.executionCalldata[20..52]),
        call_data: Bytes::copy_from_slice(&decoded.executionCalldata[52..]),
    })
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
    mode.len() == 32
        && mode[0] == 0x00
        && matches!(mode[1], 0x00 | 0x01)
        && mode[2..].iter().all(|byte| *byte == 0)
}

#[cfg(test)]
mod tests {
    use alloy_primitives::address;

    use super::*;

    #[test]
    fn decodes_erc7579_single_execution() {
        let target = address!("0000000071727De22E5E9d8BAf0edAc6f37da032");
        let inner = Bytes::from_static(&[0x20, 0x5c, 0x28, 0x78]);
        let call_data = encode_erc7579_single_execution(target, U256::from(7), inner.clone());

        let decoded = decode_erc7579_single_execution(&call_data).unwrap();

        assert_eq!(decoded.target, target);
        assert_eq!(decoded.value, U256::from(7));
        assert_eq!(decoded.call_data, inner);
    }

    #[test]
    fn rejects_batch_or_delegate_modes() {
        let target = address!("0000000071727De22E5E9d8BAf0edAc6f37da032");
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
        let entry_point = address!("0000000071727De22E5E9d8BAf0edAc6f37da032");
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
        let entry_point = address!("0000000071727De22E5E9d8BAf0edAc6f37da032");

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
        let entry_point = address!("0000000071727De22E5E9d8BAf0edAc6f37da032");
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
        let entry_point = address!("0000000071727De22E5E9d8BAf0edAc6f37da032");
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
}
