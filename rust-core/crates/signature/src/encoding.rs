use alloy_primitives::U256;
use alloy_sol_types::{sol, SolValue};

use crate::webauthn::WebAuthnSignature;

sol! {
    struct WebAuthnSigEncoded {
        bytes authenticatorData;
        string clientDataJSON;
        uint256 responseTypeLocation;
        uint256 r;
        uint256 s;
        bool usePrecompiled;
    }
}

/// ABI-encode a WebAuthnSignature for the Kernel WebAuthn validator.
pub fn abi_encode_webauthn_signature(sig: &WebAuthnSignature) -> Vec<u8> {
    let encoded = WebAuthnSigEncoded {
        authenticatorData: sig.authenticator_data.clone().into(),
        clientDataJSON: sig.client_data_json.clone(),
        responseTypeLocation: U256::from(sig.response_type_location),
        r: U256::from_be_bytes(sig.r),
        s: U256::from_be_bytes(sig.s),
        usePrecompiled: sig.use_precompiled,
    };
    encoded.abi_encode_params()
}

/// ABI-encode the deterministic dummy signature used for gas estimation.
///
/// This is intentionally invalid but Kernel-shaped. It exercises the same
/// WebAuthn validator path as a real signature and is expected to produce
/// SIG_VALIDATION_FAILED rather than revert.
pub fn abi_encode_dummy_signature(use_precompiled: bool) -> Vec<u8> {
    let encoded = WebAuthnSigEncoded {
        authenticatorData: hex::decode(
            "e8d44050873dba865aa7c170ab4cce64d90839a34dcfd6cf71d14e0205443b1b0500000000",
        )
        .expect("static dummy authenticator data is valid hex")
        .into(),
        clientDataJSON: r#"{"type":"webauthn.get","challenge":"Rd0Z1H0tQ9Hi4bvx7R7IO9c-2FLR6X4e2-HFLNLMlYU","origin":"https://wallet.local","crossOrigin":false}"#.to_string(),
        responseTypeLocation: U256::MAX,
        r: U256::from_be_bytes(hex_array(
            "f2638b43968df7394b266e9c208f996fdcae278b736b4b8e292d179aa8daca1a",
        )),
        s: U256::from_be_bytes(hex_array(
            "13a0514ec6736fa6171137c4de6929a39fb727a222fc949875c9bdac83011db6",
        )),
        usePrecompiled: use_precompiled,
    };
    encoded.abi_encode_params()
}

fn hex_array(value: &str) -> [u8; 32] {
    hex::decode(value)
        .expect("static dummy signature scalar is valid hex")
        .try_into()
        .expect("static dummy signature scalar is 32 bytes")
}

#[cfg(test)]
mod tests {
    use super::*;
    use hex_literal::hex;

    #[test]
    fn abi_encoding_round_trips() {
        let sig = WebAuthnSignature {
            authenticator_data: vec![0x05; 37],
            client_data_json: r#"{"type":"webauthn.get","challenge":"AAAA","origin":"https://wallet.local","crossOrigin":false}"#.to_string(),
            response_type_location: 1,
            r: hex!("980aa6cd4f8ae94ef7653aec978b8335f6a00e785103665506380de233eab85e"),
            s: hex!("63bde20ed18273f1d59ae4411fa7abb4c929a4a7476e1934a04c4d4b05bad0e2"),
            use_precompiled: true,
        };
        let encoded = abi_encode_webauthn_signature(&sig);

        assert!(!encoded.is_empty());
        assert_eq!(
            encoded.len() % 32,
            0,
            "ABI encoding must be 32-byte aligned"
        );

        let decoded = WebAuthnSigEncoded::abi_decode_params(&encoded).expect("must decode back");
        assert_eq!(decoded.r, U256::from_be_bytes(sig.r));
        assert_eq!(decoded.s, U256::from_be_bytes(sig.s));
        assert_eq!(decoded.usePrecompiled, true);
        assert_eq!(decoded.responseTypeLocation, U256::from(1u64));
    }

    #[test]
    fn abi_encoding_matches_solidity() {
        let sig = WebAuthnSignature {
            authenticator_data: vec![0u8; 37],
            client_data_json: "{}".to_string(),
            response_type_location: 1,
            r: [0u8; 32],
            s: [0u8; 32],
            use_precompiled: false,
        };
        let encoded = abi_encode_webauthn_signature(&sig);

        // First 32 bytes: offset to authenticatorData. With 6 head slots, should be 0xc0 = 192.
        let first_word = &encoded[0..32];
        assert_eq!(
            first_word[31], 0xc0,
            "first offset should point past 6 head slots"
        );
    }

    #[test]
    fn dummy_signature_uses_reference_shape_and_configured_precompile_flag() {
        let encoded = abi_encode_dummy_signature(true);
        let decoded = WebAuthnSigEncoded::abi_decode_params(&encoded).expect("must decode back");

        assert_eq!(
            decoded.authenticatorData,
            hex::decode(
                "e8d44050873dba865aa7c170ab4cce64d90839a34dcfd6cf71d14e0205443b1b0500000000"
            )
            .unwrap()
        );
        assert!(decoded.clientDataJSON.contains("webauthn.get"));
        assert!(decoded.clientDataJSON.contains("wallet.local"));
        assert_eq!(decoded.responseTypeLocation, U256::MAX);
        assert!(!decoded.r.is_zero());
        assert!(!decoded.s.is_zero());
        assert!(decoded.usePrecompiled);
    }
}
