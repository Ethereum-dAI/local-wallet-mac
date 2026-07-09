//! Kernel v3.3 modular-permission session-key encoding.

use alloy_primitives::{b256, keccak256, Address, Bytes, B256, U256};
use alloy_sol_types::{sol, SolCall, SolValue};
use wallet_addresses::{
    CALL_POLICY_V0_0_5, ECDSA_SIGNER_MODULE, GAS_POLICY, RATE_LIMIT_POLICY, SUDO_POLICY,
    TIMESTAMP_POLICY,
};

use crate::VALIDATION_TYPE_PERMISSION;

pub type PolicyEntry = (Vec<u8>, Vec<u8>);

sol! {
    struct ParamRule {
        uint8 condition;
        uint64 offset;
        bytes32[] params;
    }

    struct CallPermission {
        bytes1 callType;
        address target;
        bytes4 selector;
        uint256 valueLimit;
        ParamRule[] rules;
    }

    struct ValidationConfig {
        uint32 nonce;
        address hook;
    }

    function invalidateNonce(uint32 nonce) external;
    function uninstallValidation(bytes21 vId, bytes deinitData, bytes hookDeinitData) external;
    function installValidations(
        bytes21[] vIds,
        ValidationConfig[] configs,
        bytes[] validationData,
        bytes[] hookData
    ) external;
    function grantAccess(bytes21 vId, bytes4 selector, bool allow) external;
}

/// Kernel sentinel for "no hook" in a `ValidationConfig` (address(1)).
pub const KERNEL_NO_HOOK: Address =
    Address::new([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]);

/// `execute(bytes32,bytes)` selector — the Kernel entry point that session user
/// ops call, so a session permission must be granted access to it.
pub const KERNEL_EXECUTE_SELECTOR: [u8; 4] = [0xe9, 0xae, 0x5c, 0x53];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Condition {
    Equal = 0,
    GreaterThan = 1,
    LessThan = 2,
    GreaterEqual = 3,
    LessEqual = 4,
    NotEqual = 5,
    OneOf = 6,
    SliceEqual = 7,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AllowRule {
    pub condition: Condition,
    pub offset: u64,
    pub params: Vec<B256>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AllowedCall {
    pub target: Address,
    pub selector: [u8; 4],
    pub value_limit: U256,
    pub rules: Vec<AllowRule>,
}

/// EntryPoint nonce value with the permission key in the upper 192 bits and sequence 0.
pub fn encode_permission_nonce_key(permission_id: [u8; 4], mode: u8) -> U256 {
    let mut be = [0u8; 32];
    be[0] = mode;
    be[1] = VALIDATION_TYPE_PERMISSION;
    be[2..6].copy_from_slice(&permission_id);
    U256::from_be_bytes(be)
}

pub fn policy_info(policy_flag: u16, policy_addr: Address) -> Vec<u8> {
    let mut out = Vec::with_capacity(22);
    out.extend_from_slice(&policy_flag.to_be_bytes());
    out.extend_from_slice(policy_addr.as_slice());
    out
}

fn encode_bytes_array(items: &[Vec<u8>]) -> Vec<u8> {
    let owned: Vec<Bytes> = items.iter().cloned().map(Bytes::from).collect();
    (owned,).abi_encode_params()
}

fn encode_single_bytes(bytes: &[u8]) -> Vec<u8> {
    (Bytes::from(bytes.to_vec()),).abi_encode_params()
}

pub fn permission_id(
    policies: &[PolicyEntry],
    signer_contract: Address,
    signer_data: &[u8],
) -> [u8; 4] {
    let policy_elems: Vec<Vec<u8>> = policies
        .iter()
        .map(|(info, data)| [info.as_slice(), data.as_slice()].concat())
        .collect();
    let to_policy_id = encode_bytes_array(&policy_elems);
    let flag = vec![0u8, 0u8];

    let mut signer_blob = Vec::with_capacity(20 + signer_data.len());
    signer_blob.extend_from_slice(signer_contract.as_slice());
    signer_blob.extend_from_slice(signer_data);
    let to_signer_id = encode_single_bytes(&signer_blob);

    let outer = encode_bytes_array(&[to_policy_id, flag, to_signer_id]);
    let hash = keccak256(&outer);
    [hash[0], hash[1], hash[2], hash[3]]
}

pub fn encode_gas_policy_data(
    allowed: u128,
    enforce_paymaster: bool,
    allowed_paymaster: Address,
) -> Vec<u8> {
    (U256::from(allowed), enforce_paymaster, allowed_paymaster).abi_encode_params()
}

pub fn encode_rate_limit_policy_data(interval: u64, count: u64, start_at: u64) -> Vec<u8> {
    fn u48(value: u64) -> [u8; 6] {
        let be = value.to_be_bytes();
        [be[2], be[3], be[4], be[5], be[6], be[7]]
    }

    [u48(interval), u48(count), u48(start_at)].concat()
}

pub fn encode_timestamp_policy_data(valid_after: u64, valid_until: u64) -> Vec<u8> {
    (U256::from(valid_after), U256::from(valid_until)).abi_encode_params()
}

pub fn encode_sudo_policy_data() -> Vec<u8> {
    Vec::new()
}

pub fn encode_ecdsa_signer_data(signer: Address) -> Vec<u8> {
    signer.as_slice().to_vec()
}

pub fn gas_policy(
    allowed: u128,
    enforce_paymaster: bool,
    allowed_paymaster: Address,
) -> PolicyEntry {
    (
        policy_info(0, GAS_POLICY),
        encode_gas_policy_data(allowed, enforce_paymaster, allowed_paymaster),
    )
}

pub fn rate_limit_policy(interval: u64, count: u64, start_at: u64) -> PolicyEntry {
    (
        policy_info(0, RATE_LIMIT_POLICY),
        encode_rate_limit_policy_data(interval, count, start_at),
    )
}

pub fn timestamp_policy(valid_after: u64, valid_until: u64) -> PolicyEntry {
    (
        policy_info(0, TIMESTAMP_POLICY),
        encode_timestamp_policy_data(valid_after, valid_until),
    )
}

pub fn sudo_policy() -> PolicyEntry {
    (policy_info(0, SUDO_POLICY), encode_sudo_policy_data())
}

pub fn ecdsa_signer_entry(signer: Address) -> (Address, Vec<u8>) {
    (ECDSA_SIGNER_MODULE, encode_ecdsa_signer_data(signer))
}

pub fn encode_call_policy_data(calls: &[AllowedCall]) -> Vec<u8> {
    let permissions: Vec<CallPermission> = calls
        .iter()
        .map(|call| CallPermission {
            callType: [0x00].into(),
            target: call.target,
            selector: call.selector.into(),
            valueLimit: call.value_limit,
            rules: call
                .rules
                .iter()
                .map(|rule| ParamRule {
                    condition: rule.condition as u8,
                    offset: rule.offset,
                    params: rule.params.clone(),
                })
                .collect(),
        })
        .collect();

    (permissions,).abi_encode_params()
}

pub fn call_policy(calls: &[AllowedCall]) -> PolicyEntry {
    (
        policy_info(0, CALL_POLICY_V0_0_5),
        encode_call_policy_data(calls),
    )
}

pub fn encode_enable_data(
    policies: &[PolicyEntry],
    signer_contract: Address,
    signer_data: &[u8],
) -> Vec<u8> {
    let mut elems: Vec<Vec<u8>> = policies
        .iter()
        .map(|(info, data)| [info.as_slice(), data.as_slice()].concat())
        .collect();

    let mut signer_elem = Vec::with_capacity(2 + 20 + signer_data.len());
    signer_elem.extend_from_slice(&[0u8, 0u8]);
    signer_elem.extend_from_slice(signer_contract.as_slice());
    signer_elem.extend_from_slice(signer_data);
    elems.push(signer_elem);

    encode_bytes_array(&elems)
}

pub fn encode_selector_data_default_action(execute_selector: [u8; 4]) -> Vec<u8> {
    let tail = (Bytes::from(vec![0xffu8]), Bytes::from(vec![0x00u8, 0x00u8])).abi_encode_params();

    let mut out = Vec::with_capacity(4 + 20 + 20 + tail.len());
    out.extend_from_slice(&execute_selector);
    out.extend_from_slice(Address::ZERO.as_slice());
    out.extend_from_slice(Address::ZERO.as_slice());
    out.extend_from_slice(&tail);
    out
}

pub fn enable_type_hash() -> B256 {
    b256!("b17ab1224aca0d4255ef8161acaf2ac121b8faa32a4b2258c912cc5f8308c505")
}

fn domain_separator(account: Address, chain_id: u64) -> B256 {
    let domain_type_hash = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)",
    );
    let encoded = (
        domain_type_hash,
        keccak256("Kernel"),
        keccak256("0.3.3"),
        U256::from(chain_id),
        account,
    )
        .abi_encode_params();
    keccak256(encoded)
}

#[allow(clippy::too_many_arguments)]
pub fn enable_digest(
    account: Address,
    chain_id: u64,
    validation_id: [u8; 21],
    validation_nonce: u32,
    hook: Address,
    validator_data: &[u8],
    hook_data: &[u8],
    selector_data: &[u8],
) -> B256 {
    let encoded = (
        enable_type_hash(),
        alloy_primitives::FixedBytes::<21>::from(validation_id),
        U256::from(validation_nonce),
        hook,
        keccak256(validator_data),
        keccak256(hook_data),
        keccak256(selector_data),
    )
        .abi_encode_params();
    let struct_hash = keccak256(encoded);

    let mut digest_input = Vec::with_capacity(2 + 32 + 32);
    digest_input.extend_from_slice(b"\x19\x01");
    digest_input.extend_from_slice(domain_separator(account, chain_id).as_slice());
    digest_input.extend_from_slice(struct_hash.as_slice());
    keccak256(digest_input)
}

pub fn permission_validation_id(permission_id: [u8; 4]) -> [u8; 21] {
    let mut validation_id = [0u8; 21];
    validation_id[0] = VALIDATION_TYPE_PERMISSION;
    validation_id[1..5].copy_from_slice(&permission_id);
    validation_id
}

pub fn invalidate_nonce_calldata(nonce: u32) -> Vec<u8> {
    invalidateNonceCall { nonce }.abi_encode()
}

pub fn uninstall_permission_calldata(permission_id: [u8; 4], deinit_data: &[u8]) -> Vec<u8> {
    uninstallValidationCall {
        vId: alloy_primitives::FixedBytes::<21>::from(permission_validation_id(permission_id)),
        deinitData: Bytes::from(deinit_data.to_vec()),
        hookDeinitData: Bytes::new(),
    }
    .abi_encode()
}

/// Calldata to explicitly install a session permission as a root(owner)-validated
/// operation, so the (expensive) install runs in the execution phase and is NOT
/// charged against the permission's own GasPolicy. `nonce` must equal the
/// account's `currentNonce()` at install time, else Kernel reverts `InvalidNonce`.
/// `validation_data` is the same `enableData` produced for enable-mode.
pub fn install_validations_calldata(
    permission_id: [u8; 4],
    nonce: u32,
    validation_data: &[u8],
    hook_data: &[u8],
) -> Vec<u8> {
    installValidationsCall {
        vIds: vec![alloy_primitives::FixedBytes::<21>::from(
            permission_validation_id(permission_id),
        )],
        configs: vec![ValidationConfig {
            nonce,
            hook: KERNEL_NO_HOOK,
        }],
        validationData: vec![Bytes::from(validation_data.to_vec())],
        hookData: vec![Bytes::from(hook_data.to_vec())],
    }
    .abi_encode()
}

/// Calldata to grant an installed permission access to a selector (the session
/// user ops call `execute`). Pairs with [`install_validations_calldata`].
pub fn grant_access_calldata(permission_id: [u8; 4], selector: [u8; 4]) -> Vec<u8> {
    grantAccessCall {
        vId: alloy_primitives::FixedBytes::<21>::from(permission_validation_id(permission_id)),
        selector: alloy_primitives::FixedBytes::<4>::from(selector),
        allow: true,
    }
    .abi_encode()
}

#[cfg(test)]
mod tests {
    use hex_literal::hex;

    use super::*;
    use crate::{VALIDATION_MODE_DEFAULT, VALIDATION_MODE_ENABLE};

    #[test]
    fn permission_nonce_key_enable_and_default() {
        let pid = [0xaa, 0xbb, 0xcc, 0xdd];
        let bytes = encode_permission_nonce_key(pid, VALIDATION_MODE_ENABLE).to_be_bytes::<32>();
        assert_eq!(bytes[0], 0x01);
        assert_eq!(bytes[1], 0x02);
        assert_eq!(&bytes[2..6], &pid);
        assert_eq!(&bytes[6..24], &[0u8; 18]);
        assert_eq!(&bytes[24..32], &[0u8; 8]);

        let default = encode_permission_nonce_key(pid, VALIDATION_MODE_DEFAULT).to_be_bytes::<32>();
        assert_eq!(default[0], 0x00);
    }

    #[test]
    fn revocation_calldata_matches_cast_references() {
        assert_eq!(
            invalidate_nonce_calldata(7),
            hex!("1f1b92e30000000000000000000000000000000000000000000000000000000000000007")
        );
        assert_eq!(
            uninstall_permission_calldata([0xaa, 0xbb, 0xcc, 0xdd], &[0x12, 0x34]),
            hex!(
                "e6f3d50a"
                "02aabbccdd000000000000000000000000000000000000000000000000000000"
                "0000000000000000000000000000000000000000000000000000000000000060"
                "00000000000000000000000000000000000000000000000000000000000000a0"
                "0000000000000000000000000000000000000000000000000000000000000002"
                "1234000000000000000000000000000000000000000000000000000000000000"
                "0000000000000000000000000000000000000000000000000000000000000000"
            )
        );
    }

    #[test]
    fn grant_access_calldata_matches_cast_reference() {
        assert_eq!(
            grant_access_calldata([0xaa, 0xbb, 0xcc, 0xdd], KERNEL_EXECUTE_SELECTOR),
            hex!(
                "b9b82941"
                "02aabbccdd000000000000000000000000000000000000000000000000000000"
                "e9ae5c5300000000000000000000000000000000000000000000000000000000"
                "0000000000000000000000000000000000000000000000000000000000000001"
            )
        );
    }

    #[test]
    fn install_validations_calldata_matches_cast_reference() {
        // Golden: cast calldata "installValidations(bytes21[],(uint32,address)[],bytes[],bytes[])"
        //   "[0x02aabbccdd..00]" "[(7,0x..01)]" "[0x1234]" "[0x]"
        assert_eq!(
            install_validations_calldata([0xaa, 0xbb, 0xcc, 0xdd], 7, &[0x12, 0x34], &[]),
            hex!(
                "9198bdf5"
                "0000000000000000000000000000000000000000000000000000000000000080"
                "00000000000000000000000000000000000000000000000000000000000000c0"
                "0000000000000000000000000000000000000000000000000000000000000120"
                "00000000000000000000000000000000000000000000000000000000000001a0"
                "0000000000000000000000000000000000000000000000000000000000000001"
                "02aabbccdd000000000000000000000000000000000000000000000000000000"
                "0000000000000000000000000000000000000000000000000000000000000001"
                "0000000000000000000000000000000000000000000000000000000000000007"
                "0000000000000000000000000000000000000000000000000000000000000001"
                "0000000000000000000000000000000000000000000000000000000000000001"
                "0000000000000000000000000000000000000000000000000000000000000020"
                "0000000000000000000000000000000000000000000000000000000000000002"
                "1234000000000000000000000000000000000000000000000000000000000000"
                "0000000000000000000000000000000000000000000000000000000000000001"
                "0000000000000000000000000000000000000000000000000000000000000020"
                "0000000000000000000000000000000000000000000000000000000000000000"
            )
        );
    }
}
