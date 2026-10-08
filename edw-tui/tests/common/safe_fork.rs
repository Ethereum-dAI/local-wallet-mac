//! Helpers for tests that act on a real Safe on a mainnet fork.

use alloy_primitives::{Address, B256, keccak256};
use alloy_provider::{Provider, ProviderBuilder};
use alloy_sol_types::{SolCall, sol};

sol! {
    function getOwners() returns (address[]);
}

/// `owners` is the Safe's mapping at storage slot 2; slot of `owners[key]`.
pub fn owner_slot(key: Address) -> B256 {
    let mut word = [0u8; 64];
    word[12..32].copy_from_slice(key.as_slice());
    word[63] = 2;
    keccak256(word)
}

/// Makes `me` an owner of `safe` on the fork by taking the place of the first owner who is not in
/// `keep` (people whose signatures the test still needs). The Safe's owner list is a linked list
/// in storage; this relinks it, so the threshold and everyone else are unchanged.
pub async fn become_owner(rpc: &str, safe: Address, me: Address, keep: &[Address]) {
    let provider = ProviderBuilder::new().connect_http(rpc.parse().unwrap());
    let request = alloy_rpc_types_eth::TransactionRequest::default()
        .to(safe)
        .input(getOwnersCall {}.abi_encode().into());
    let owners = getOwnersCall::abi_decode_returns(&provider.call(request).await.unwrap()).unwrap();
    let at = owners
        .iter()
        .position(|o| !keep.contains(o))
        .expect("an owner who has not signed");
    let previous = if at == 0 {
        Address::with_last_byte(1)
    } else {
        owners[at - 1]
    };
    let replaced = owners[at];
    let after = provider
        .get_storage_at(safe, owner_slot(replaced).into())
        .await
        .unwrap();
    for (slot, value) in [
        (owner_slot(previous), B256::from(me.into_word())),
        (owner_slot(me), B256::from(after)),
        (owner_slot(replaced), B256::ZERO),
    ] {
        let _: serde_json::Value = provider
            .raw_request("anvil_setStorageAt".into(), (safe, slot, value))
            .await
            .unwrap();
    }
}
