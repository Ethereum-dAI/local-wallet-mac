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
        assert_eq!(encoded.len() % 32, 0, "ABI encoding must be 32-byte aligned");

        let decoded = WebAuthnSigEncoded::abi_decode_params(&encoded, true)
            .expect("must decode back");
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
        assert_eq!(first_word[31], 0xc0,
            "first offset should point past 6 head slots");
    }
}
