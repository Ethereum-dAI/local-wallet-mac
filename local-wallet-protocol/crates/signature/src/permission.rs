//! Kernel v3.3 permission/session-key signing and signature wrappers.

use alloy_primitives::{keccak256, Address, Bytes};
use alloy_sol_types::SolValue;
use k256::ecdsa::{RecoveryId, Signature, SigningKey};

use crate::Result;

pub fn sign_session_userop_hash(userop_hash: &[u8; 32], secret: &[u8; 32]) -> Result<[u8; 65]> {
    let mut preimage = Vec::with_capacity(28 + 32);
    preimage.extend_from_slice(b"\x19Ethereum Signed Message:\n32");
    preimage.extend_from_slice(userop_hash);
    let digest = keccak256(&preimage);

    let signing_key = SigningKey::from_slice(secret)?;
    let (signature, recovery_id): (Signature, RecoveryId) =
        signing_key.sign_prehash_recoverable(digest.as_slice())?;

    let mut out = [0u8; 65];
    out[..32].copy_from_slice(&signature.r().to_bytes());
    out[32..64].copy_from_slice(&signature.s().to_bytes());
    out[64] = 27 + recovery_id.to_byte();
    Ok(out)
}

pub fn wrap_installed_signature(inner_sig: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(1 + inner_sig.len());
    out.push(0xff);
    out.extend_from_slice(inner_sig);
    out
}

pub fn wrap_enable_signature(
    hook: Address,
    validator_data: &[u8],
    hook_data: &[u8],
    selector_data: &[u8],
    enable_sig: &[u8],
    userop_sig: &[u8],
) -> Vec<u8> {
    let tail = (
        Bytes::from(validator_data.to_vec()),
        Bytes::from(hook_data.to_vec()),
        Bytes::from(selector_data.to_vec()),
        Bytes::from(enable_sig.to_vec()),
        Bytes::from(userop_sig.to_vec()),
    )
        .abi_encode_params();

    let mut out = Vec::with_capacity(20 + tail.len());
    out.extend_from_slice(hook.as_slice());
    out.extend_from_slice(&tail);
    out
}

pub fn dummy_permission_signature_installed() -> Vec<u8> {
    wrap_installed_signature(&[0u8; 65])
}

pub fn dummy_permission_signature_enable(
    hook: Address,
    validator_data: &[u8],
    hook_data: &[u8],
    selector_data: &[u8],
    use_precompiled: bool,
) -> Vec<u8> {
    let enable_sig = crate::abi_encode_dummy_signature(use_precompiled);
    let userop_sig = dummy_permission_signature_installed();
    wrap_enable_signature(
        hook,
        validator_data,
        hook_data,
        selector_data,
        &enable_sig,
        &userop_sig,
    )
}

#[cfg(test)]
mod tests {
    use alloy_primitives::Address;

    use super::*;

    #[test]
    fn dummy_installed_signature_has_expected_shape() {
        let sig = dummy_permission_signature_installed();
        assert_eq!(sig.len(), 66);
        assert_eq!(sig[0], 0xff);
        assert!(sig[1..].iter().all(|byte| *byte == 0));
    }

    #[test]
    fn dummy_enable_signature_wraps_supplied_enable_fields() {
        let validator_data = vec![0x01, 0x02];
        let selector_data = vec![0x03, 0x04];
        let sig = dummy_permission_signature_enable(
            Address::ZERO,
            &validator_data,
            &[],
            &selector_data,
            false,
        );

        assert!(sig.len() > dummy_permission_signature_installed().len());
        assert_eq!(&sig[..20], Address::ZERO.as_slice());
        assert!(sig
            .windows(validator_data.len())
            .any(|w| w == validator_data));
        assert!(sig.windows(selector_data.len()).any(|w| w == selector_data));
    }
}
