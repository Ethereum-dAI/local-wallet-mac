//! Whole-plan simulation against a real anvil. Skips when anvil is missing.

use alloy_node_bindings::Anvil;
use alloy_primitives::{Address, Bytes, I256, U256, address};
use edw_tui::skills::{plan::CheckedStep, simulate};

const BEEF: Address = address!("0x000000000000000000000000000000000000bEEF");

fn send(wei: u64) -> CheckedStep {
    CheckedStep {
        label: format!("send {wei} wei"),
        to: BEEF,
        value: U256::from(wei),
        data: Bytes::new(),
        approval: None,
    }
}

#[tokio::test]
async fn two_sends_are_simulated_in_one_block_and_netted() {
    let anvil = match Anvil::new().try_spawn() {
        Ok(anvil) => anvil,
        Err(error) => {
            eprintln!("skipping: cannot start anvil ({error})");
            return;
        }
    };
    let from = anvil.addresses()[0];
    let results = simulate::simulate(&anvil.endpoint_url(), from, &[send(5), send(7)])
        .await
        .unwrap();
    assert_eq!(results.len(), 2);
    assert!(results.iter().all(|r| r.ok), "{results:?}");
    let d = simulate::deltas(from, &results);
    assert_eq!(d.eth, I256::try_from(-12).unwrap());
    // Nothing was actually sent.
    let balance = alloy_provider::Provider::get_balance(
        &alloy_provider::ProviderBuilder::new().connect_http(anvil.endpoint_url()),
        BEEF,
    )
    .await
    .unwrap();
    assert_eq!(balance, U256::ZERO);
}
