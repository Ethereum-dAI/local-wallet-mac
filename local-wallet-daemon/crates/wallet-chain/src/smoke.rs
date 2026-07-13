use crate::adapter::ChainAdapter;
use crate::error::ChainError;
use crate::types::{AccountOverride, Address, BlockTag, Bytes, CallRequest, StateOverride, B256};
use alloy_primitives::{address, b256};

// Assembly:
// PUSH4 0xdeadbeef; PUSH1 0x00; MSTORE;
// PUSH1 0x01; SLOAD; PUSH1 0x20; MSTORE;
// PUSH1 0x40; PUSH1 0x00; RETURN
pub const STUB_BYTECODE: &[u8] = &[
    0x63, 0xDE, 0xAD, 0xBE, 0xEF, 0x60, 0x00, 0x52, 0x60, 0x01, 0x54, 0x60, 0x20, 0x52, 0x60, 0x40,
    0x60, 0x00, 0xF3,
];
pub const STUB_MAGIC: [u8; 4] = [0xDE, 0xAD, 0xBE, 0xEF];
pub const TARGET_ADDRESS: Address = address!("C02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2");
pub const TARGET_SLOT: B256 =
    b256!("0000000000000000000000000000000000000000000000000000000000000001");

pub async fn run_smoke_test(adapter: &(impl ChainAdapter + ?Sized)) -> Result<(), ChainError> {
    let head = adapter.current_head().await?;
    let block = BlockTag::Hash(head.hash);
    let expected_storage = adapter
        .eth_get_storage_at(TARGET_ADDRESS, TARGET_SLOT, block)
        .await?;
    let tx = smoke_call_request();
    let state_overrides = smoke_state_override();

    let with_override = adapter
        .eth_call(tx.clone(), block, Some(state_overrides))
        .await
        .map_err(|_| ChainError::StateOverrideUnsupported)?;

    if !has_magic(&with_override) || with_override.get(32..64) != Some(expected_storage.as_slice())
    {
        return Err(ChainError::StateOverrideUnsupported);
    }

    if let Ok(without_override) = adapter.eth_call(tx, block, None).await {
        if has_magic(&without_override) {
            return Err(ChainError::StateOverrideUnsupported);
        }
    }

    Ok(())
}

fn smoke_call_request() -> CallRequest {
    CallRequest {
        to: Some(TARGET_ADDRESS),
        ..CallRequest::default()
    }
}

fn smoke_state_override() -> StateOverride {
    let mut state_overrides = StateOverride::new();
    state_overrides.insert(
        TARGET_ADDRESS,
        AccountOverride {
            code: Some(Bytes::from(STUB_BYTECODE.to_vec())),
            ..AccountOverride::default()
        },
    );
    state_overrides
}

fn has_magic(response: &Bytes) -> bool {
    response
        .get(28..32)
        .is_some_and(|bytes| bytes == STUB_MAGIC)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mock::MockChainAdapter;
    use crate::types::{BlockHeader, U256};

    fn hash(byte: u8) -> B256 {
        B256::from([byte; 32])
    }

    fn header() -> BlockHeader {
        BlockHeader {
            number: 42,
            hash: hash(1),
            parent_hash: hash(2),
            timestamp: 1_700_000_000,
            state_root: Some(hash(3)),
            transactions_root: Some(hash(4)),
            receipts_root: Some(hash(5)),
            gas_used: Some(21_000),
            gas_limit: Some(30_000_000),
            base_fee_per_gas: Some(U256::from(1_000_000_000_u64)),
        }
    }

    fn response_with_magic(storage: B256) -> Bytes {
        let mut response = vec![0; 64];
        response[28..32].copy_from_slice(&STUB_MAGIC);
        response[32..64].copy_from_slice(storage.as_slice());
        Bytes::from(response)
    }

    fn response_without_magic() -> Bytes {
        Bytes::from(vec![0xaa; 64])
    }

    fn configured_adapter(with_override: Bytes, without_override: Bytes) -> MockChainAdapter {
        let adapter = MockChainAdapter::new();
        let head = header();
        let block = BlockTag::Hash(head.hash);
        adapter
            .set_current_head(head)
            .set_storage_at(TARGET_ADDRESS, TARGET_SLOT, block, hash(9))
            .set_call_response(
                smoke_call_request(),
                block,
                Some(smoke_state_override()),
                with_override,
            )
            .set_call_response(smoke_call_request(), block, None, without_override);
        adapter
    }

    #[tokio::test]
    async fn test_smoke_pass() {
        let adapter = configured_adapter(response_with_magic(hash(9)), response_without_magic());

        assert!(run_smoke_test(&adapter).await.is_ok());
    }

    #[tokio::test]
    async fn test_smoke_fail_no_magic() {
        let adapter = configured_adapter(response_without_magic(), response_without_magic());

        assert!(matches!(
            run_smoke_test(&adapter).await,
            Err(ChainError::StateOverrideUnsupported)
        ));
    }

    #[tokio::test]
    async fn test_smoke_fail_override_leaked() {
        let adapter =
            configured_adapter(response_with_magic(hash(9)), response_with_magic(hash(9)));

        assert!(matches!(
            run_smoke_test(&adapter).await,
            Err(ChainError::StateOverrideUnsupported)
        ));
    }
}
