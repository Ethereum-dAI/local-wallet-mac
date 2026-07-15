use crate::adapter::ChainAdapter;
use crate::error::ChainError;
use crate::types::{Address, BlockTag, Bytes, CallRequest};
use alloy_primitives::{address, hex};

/// RIP-7212 / EIP-7951 secp256r1 (P-256) signature verification precompile.
pub const P256_VERIFY_ADDRESS: Address = address!("0000000000000000000000000000000000000100");

// Known-valid P-256 signature vector (low-s normalised), independently verified
// off-chain. Layout expected by RIP-7212: hash || r || s || pubkey_x || pubkey_y
// (160 bytes). Sourced from the wallet-signature integration test (real Secure
// Enclave output); `hash` is the sha256 signing message, not the UserOp hash.
const PROBE_MESSAGE_HASH: [u8; 32] =
    hex!("4793eac07d8740aa367f813f52b43e30352fde2f79e43b8879a14e39eb7dbfd5");
const PROBE_R: [u8; 32] = hex!("885942f43a854e3f832b1e326fef2faa2e9145366c5ad0198e807e6cb4d32ea3");
const PROBE_S: [u8; 32] = hex!("2d00177c5e8d1cc58156cbd1f2aa4f17ec4d7b250e4328f0bd585c10b32c67cf");
const PROBE_PUBKEY_X: [u8; 32] =
    hex!("8ea35f44f5e75314e34c77b893cc5f07e1c8c239db11263ae8c839af1d5dd2a0");
const PROBE_PUBKEY_Y: [u8; 32] =
    hex!("61d745ab16afdb60a42a8385f5e4823476078d44c023089b2d04c006310208b5");

/// Probe whether the chain exposes the RIP-7212 P-256 verification precompile.
///
/// Returns `Ok(true)` when the precompile verifies the known-valid vector (returns
/// the 32-byte success word), `Ok(false)` when the precompile is absent or returns a
/// non-success result, and `Err` on a chain/transport error (caller should treat as
/// unavailable and may retry).
pub async fn probe_p256_precompile(
    adapter: &(impl ChainAdapter + ?Sized),
) -> Result<bool, ChainError> {
    let head = adapter.current_head().await?;
    let block = BlockTag::Hash(head.hash);
    let output = adapter.eth_call(probe_call_request(), block, None).await?;
    Ok(is_success_word(&output))
}

fn probe_call_request() -> CallRequest {
    let mut input = Vec::with_capacity(160);
    input.extend_from_slice(&PROBE_MESSAGE_HASH);
    input.extend_from_slice(&PROBE_R);
    input.extend_from_slice(&PROBE_S);
    input.extend_from_slice(&PROBE_PUBKEY_X);
    input.extend_from_slice(&PROBE_PUBKEY_Y);
    CallRequest {
        to: Some(P256_VERIFY_ADDRESS),
        data: Some(Bytes::from(input)),
        ..CallRequest::default()
    }
}

/// RIP-7212 returns a 32-byte big-endian `1` on success and empty output on failure
/// or when the precompile is absent (a call to an address with no code succeeds with
/// empty return data).
fn is_success_word(output: &Bytes) -> bool {
    output.len() == 32 && output[31] == 1 && output[..31].iter().all(|byte| *byte == 0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mock::MockChainAdapter;
    use crate::types::{BlockHeader, B256, U256};

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

    fn success_word() -> Bytes {
        let mut word = vec![0u8; 32];
        word[31] = 1;
        Bytes::from(word)
    }

    fn configured_adapter(response: Bytes) -> MockChainAdapter {
        let adapter = MockChainAdapter::new();
        let head = header();
        let block = BlockTag::Hash(head.hash);
        adapter.set_current_head(head).set_call_response(
            probe_call_request(),
            block,
            None,
            response,
        );
        adapter
    }

    #[tokio::test]
    async fn detects_available_precompile() {
        let adapter = configured_adapter(success_word());

        assert!(probe_p256_precompile(&adapter)
            .await
            .expect("probe should not error"));
    }

    #[tokio::test]
    async fn detects_absent_precompile_from_empty_output() {
        let adapter = configured_adapter(Bytes::new());

        assert!(!probe_p256_precompile(&adapter)
            .await
            .expect("probe should not error"));
    }

    #[tokio::test]
    async fn rejects_zero_word_output() {
        let adapter = configured_adapter(Bytes::from(vec![0u8; 32]));

        assert!(!probe_p256_precompile(&adapter)
            .await
            .expect("probe should not error"));
    }
}
