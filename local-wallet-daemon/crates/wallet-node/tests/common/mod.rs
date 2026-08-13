//! Shared helpers for the Anvil fork integration tests (`mainnet_fork_kernel`,
//! `sepolia_fork_daemon_e2e`). These drive a forked chain over raw JSON-RPC and
//! sign Kernel WebAuthn UserOperations with a software P-256 key whose encoding
//! is byte-for-byte identical to the Secure Enclave path.
#![allow(dead_code)]

use alloy_primitives::{Address, Bytes, B256, U256};
use alloy_sol_types::{sol, SolCall};
use p256::ecdsa::{signature::Signer, Signature, SigningKey, VerifyingKey};
use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

sol! {
    struct PackedUserOperationSol {
        address sender;
        uint256 nonce;
        bytes initCode;
        bytes callData;
        bytes32 accountGasLimits;
        uint256 preVerificationGas;
        bytes32 gasFees;
        bytes paymasterAndData;
        bytes signature;
    }

    function createAccount(bytes initData, bytes32 salt) returns (address account);
    function rootValidator() view returns (bytes21);
    function getUserOpHash(PackedUserOperationSol userOp) view returns (bytes32);
    function replayableUserOpHash(PackedUserOperationSol userOp, address entryPoint) view returns (bytes32);
    function validateUserOp(PackedUserOperationSol userOp, bytes32 userOpHash, uint256 missingAccountFunds) returns (uint256);
    function webAuthnValidatorStorage(address kernel) view returns (uint256 pubKeyX, uint256 pubKeyY);
    function isValidSignatureWithSender(address sender, bytes32 hash, bytes data) view returns (bytes4);
    function balanceOf(address account) view returns (uint256);
    function depositTo(address account) payable;
}

pub const ANVIL_DEFAULT_SENDER: &str = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
pub const TEST_P256_PRIVATE_KEY: [u8; 32] = [
    0xc9, 0xaf, 0xa9, 0xd8, 0x45, 0xba, 0x75, 0x16, 0x6b, 0x5c, 0x21, 0x57, 0x67, 0xb1, 0xd6, 0x93,
    0x4e, 0x50, 0xc3, 0xdb, 0x36, 0xe8, 0x9b, 0x12, 0x7b, 0x8a, 0x62, 0x2b, 0x12, 0x0f, 0x67, 0x21,
];

pub fn address_hex(address: Address) -> String {
    format!("{address:#x}")
}

pub fn b256_hex(value: B256) -> String {
    format!("{value:#x}")
}

pub fn bytes_hex(bytes: &Bytes) -> String {
    format!("0x{}", hex::encode(bytes))
}

pub fn u256_hex(value: U256) -> String {
    format!("0x{:x}", value)
}

pub fn u256_from_hex(value: &str) -> U256 {
    U256::from_str_radix(value.strip_prefix("0x").unwrap_or(value), 16).unwrap()
}

pub fn hex_bytes(value: &str) -> Bytes {
    Bytes::from(hex::decode(value.strip_prefix("0x").unwrap_or(value)).unwrap())
}

pub fn fixed_bytes(value: &str) -> B256 {
    let bytes = hex::decode(value.strip_prefix("0x").unwrap_or(value)).unwrap();
    assert_eq!(bytes.len(), 32);
    B256::from_slice(&bytes)
}

pub fn receipt_fee_paid(receipt: &Value) -> U256 {
    let gas_used = receipt_u256(receipt, "gasUsed");
    let effective_gas_price = receipt_u256(receipt, "effectiveGasPrice");
    gas_used * effective_gas_price
}

pub fn receipt_u256(receipt: &Value, field: &str) -> U256 {
    let value = receipt
        .get(field)
        .and_then(Value::as_str)
        .unwrap_or_else(|| panic!("receipt is missing {field}"));
    U256::from_str_radix(value.strip_prefix("0x").unwrap_or(value), 16).unwrap()
}

pub fn user_operation_actual_gas_cost(receipt: &Value) -> U256 {
    let topic = format!("{:#x}", wallet_bundler::user_operation_event_topic());
    let logs = receipt
        .get("logs")
        .and_then(Value::as_array)
        .expect("receipt logs are an array");
    let log = logs
        .iter()
        .find(|log| {
            log.get("address").and_then(Value::as_str)
                == Some("0x0000000071727de22e5e9d8baf0edac6f37da032")
                && log
                    .get("topics")
                    .and_then(Value::as_array)
                    .and_then(|topics| topics.first())
                    .and_then(Value::as_str)
                    == Some(topic.as_str())
        })
        .expect("receipt includes UserOperationEvent");
    let data = hex::decode(
        log.get("data")
            .and_then(Value::as_str)
            .expect("UserOperationEvent has data")
            .strip_prefix("0x")
            .unwrap_or_default(),
    )
    .expect("event data is hex");
    assert_eq!(data.len(), 128);
    assert_eq!(U256::from_be_slice(&data[32..64]), U256::from(1));
    U256::from_be_slice(&data[64..96])
}

#[derive(Debug, Deserialize)]
pub struct RpcResponse {
    #[serde(default)]
    pub result: Value,
    pub error: Option<RpcError>,
}

#[derive(Debug, Deserialize)]
pub struct RpcError {
    pub code: i64,
    pub message: String,
    pub data: Option<Value>,
}

pub async fn rpc<T: DeserializeOwned>(
    client: &reqwest::Client,
    rpc_url: &str,
    method: &str,
    params: Value,
) -> T {
    let response = rpc_response(client, rpc_url, method, params).await;

    if let Some(error) = response.error {
        panic!(
            "{method} RPC error {}: {} {:?}",
            error.code, error.message, error.data
        );
    }

    serde_json::from_value(response.result)
        .unwrap_or_else(|error| panic!("{method} result decode failed: {error}"))
}

pub async fn rpc_response(
    client: &reqwest::Client,
    rpc_url: &str,
    method: &str,
    params: Value,
) -> RpcResponse {
    let body = client
        .post(rpc_url)
        .json(&json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params,
        }))
        .send()
        .await
        .unwrap_or_else(|error| panic!("{method} request failed: {error}"))
        .error_for_status()
        .unwrap_or_else(|error| panic!("{method} HTTP error: {error}"))
        .text()
        .await
        .unwrap_or_else(|error| panic!("{method} response body read failed: {error}"));
    serde_json::from_str(&body)
        .unwrap_or_else(|error| panic!("{method} response decode failed: {error}; body: {body}"))
}

pub async fn eth_get_code(client: &reqwest::Client, rpc_url: &str, address: Address) -> Bytes {
    let result: String = rpc(
        client,
        rpc_url,
        "eth_getCode",
        json!([address_hex(address), "latest"]),
    )
    .await;
    hex_bytes(&result)
}

pub async fn eth_get_balance(client: &reqwest::Client, rpc_url: &str, address: Address) -> U256 {
    let result: String = rpc(
        client,
        rpc_url,
        "eth_getBalance",
        json!([address_hex(address), "latest"]),
    )
    .await;
    U256::from_str_radix(result.strip_prefix("0x").unwrap_or(&result), 16).unwrap()
}

pub async fn eth_call(client: &reqwest::Client, rpc_url: &str, to: Address, data: Bytes) -> Bytes {
    eth_call_from(client, rpc_url, None, to, data).await
}

pub async fn eth_call_from(
    client: &reqwest::Client,
    rpc_url: &str,
    from: Option<Address>,
    to: Address,
    data: Bytes,
) -> Bytes {
    let mut tx = json!({ "to": address_hex(to), "data": bytes_hex(&data) });
    if let Some(from) = from {
        tx["from"] = json!(address_hex(from));
    }
    let result: String = rpc(client, rpc_url, "eth_call", json!([tx, "latest"])).await;
    hex_bytes(&result)
}

pub async fn entry_point_balance_of(
    client: &reqwest::Client,
    rpc_url: &str,
    account: Address,
) -> U256 {
    let raw = eth_call(
        client,
        rpc_url,
        wallet_bundler::ENTRY_POINT_V07,
        Bytes::from(balanceOfCall { account }.abi_encode()),
    )
    .await;
    U256::from_be_slice(&raw)
}

pub async fn entry_point_user_op_hash(
    client: &reqwest::Client,
    rpc_url: &str,
    op: &wallet_bundler::UserOperation,
) -> [u8; 32] {
    let raw = eth_call(
        client,
        rpc_url,
        wallet_bundler::ENTRY_POINT_V07,
        Bytes::from(
            getUserOpHashCall {
                userOp: packed_user_operation_sol(op),
            }
            .abi_encode(),
        ),
    )
    .await;
    raw.as_ref().try_into().expect("hash is 32 bytes")
}

pub fn packed_user_operation_sol(op: &wallet_bundler::UserOperation) -> PackedUserOperationSol {
    let fields = op.pack_fields().unwrap();
    PackedUserOperationSol {
        sender: op.sender,
        nonce: op.nonce,
        initCode: fields.init_code,
        callData: op.call_data.clone(),
        accountGasLimits: fields.account_gas_limits,
        preVerificationGas: op.pre_verification_gas,
        gasFees: fields.gas_fees,
        paymasterAndData: fields.paymaster_and_data,
        signature: op.signature.clone(),
    }
}

pub async fn eth_send_transaction(
    client: &reqwest::Client,
    rpc_url: &str,
    from: &str,
    to: Address,
    data: Bytes,
) -> String {
    eth_send_transaction_with_value(client, rpc_url, from, to, data, None).await
}

pub async fn eth_send_transaction_with_value(
    client: &reqwest::Client,
    rpc_url: &str,
    from: &str,
    to: Address,
    data: Bytes,
    value: Option<U256>,
) -> String {
    let mut tx = json!({ "from": from, "to": address_hex(to), "data": bytes_hex(&data) });
    if let Some(value) = value {
        tx["value"] = json!(u256_hex(value));
    }
    rpc(client, rpc_url, "eth_sendTransaction", json!([tx])).await
}

pub async fn eth_send_transaction_with_fees(
    client: &reqwest::Client,
    rpc_url: &str,
    from: &str,
    to: Address,
    data: Bytes,
    max_fee_per_gas: U256,
    max_priority_fee_per_gas: U256,
) -> String {
    rpc(
        client,
        rpc_url,
        "eth_sendTransaction",
        json!([{
            "from": from,
            "to": address_hex(to),
            "data": bytes_hex(&data),
            "maxFeePerGas": u256_hex(max_fee_per_gas),
            "maxPriorityFeePerGas": u256_hex(max_priority_fee_per_gas),
        }]),
    )
    .await
}

pub async fn wait_for_successful_receipt(
    client: &reqwest::Client,
    rpc_url: &str,
    tx_hash: &str,
) -> Value {
    for _ in 0..60 {
        let receipt = eth_get_transaction_receipt(client, rpc_url, tx_hash).await;
        if let Some(receipt) = receipt {
            assert_eq!(receipt.get("status"), Some(&json!("0x1")));
            return receipt;
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }

    panic!("timed out waiting for transaction receipt {tx_hash}");
}

pub async fn eth_get_transaction_receipt(
    client: &reqwest::Client,
    rpc_url: &str,
    tx_hash: &str,
) -> Option<Value> {
    rpc(
        client,
        rpc_url,
        "eth_getTransactionReceipt",
        json!([tx_hash]),
    )
    .await
}

pub async fn anvil_impersonate_account(client: &reqwest::Client, rpc_url: &str, address: &str) {
    let _: Value = rpc(
        client,
        rpc_url,
        "anvil_impersonateAccount",
        json!([address]),
    )
    .await;
}

pub async fn anvil_set_balance(
    client: &reqwest::Client,
    rpc_url: &str,
    address: Address,
    balance: U256,
) {
    let _: Value = rpc(
        client,
        rpc_url,
        "anvil_setBalance",
        json!([address_hex(address), u256_hex(balance)]),
    )
    .await;
}

pub async fn anvil_set_automine(client: &reqwest::Client, rpc_url: &str, enabled: bool) {
    let _: Value = rpc(client, rpc_url, "evm_setAutomine", json!([enabled])).await;
}

pub async fn anvil_mine(client: &reqwest::Client, rpc_url: &str) {
    let _: Value = rpc(client, rpc_url, "evm_mine", json!([])).await;
}

pub fn simulated_deployed_user_op(sender: Address) -> wallet_bundler::UserOperation {
    wallet_bundler::UserOperation::parse(json!({
        "sender": address_hex(sender),
        "nonce": "0x00",
        "callData": "0x",
        "callGasLimit": "0x10",
        "verificationGasLimit": "0x20",
        "preVerificationGas": "0x30",
        "maxFeePerGas": "0x40",
        "maxPriorityFeePerGas": "0x05",
        "signature": "0x"
    }))
    .unwrap()
}

pub fn realistic_deployed_user_op(sender: Address, nonce: U256) -> wallet_bundler::UserOperation {
    wallet_bundler::UserOperation::parse(json!({
        "sender": address_hex(sender),
        "nonce": u256_hex(nonce),
        "callData": "0x",
        "callGasLimit": "0x4623",
        "verificationGasLimit": "0xf4240",
        "preVerificationGas": "0xd80d",
        "maxFeePerGas": "0x119fd7",
        "maxPriorityFeePerGas": "0x119fb8",
        "signature": "0x"
    }))
    .unwrap()
}

pub fn realistic_transfer_user_op(
    sender: Address,
    nonce: U256,
    recipient: Address,
    amount: U256,
) -> wallet_bundler::UserOperation {
    wallet_bundler::UserOperation::parse(json!({
        "sender": address_hex(sender),
        "nonce": u256_hex(nonce),
        "callData": bytes_hex(&wallet_bundler::encode_erc7579_single_execution(
            recipient,
            amount,
            Bytes::new(),
        )),
        "callGasLimit": "0x186a0",
        "verificationGasLimit": "0xf4240",
        "preVerificationGas": "0xd80d",
        "maxFeePerGas": "0x119fd7",
        "maxPriorityFeePerGas": "0x119fb8",
        "signature": "0x"
    }))
    .unwrap()
}

pub fn realistic_transfer_user_op_with_fees(
    sender: Address,
    nonce: U256,
    recipient: Address,
    amount: U256,
    max_fee_per_gas: U256,
    max_priority_fee_per_gas: U256,
) -> wallet_bundler::UserOperation {
    wallet_bundler::UserOperation::parse(json!({
        "sender": address_hex(sender),
        "nonce": u256_hex(nonce),
        "callData": bytes_hex(&wallet_bundler::encode_erc7579_single_execution(
            recipient,
            amount,
            Bytes::new(),
        )),
        "callGasLimit": "0x186a0",
        "verificationGasLimit": "0xf4240",
        "preVerificationGas": "0xd80d",
        "maxFeePerGas": u256_hex(max_fee_per_gas),
        "maxPriorityFeePerGas": u256_hex(max_priority_fee_per_gas),
        "signature": "0x"
    }))
    .unwrap()
}

pub struct SignedUserOperationForTest {
    pub op: wallet_bundler::UserOperation,
    pub message_hash: B256,
    pub r: U256,
    pub s: U256,
}

pub fn sign_user_op_for_test(
    op: wallet_bundler::UserOperation,
    user_op_hash: [u8; 32],
    signing_key: &SigningKey,
    use_precompiled: bool,
) -> SignedUserOperationForTest {
    let authenticator_data = wallet_signature::build_authenticator_data();
    let client_data_json = wallet_signature::build_client_data_json(&user_op_hash);
    let client_data_hash: [u8; 32] = Sha256::digest(client_data_json.as_bytes()).into();
    let mut signing_preimage = Vec::with_capacity(69);
    signing_preimage.extend_from_slice(&authenticator_data);
    signing_preimage.extend_from_slice(&client_data_hash);
    let message_hash = B256::from_slice(&Sha256::digest(&signing_preimage));
    let signature: Signature = signing_key.sign(&signing_preimage);
    let (r_scalar, s_scalar) = signature.split_scalars();
    let r: [u8; 32] = r_scalar.to_bytes().into();
    let s: [u8; 32] = s_scalar.to_bytes().into();
    let (r, s) = wallet_signature::normalise_low_s(r, s);
    let webauthn_signature =
        wallet_signature::build_signature(&user_op_hash, r, s, use_precompiled);
    SignedUserOperationForTest {
        op: op.with_signature(Bytes::from(
            wallet_signature::abi_encode_webauthn_signature(&webauthn_signature),
        )),
        message_hash,
        r: U256::from_be_bytes(r),
        s: U256::from_be_bytes(s),
    }
}

pub fn p256_public_key_coordinates(verifying_key: &VerifyingKey) -> ([u8; 32], [u8; 32]) {
    let point = verifying_key.to_encoded_point(false);
    let mut x = [0u8; 32];
    x.copy_from_slice(point.x().expect("uncompressed P-256 key has x"));
    let mut y = [0u8; 32];
    y.copy_from_slice(point.y().expect("uncompressed P-256 key has y"));
    (x, y)
}
