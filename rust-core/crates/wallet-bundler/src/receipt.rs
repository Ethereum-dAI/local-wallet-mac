use alloy_primitives::{keccak256, Address, B256, U256};
use wallet_chain::Log;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UserOperationEvent {
    pub log: Log,
    pub nonce: U256,
    pub success: bool,
    pub actual_gas_cost: U256,
    pub actual_gas_used: U256,
}

pub fn user_operation_event_topic() -> B256 {
    keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)")
}

pub fn extract_user_operation_event(
    logs: &[Log],
    entry_point: Address,
    user_op_hash: B256,
    sender: Address,
    nonce: U256,
) -> Option<UserOperationEvent> {
    let topic0 = user_operation_event_topic();
    let sender_topic = address_topic(sender);
    logs.iter()
        .filter_map(|log| {
            if log.address != entry_point
                || log.topics.len() < 4
                || log.topics[0] != topic0
                || log.topics[1] != user_op_hash
                || log.topics[2] != sender_topic
            {
                return None;
            }
            let decoded = decode_user_operation_event_data(log.data.as_ref())?;
            (decoded.nonce == nonce).then(|| UserOperationEvent {
                log: log.clone(),
                nonce: decoded.nonce,
                success: decoded.success,
                actual_gas_cost: decoded.actual_gas_cost,
                actual_gas_used: decoded.actual_gas_used,
            })
        })
        .next()
}

struct DecodedUserOperationEventData {
    nonce: U256,
    success: bool,
    actual_gas_cost: U256,
    actual_gas_used: U256,
}

fn decode_user_operation_event_data(data: &[u8]) -> Option<DecodedUserOperationEventData> {
    if data.len() != 128 {
        return None;
    }
    let nonce = U256::from_be_slice(&data[0..32]);
    let success_word = U256::from_be_slice(&data[32..64]);
    let success = if success_word == U256::from(0) {
        false
    } else if success_word == U256::from(1) {
        true
    } else {
        return None;
    };
    let actual_gas_cost = U256::from_be_slice(&data[64..96]);
    let actual_gas_used = U256::from_be_slice(&data[96..128]);
    Some(DecodedUserOperationEventData {
        nonce,
        success,
        actual_gas_cost,
        actual_gas_used,
    })
}

fn address_topic(address: Address) -> B256 {
    let mut bytes = [0u8; 32];
    bytes[12..].copy_from_slice(address.as_slice());
    B256::from(bytes)
}

#[cfg(test)]
mod tests {
    use alloy_primitives::{address, b256, Bytes};
    use wallet_chain::Log;

    use super::*;

    #[test]
    fn requires_matching_entrypoint_event() {
        let sender = address!("d73c7780b1c1da1586a8332d5499f36b7cbb33c2");
        let hash = b256!("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        let nonce = U256::from(7);
        let actual_gas_cost = U256::from(1_234);
        let actual_gas_used = U256::from(45_678);
        let log = Log {
            address: crate::ENTRY_POINT_V07,
            topics: vec![
                user_operation_event_topic(),
                hash,
                address_topic(sender),
                address_topic(Address::ZERO),
            ],
            data: event_data(nonce, true, actual_gas_cost, actual_gas_used),
            block_hash: None,
            block_number: None,
            transaction_hash: None,
            transaction_index: None,
            log_index: None,
            removed: None,
        };

        let event =
            extract_user_operation_event(&[log], crate::ENTRY_POINT_V07, hash, sender, nonce)
                .unwrap();
        assert!(event.success);
        assert_eq!(event.nonce, nonce);
        assert_eq!(event.actual_gas_cost, actual_gas_cost);
        assert_eq!(event.actual_gas_used, actual_gas_used);
    }

    #[test]
    fn rejects_mismatched_event_nonce() {
        let sender = address!("d73c7780b1c1da1586a8332d5499f36b7cbb33c2");
        let hash = b256!("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        let log = Log {
            address: crate::ENTRY_POINT_V07,
            topics: vec![
                user_operation_event_topic(),
                hash,
                address_topic(sender),
                address_topic(Address::ZERO),
            ],
            data: event_data(U256::from(8), true, U256::from(1), U256::from(2)),
            block_hash: None,
            block_number: None,
            transaction_hash: None,
            transaction_index: None,
            log_index: None,
            removed: None,
        };

        assert!(extract_user_operation_event(
            &[log],
            crate::ENTRY_POINT_V07,
            hash,
            sender,
            U256::from(7)
        )
        .is_none());
    }

    fn event_data(
        nonce: U256,
        success: bool,
        actual_gas_cost: U256,
        actual_gas_used: U256,
    ) -> Bytes {
        let mut bytes = Vec::with_capacity(128);
        bytes.extend_from_slice(&nonce.to_be_bytes::<32>());
        bytes.extend_from_slice(&U256::from(success as u8).to_be_bytes::<32>());
        bytes.extend_from_slice(&actual_gas_cost.to_be_bytes::<32>());
        bytes.extend_from_slice(&actual_gas_used.to_be_bytes::<32>());
        bytes.into()
    }
}
