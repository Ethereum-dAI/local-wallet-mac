mod common;

use alloy_primitives::{keccak256, Address, Bytes, B256, U256};
use alloy_sol_types::{SolCall, SolValue};
use p256::ecdsa::SigningKey;
use serde_json::{json, Value};
use wallet_bundler::{
    erc1967_implementation_address, validate_counterfactual_kernel_account,
    validate_daimo_p256_verifier_code, validate_kernel_factory_code,
    validate_kernel_implementation_code, validate_kernel_root_validator,
    validate_webauthn_validator_code, DAIMO_P256_VERIFIER_ADDRESS, ERC1967_IMPLEMENTATION_SLOT,
    MAINNET_CHAIN_ID, PINNED_KERNEL_FACTORY_ADDRESS, PINNED_KERNEL_IMPLEMENTATION_ADDRESS,
    PINNED_WEBAUTHN_VALIDATOR_ADDRESS, SOLADY_ERC1967_PROXY_RUNTIME_HASH,
};

use common::*;

const FORK_BUNDLER_EOA: &str = "0xB000000000000000000000000000000000000001";
const FORK_ROTATED_BUNDLER_EOA: &str = "0xB000000000000000000000000000000000000002";
const TRANSFER_RECIPIENT: &str = "0x1000000000000000000000000000000000000001";
const FLATNESS_SEND_COUNT: u64 = 50;
const FLATNESS_MAX_FEE_PER_GAS: u64 = 10_000_000_000;
const FLATNESS_MAX_PRIORITY_FEE_PER_GAS: u64 = 1_000_000_000;
const P256_GENERATOR_X: &str = "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296";
const P256_GENERATOR_Y: &str = "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5";

#[tokio::test]
#[ignore = "requires an Anvil Ethereum mainnet fork; run scripts/run-kernel-mainnet-fork-check.sh"]
async fn pinned_kernel_factory_path_validates_on_mainnet_fork() {
    let rpc_url = std::env::var("WALLET_MAINNET_FORK_RPC_URL")
        .expect("set WALLET_MAINNET_FORK_RPC_URL to an Anvil mainnet-fork RPC URL");
    let client = reqwest::Client::new();

    let factory_code = eth_get_code(&client, &rpc_url, PINNED_KERNEL_FACTORY_ADDRESS).await;
    validate_kernel_factory_code(
        MAINNET_CHAIN_ID,
        PINNED_KERNEL_FACTORY_ADDRESS,
        &factory_code,
    )
    .unwrap();

    let implementation_code =
        eth_get_code(&client, &rpc_url, PINNED_KERNEL_IMPLEMENTATION_ADDRESS).await;
    validate_kernel_implementation_code(
        MAINNET_CHAIN_ID,
        PINNED_KERNEL_IMPLEMENTATION_ADDRESS,
        &implementation_code,
    )
    .unwrap();

    let webauthn_validator_code =
        eth_get_code(&client, &rpc_url, PINNED_WEBAUTHN_VALIDATOR_ADDRESS).await;
    validate_webauthn_validator_code(MAINNET_CHAIN_ID, &webauthn_validator_code).unwrap();

    let daimo_verifier_code = eth_get_code(&client, &rpc_url, DAIMO_P256_VERIFIER_ADDRESS).await;
    validate_daimo_p256_verifier_code(MAINNET_CHAIN_ID, &daimo_verifier_code).unwrap();

    let salt = B256::ZERO;
    let init_data = wallet_kernel::encode_initialize_call(
        PINNED_WEBAUTHN_VALIDATOR_ADDRESS,
        u256_from_hex(P256_GENERATOR_X),
        u256_from_hex(P256_GENERATOR_Y),
        B256::ZERO,
    );
    let factory_data = Bytes::from(
        createAccountCall {
            initData: Bytes::from(init_data.clone()),
            salt,
        }
        .abi_encode(),
    );
    let actual_salt = wallet_kernel::compute_actual_salt(&init_data, salt);
    let init_code_hash =
        wallet_kernel::erc1967_init_code_hash(PINNED_KERNEL_IMPLEMENTATION_ADDRESS);
    let predicted_sender = wallet_kernel::predict_create2_address(
        PINNED_KERNEL_FACTORY_ADDRESS,
        actual_salt,
        init_code_hash,
    );

    validate_counterfactual_kernel_account(
        MAINNET_CHAIN_ID,
        predicted_sender,
        U256::ZERO,
        Some(PINNED_KERNEL_FACTORY_ADDRESS),
        &factory_data,
    )
    .unwrap();

    let returned = eth_call(
        &client,
        &rpc_url,
        PINNED_KERNEL_FACTORY_ADDRESS,
        factory_data.clone(),
    )
    .await;
    let returned_account = createAccountCall::abi_decode_returns(&returned).unwrap();
    assert_eq!(returned_account, predicted_sender);

    let tx_hash = eth_send_transaction(
        &client,
        &rpc_url,
        ANVIL_DEFAULT_SENDER,
        PINNED_KERNEL_FACTORY_ADDRESS,
        factory_data,
    )
    .await;
    wait_for_successful_receipt(&client, &rpc_url, &tx_hash).await;

    let deployed_code = eth_get_code(&client, &rpc_url, predicted_sender).await;
    assert_eq!(keccak256(&deployed_code), SOLADY_ERC1967_PROXY_RUNTIME_HASH);

    let implementation_word = eth_get_storage_at(
        &client,
        &rpc_url,
        predicted_sender,
        ERC1967_IMPLEMENTATION_SLOT,
    )
    .await;
    let implementation = erc1967_implementation_address(implementation_word).unwrap();
    assert_eq!(implementation, PINNED_KERNEL_IMPLEMENTATION_ADDRESS);

    let root_validator = eth_call(
        &client,
        &rpc_url,
        predicted_sender,
        Bytes::from(rootValidatorCall {}.abi_encode()),
    )
    .await;
    let root_validator = rootValidatorCall::abi_decode_returns(&root_validator).unwrap();
    validate_kernel_root_validator(predicted_sender, root_validator).unwrap();

    let initial_deposit = entry_point_balance_of(&client, &rpc_url, predicted_sender).await;
    assert_eq!(initial_deposit, U256::ZERO);

    let deposit_amount = U256::from(1_000_000_000_000_000_u64);
    let deposit_tx = eth_send_transaction_with_value(
        &client,
        &rpc_url,
        ANVIL_DEFAULT_SENDER,
        wallet_bundler::ENTRY_POINT_V07,
        Bytes::from(
            depositToCall {
                account: predicted_sender,
            }
            .abi_encode(),
        ),
        Some(deposit_amount),
    )
    .await;
    wait_for_successful_receipt(&client, &rpc_url, &deposit_tx).await;
    assert_eq!(
        entry_point_balance_of(&client, &rpc_url, predicted_sender).await,
        deposit_amount
    );

    let op = simulated_deployed_user_op(predicted_sender)
        .with_verification_gas_limit(U256::from(1_000_000_u64))
        .with_signature(wallet_bundler::dummy_webauthn_signature(false));
    let runtime = wallet_bundler::entry_point_simulations_runtime_bytecode().unwrap();
    let dummy_validation = wallet_bundler::decode_validation_result(
        &eth_call_with_state_override(
            &client,
            &rpc_url,
            wallet_bundler::ENTRY_POINT_V07,
            wallet_bundler::encode_simulate_validation(&op).unwrap(),
            json!({
                address_hex(wallet_bundler::ENTRY_POINT_V07): {
                    "code": bytes_hex(&runtime)
                }
            }),
        )
        .await,
    )
    .unwrap();
    assert!(dummy_validation.sig_failed);

    let low_gas_op = simulated_deployed_user_op(predicted_sender)
        .with_signature(wallet_bundler::dummy_webauthn_signature(false));
    let revert_data = eth_call_revert_data_with_state_override(
        &client,
        &rpc_url,
        wallet_bundler::ENTRY_POINT_V07,
        wallet_bundler::encode_simulate_validation(&low_gas_op).unwrap(),
        json!({
            address_hex(wallet_bundler::ENTRY_POINT_V07): {
                "code": bytes_hex(&runtime)
            }
        }),
    )
    .await;
    assert_eq!(
        wallet_bundler::simulation_revert_reason(&revert_data),
        "AA23 reverted"
    );

    let signing_key = SigningKey::from_bytes(&TEST_P256_PRIVATE_KEY.into()).unwrap();
    let (pubkey_x, pubkey_y) = p256_public_key_coordinates(signing_key.verifying_key());
    let signed_init_data = wallet_kernel::encode_initialize_call(
        PINNED_WEBAUTHN_VALIDATOR_ADDRESS,
        U256::from_be_slice(&pubkey_x),
        U256::from_be_slice(&pubkey_y),
        B256::ZERO,
    );
    let signed_factory_data = Bytes::from(
        createAccountCall {
            initData: Bytes::from(signed_init_data.clone()),
            salt,
        }
        .abi_encode(),
    );
    let signed_actual_salt = wallet_kernel::compute_actual_salt(&signed_init_data, salt);
    let signed_sender = wallet_kernel::predict_create2_address(
        PINNED_KERNEL_FACTORY_ADDRESS,
        signed_actual_salt,
        init_code_hash,
    );
    validate_counterfactual_kernel_account(
        MAINNET_CHAIN_ID,
        signed_sender,
        U256::ZERO,
        Some(PINNED_KERNEL_FACTORY_ADDRESS),
        &signed_factory_data,
    )
    .unwrap();

    let signed_tx_hash = eth_send_transaction(
        &client,
        &rpc_url,
        ANVIL_DEFAULT_SENDER,
        PINNED_KERNEL_FACTORY_ADDRESS,
        signed_factory_data,
    )
    .await;
    wait_for_successful_receipt(&client, &rpc_url, &signed_tx_hash).await;
    assert_eq!(
        keccak256(&eth_get_code(&client, &rpc_url, signed_sender).await),
        SOLADY_ERC1967_PROXY_RUNTIME_HASH
    );
    let stored_pubkey = webauthn_validator_storage(&client, &rpc_url, signed_sender).await;
    assert_eq!(
        stored_pubkey,
        (
            U256::from_be_slice(&pubkey_x),
            U256::from_be_slice(&pubkey_y)
        )
    );

    let signed_deposit_tx = eth_send_transaction_with_value(
        &client,
        &rpc_url,
        ANVIL_DEFAULT_SENDER,
        wallet_bundler::ENTRY_POINT_V07,
        Bytes::from(
            depositToCall {
                account: signed_sender,
            }
            .abi_encode(),
        ),
        Some(deposit_amount),
    )
    .await;
    wait_for_successful_receipt(&client, &rpc_url, &signed_deposit_tx).await;

    let unsigned_signed_op = realistic_deployed_user_op(signed_sender, U256::ZERO);
    let user_op_hash = entry_point_user_op_hash(&client, &rpc_url, &unsigned_signed_op).await;
    let signed = sign_user_op_for_test(unsigned_signed_op, user_op_hash, &signing_key, false);
    assert_eq!(
        daimo_p256_verify(
            &client,
            &rpc_url,
            signed.message_hash,
            signed.r,
            signed.s,
            U256::from_be_slice(&pubkey_x),
            U256::from_be_slice(&pubkey_y)
        )
        .await,
        U256::from(1)
    );
    let signed_op = signed.op;
    assert_eq!(
        webauthn_is_valid_signature(
            &client,
            &rpc_url,
            signed_sender,
            user_op_hash,
            signed_op.signature.clone()
        )
        .await,
        [0x16, 0x26, 0xba, 0x7e]
    );
    let account_validation_data =
        kernel_validate_user_op(&client, &rpc_url, signed_sender, &signed_op, user_op_hash).await;
    assert_ne!(account_validation_data, U256::from(1));
    let raw_validation = eth_call_with_state_override(
        &client,
        &rpc_url,
        wallet_bundler::ENTRY_POINT_V07,
        wallet_bundler::encode_simulate_validation(&signed_op).unwrap(),
        json!({
            address_hex(wallet_bundler::ENTRY_POINT_V07): {
                "code": bytes_hex(&runtime)
            }
        }),
    )
    .await;
    let validation = wallet_bundler::decode_validation_result(&raw_validation).unwrap();
    assert!(!validation.sig_failed);
    wallet_bundler::validate_validation_result(
        &validation,
        0,
        0,
        0,
        u64::MAX,
        wallet_bundler::SimulationMode::Submit,
    )
    .unwrap();

    let transfer_recipient: Address = TRANSFER_RECIPIENT.parse().unwrap();
    let transfer_amount = U256::from(12_345_u64);
    let fund_transfer_tx = eth_send_transaction_with_value(
        &client,
        &rpc_url,
        ANVIL_DEFAULT_SENDER,
        signed_sender,
        Bytes::new(),
        Some(transfer_amount),
    )
    .await;
    wait_for_successful_receipt(&client, &rpc_url, &fund_transfer_tx).await;
    assert_eq!(
        eth_get_balance(&client, &rpc_url, signed_sender).await,
        transfer_amount
    );

    let transfer_op = realistic_transfer_user_op(
        signed_sender,
        U256::ZERO,
        transfer_recipient,
        transfer_amount,
    );
    let transfer_hash = entry_point_user_op_hash(&client, &rpc_url, &transfer_op).await;
    // Sign with usePrecompiled=true so on-chain validation routes the passkey
    // signature through the RIP-7212 / EIP-7951 P-256 precompile (0x100) instead of
    // the Daimo verifier. This exercises the full handleOps path (validate + execute)
    // through the precompile end to end (issue #42). The false/Daimo execution path
    // remains covered by the 50-send flatness loop below.
    let signed_transfer = sign_user_op_for_test(transfer_op, transfer_hash, &signing_key, true).op;
    // Guard: the usePrecompiled flag must actually change the encoded signature,
    // otherwise the "precompile path" would silently collapse to the Daimo path.
    let daimo_signed_variant = sign_user_op_for_test(
        realistic_transfer_user_op(
            signed_sender,
            U256::ZERO,
            transfer_recipient,
            transfer_amount,
        ),
        transfer_hash,
        &signing_key,
        false,
    )
    .op;
    assert_ne!(
        signed_transfer.signature, daimo_signed_variant.signature,
        "usePrecompiled=true must produce a different encoded signature than the Daimo path"
    );
    // The Kernel WebAuthnValidator must accept the precompile-encoded signature
    // (ERC-1271 magic value), proving it invokes 0x100 and the precompile verifies.
    assert_eq!(
        webauthn_is_valid_signature(
            &client,
            &rpc_url,
            signed_sender,
            transfer_hash,
            signed_transfer.signature.clone()
        )
        .await,
        [0x16, 0x26, 0xba, 0x7e],
        "WebAuthnValidator must validate the usePrecompiled=true signature via RIP-7212"
    );
    let transfer_validation = wallet_bundler::decode_validation_result(
        &eth_call_with_state_override(
            &client,
            &rpc_url,
            wallet_bundler::ENTRY_POINT_V07,
            wallet_bundler::encode_simulate_validation(&signed_transfer).unwrap(),
            json!({
                address_hex(wallet_bundler::ENTRY_POINT_V07): {
                    "code": bytes_hex(&runtime)
                }
            }),
        )
        .await,
    )
    .unwrap();
    assert!(!transfer_validation.sig_failed);

    let recipient_before = eth_get_balance(&client, &rpc_url, transfer_recipient).await;
    let handle_ops_tx = eth_send_transaction(
        &client,
        &rpc_url,
        ANVIL_DEFAULT_SENDER,
        wallet_bundler::ENTRY_POINT_V07,
        wallet_bundler::encode_handle_ops(&signed_transfer, ANVIL_DEFAULT_SENDER.parse().unwrap())
            .unwrap(),
    )
    .await;
    wait_for_successful_receipt(&client, &rpc_url, &handle_ops_tx).await;
    assert_eq!(
        eth_get_balance(&client, &rpc_url, transfer_recipient).await,
        recipient_before + transfer_amount
    );

    let flatness_funding = U256::from(1_000_000_000_000_000_000_u64);
    let fund_flatness_tx = eth_send_transaction_with_value(
        &client,
        &rpc_url,
        ANVIL_DEFAULT_SENDER,
        signed_sender,
        Bytes::new(),
        Some(flatness_funding),
    )
    .await;
    wait_for_successful_receipt(&client, &rpc_url, &fund_flatness_tx).await;

    let bundler_eoa: Address = FORK_BUNDLER_EOA.parse().unwrap();
    assert!(
        eth_get_code(&client, &rpc_url, bundler_eoa)
            .await
            .is_empty(),
        "fork bundler EOA must not have mainnet code"
    );
    anvil_impersonate_account(&client, &rpc_url, FORK_BUNDLER_EOA).await;
    anvil_set_balance(
        &client,
        &rpc_url,
        bundler_eoa,
        U256::from(1_000_000_000_000_000_000_u64),
    )
    .await;
    let bundler_before = eth_get_balance(&client, &rpc_url, bundler_eoa).await;
    let account_before = eth_get_balance(&client, &rpc_url, signed_sender).await;
    let account_deposit_before = entry_point_balance_of(&client, &rpc_url, signed_sender).await;
    let flatness_recipient_before = eth_get_balance(&client, &rpc_url, transfer_recipient).await;
    let mut total_tx_fee_paid = U256::ZERO;
    let mut total_user_op_actual_gas_cost = U256::ZERO;
    let mut total_transfer_value = U256::ZERO;
    let max_fee_per_gas = U256::from(FLATNESS_MAX_FEE_PER_GAS);
    let max_priority_fee_per_gas = U256::from(FLATNESS_MAX_PRIORITY_FEE_PER_GAS);

    for index in 0..FLATNESS_SEND_COUNT {
        let nonce = U256::from(index + 1);
        let amount = U256::from(1_u64);
        total_transfer_value += amount;
        let op = realistic_transfer_user_op_with_fees(
            signed_sender,
            nonce,
            transfer_recipient,
            amount,
            max_fee_per_gas,
            max_priority_fee_per_gas,
        );
        let hash = entry_point_user_op_hash(&client, &rpc_url, &op).await;
        let signed_op = sign_user_op_for_test(op, hash, &signing_key, false).op;
        let tx_hash = eth_send_transaction_with_fees(
            &client,
            &rpc_url,
            FORK_BUNDLER_EOA,
            wallet_bundler::ENTRY_POINT_V07,
            wallet_bundler::encode_handle_ops(&signed_op, bundler_eoa).unwrap(),
            max_fee_per_gas,
            max_priority_fee_per_gas,
        )
        .await;
        let receipt = wait_for_successful_receipt(&client, &rpc_url, &tx_hash).await;
        total_tx_fee_paid += receipt_fee_paid(&receipt);
        total_user_op_actual_gas_cost += user_operation_actual_gas_cost(&receipt);
    }

    let bundler_after = eth_get_balance(&client, &rpc_url, bundler_eoa).await;
    let account_after = eth_get_balance(&client, &rpc_url, signed_sender).await;
    let account_deposit_after = entry_point_balance_of(&client, &rpc_url, signed_sender).await;
    let flatness_recipient_after = eth_get_balance(&client, &rpc_url, transfer_recipient).await;
    let loss = bundler_before.saturating_sub(bundler_after);
    let gain = bundler_after.saturating_sub(bundler_before);
    let account_balance_debit = account_before.saturating_sub(account_after);
    let account_deposit_debit = account_deposit_before.saturating_sub(account_deposit_after);
    let account_deposit_credit = account_deposit_after.saturating_sub(account_deposit_before);
    let account_total_debit = account_balance_debit + account_deposit_debit;
    let account_total_credit = account_deposit_credit;
    let tolerance = total_tx_fee_paid / U256::from(100_u64);
    println!(
        "flatness sends={FLATNESS_SEND_COUNT} bundler_before={} bundler_after={} loss={} gain={} account_before={} account_after={} account_deposit_before={} account_deposit_after={} total_tx_fee_paid={} user_op_actual_gas_cost={} tolerance={}",
        u256_hex(bundler_before),
        u256_hex(bundler_after),
        u256_hex(loss),
        u256_hex(gain),
        u256_hex(account_before),
        u256_hex(account_after),
        u256_hex(account_deposit_before),
        u256_hex(account_deposit_after),
        u256_hex(total_tx_fee_paid),
        u256_hex(total_user_op_actual_gas_cost),
        u256_hex(tolerance)
    );
    assert!(
        loss <= tolerance,
        "bundler EOA loss {} exceeds tolerance {} over {} sends",
        u256_hex(loss),
        u256_hex(tolerance),
        FLATNESS_SEND_COUNT
    );
    assert_eq!(
        flatness_recipient_after,
        flatness_recipient_before + total_transfer_value
    );
    assert_eq!(
        account_total_debit,
        total_user_op_actual_gas_cost + total_transfer_value + account_total_credit
    );

    let rotated_bundler_eoa: Address = FORK_ROTATED_BUNDLER_EOA.parse().unwrap();
    assert!(
        eth_get_code(&client, &rpc_url, rotated_bundler_eoa)
            .await
            .is_empty(),
        "rotated fork bundler EOA must not have mainnet code"
    );
    anvil_impersonate_account(&client, &rpc_url, FORK_ROTATED_BUNDLER_EOA).await;
    anvil_set_balance(
        &client,
        &rpc_url,
        rotated_bundler_eoa,
        U256::from(1_000_000_000_000_000_000_u64),
    )
    .await;

    let pending_old_nonce = U256::from(FLATNESS_SEND_COUNT + 1);
    let pending_new_nonce = U256::from(FLATNESS_SEND_COUNT + 2);
    let old_relayer_op = realistic_transfer_user_op_with_fees(
        signed_sender,
        pending_old_nonce,
        transfer_recipient,
        U256::from(1_u64),
        max_fee_per_gas,
        max_priority_fee_per_gas,
    );
    let old_relayer_hash = entry_point_user_op_hash(&client, &rpc_url, &old_relayer_op).await;
    let old_relayer_signed =
        sign_user_op_for_test(old_relayer_op, old_relayer_hash, &signing_key, false).op;
    let new_relayer_op = realistic_transfer_user_op_with_fees(
        signed_sender,
        pending_new_nonce,
        transfer_recipient,
        U256::from(1_u64),
        max_fee_per_gas,
        max_priority_fee_per_gas,
    );
    let new_relayer_hash = entry_point_user_op_hash(&client, &rpc_url, &new_relayer_op).await;
    let new_relayer_signed =
        sign_user_op_for_test(new_relayer_op, new_relayer_hash, &signing_key, false).op;

    let old_relayer_before = eth_get_balance(&client, &rpc_url, bundler_eoa).await;
    let new_relayer_before = eth_get_balance(&client, &rpc_url, rotated_bundler_eoa).await;
    let rotation_recipient_before = eth_get_balance(&client, &rpc_url, transfer_recipient).await;
    anvil_set_automine(&client, &rpc_url, false).await;
    let old_pending_tx = eth_send_transaction_with_fees(
        &client,
        &rpc_url,
        FORK_BUNDLER_EOA,
        wallet_bundler::ENTRY_POINT_V07,
        wallet_bundler::encode_handle_ops(&old_relayer_signed, bundler_eoa).unwrap(),
        max_fee_per_gas,
        max_priority_fee_per_gas,
    )
    .await;
    assert!(
        eth_get_transaction_receipt(&client, &rpc_url, &old_pending_tx)
            .await
            .is_none(),
        "old relayer transaction should remain pending while automine is off"
    );
    let new_pending_tx = eth_send_transaction_with_fees(
        &client,
        &rpc_url,
        FORK_ROTATED_BUNDLER_EOA,
        wallet_bundler::ENTRY_POINT_V07,
        wallet_bundler::encode_handle_ops(&new_relayer_signed, rotated_bundler_eoa).unwrap(),
        max_fee_per_gas,
        max_priority_fee_per_gas,
    )
    .await;
    assert!(
        eth_get_transaction_receipt(&client, &rpc_url, &new_pending_tx)
            .await
            .is_none(),
        "rotated relayer transaction should also wait for manual mining"
    );
    anvil_mine(&client, &rpc_url).await;
    anvil_set_automine(&client, &rpc_url, true).await;

    let old_receipt = wait_for_successful_receipt(&client, &rpc_url, &old_pending_tx).await;
    let new_receipt = wait_for_successful_receipt(&client, &rpc_url, &new_pending_tx).await;
    let old_fee_paid = receipt_fee_paid(&old_receipt);
    let new_fee_paid = receipt_fee_paid(&new_receipt);
    let old_loss =
        old_relayer_before.saturating_sub(eth_get_balance(&client, &rpc_url, bundler_eoa).await);
    let new_loss = new_relayer_before
        .saturating_sub(eth_get_balance(&client, &rpc_url, rotated_bundler_eoa).await);
    assert!(
        old_loss <= old_fee_paid / U256::from(100_u64),
        "old relayer loss {} exceeds tolerance after pending rotation settlement",
        u256_hex(old_loss)
    );
    assert!(
        new_loss <= new_fee_paid / U256::from(100_u64),
        "rotated relayer loss {} exceeds tolerance after activation send",
        u256_hex(new_loss)
    );
    assert_eq!(
        eth_get_balance(&client, &rpc_url, transfer_recipient).await,
        rotation_recipient_before + U256::from(2_u64)
    );
}

async fn eth_get_storage_at(
    client: &reqwest::Client,
    rpc_url: &str,
    address: Address,
    slot: B256,
) -> B256 {
    let result: String = rpc(
        client,
        rpc_url,
        "eth_getStorageAt",
        json!([address_hex(address), b256_hex(slot), "latest"]),
    )
    .await;
    fixed_bytes(&result)
}

async fn eth_call_revert_data_with_state_override(
    client: &reqwest::Client,
    rpc_url: &str,
    to: Address,
    data: Bytes,
    state_override: Value,
) -> Bytes {
    let response = rpc_response(
        client,
        rpc_url,
        "eth_call",
        json!([
            { "to": address_hex(to), "data": bytes_hex(&data) },
            "latest",
            state_override
        ]),
    )
    .await;
    let error = response.error.expect("eth_call should revert");
    let data = error
        .data
        .and_then(|value| value.as_str().map(ToOwned::to_owned))
        .expect("revert should include data");
    hex_bytes(&data)
}

async fn eth_call_with_state_override(
    client: &reqwest::Client,
    rpc_url: &str,
    to: Address,
    data: Bytes,
    state_override: Value,
) -> Bytes {
    let response = rpc_response(
        client,
        rpc_url,
        "eth_call",
        json!([
            { "to": address_hex(to), "data": bytes_hex(&data) },
            "latest",
            state_override
        ]),
    )
    .await;
    if let Some(error) = response.error {
        panic!(
            "eth_call should return validation data, got error {}: {} {:?}",
            error.code, error.message, error.data
        );
    }
    let result = response
        .result
        .as_str()
        .expect("eth_call result should be hex data");
    hex_bytes(result)
}

async fn kernel_validate_user_op(
    client: &reqwest::Client,
    rpc_url: &str,
    account: Address,
    op: &wallet_bundler::UserOperation,
    user_op_hash: [u8; 32],
) -> U256 {
    let raw = eth_call_from(
        client,
        rpc_url,
        Some(wallet_bundler::ENTRY_POINT_V07),
        account,
        Bytes::from(
            validateUserOpCall {
                userOp: packed_user_operation_sol(op),
                userOpHash: B256::from(user_op_hash),
                missingAccountFunds: U256::ZERO,
            }
            .abi_encode(),
        ),
    )
    .await;
    U256::from_be_slice(&raw)
}

async fn webauthn_validator_storage(
    client: &reqwest::Client,
    rpc_url: &str,
    account: Address,
) -> (U256, U256) {
    let raw = eth_call(
        client,
        rpc_url,
        PINNED_WEBAUTHN_VALIDATOR_ADDRESS,
        Bytes::from(webAuthnValidatorStorageCall { kernel: account }.abi_encode()),
    )
    .await;
    webAuthnValidatorStorageCall::abi_decode_returns(&raw)
        .unwrap()
        .into()
}

async fn webauthn_is_valid_signature(
    client: &reqwest::Client,
    rpc_url: &str,
    account: Address,
    hash: [u8; 32],
    signature: Bytes,
) -> [u8; 4] {
    let raw = eth_call_from(
        client,
        rpc_url,
        Some(account),
        PINNED_WEBAUTHN_VALIDATOR_ADDRESS,
        Bytes::from(
            isValidSignatureWithSenderCall {
                sender: account,
                hash: B256::from(hash),
                data: signature,
            }
            .abi_encode(),
        ),
    )
    .await;
    isValidSignatureWithSenderCall::abi_decode_returns(&raw)
        .unwrap()
        .into()
}

async fn daimo_p256_verify(
    client: &reqwest::Client,
    rpc_url: &str,
    message_hash: B256,
    r: U256,
    s: U256,
    x: U256,
    y: U256,
) -> U256 {
    let raw = eth_call(
        client,
        rpc_url,
        DAIMO_P256_VERIFIER_ADDRESS,
        Bytes::from((message_hash, r, s, x, y).abi_encode()),
    )
    .await;
    U256::from_be_slice(&raw)
}
