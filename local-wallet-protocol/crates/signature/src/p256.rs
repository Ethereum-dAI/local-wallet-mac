use crate::{Result, SignatureError};

/// secp256r1 curve order
#[allow(dead_code)]
const SECP256R1_ORDER: [u8; 32] = [
    0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xBC, 0xE6, 0xFA, 0xAD, 0xA7, 0x17, 0x9E, 0x84, 0xF3, 0xB9, 0xCA, 0xC2, 0xFC, 0x63, 0x25, 0x51,
];

/// n/2 (floor) — threshold for low-s
const SECP256R1_HALF_ORDER: [u8; 32] = [
    0x7F, 0xFF, 0xFF, 0xFF, 0x80, 0x00, 0x00, 0x00, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xDE, 0x73, 0x7D, 0x56, 0xD3, 0x8B, 0xCF, 0x42, 0x79, 0xDC, 0xE5, 0x61, 0x7E, 0x31, 0x92, 0xA8,
];

/// Parse DER-encoded ECDSA signature into raw (r, s) scalars.
pub fn der_to_raw(der: &[u8]) -> Result<([u8; 32], [u8; 32])> {
    use ::p256::ecdsa::Signature;
    let sig = Signature::from_der(der).map_err(|_| SignatureError::InvalidDerEncoding)?;
    let (r_scalar, s_scalar) = sig.split_scalars();
    let r: [u8; 32] = r_scalar.to_bytes().into();
    let s: [u8; 32] = s_scalar.to_bytes().into();
    Ok((r, s))
}

/// Normalise (r, s) to low-s form.
/// MANDATORY: Kernel WebAuthn validator rejects s > n/2.
pub fn normalise_low_s(r: [u8; 32], s: [u8; 32]) -> ([u8; 32], [u8; 32]) {
    if s > SECP256R1_HALF_ORDER {
        use ::p256::elliptic_curve::ops::Reduce;
        let s_scalar = ::p256::Scalar::reduce_bytes(&s.into());
        let neg_s = -s_scalar;
        let new_s: [u8; 32] = neg_s.to_bytes().into();
        (r, new_s)
    } else {
        (r, s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hex_literal::hex;

    #[test]
    fn der_to_raw_parses_correctly() {
        use ::p256::ecdsa::{signature::Signer, Signature, SigningKey};
        let sk = SigningKey::from_bytes(
            &hex!("c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721").into(),
        )
        .unwrap();
        let msg = b"test message";
        let sig: Signature = sk.sign(msg);
        let der = sig.to_der();

        let (r, s) = der_to_raw(der.as_bytes()).unwrap();

        let sig2 = Signature::from_scalars(r, s).unwrap();
        use ::p256::ecdsa::signature::Verifier;
        let vk = sk.verifying_key();
        vk.verify(msg, &sig2).unwrap();
    }

    #[test]
    fn der_to_raw_rejects_invalid_der() {
        let error = der_to_raw(&[0x01, 0x02, 0x03]).unwrap_err();
        assert_eq!(error, SignatureError::InvalidDerEncoding);
    }

    #[test]
    fn normalise_low_s_keeps_low_s() {
        let r = hex!("980aa6cd4f8ae94ef7653aec978b8335f6a00e785103665506380de233eab85e");
        let s = hex!("63bde20ed18273f1d59ae4411fa7abb4c929a4a7476e1934a04c4d4b05bad0e2");
        let (r2, s2) = normalise_low_s(r, s);
        assert_eq!(r, r2);
        assert_eq!(s, s2, "low-s should be unchanged");
    }

    #[test]
    fn normalise_low_s_flips_high_s() {
        let r = hex!("980aa6cd4f8ae94ef7653aec978b8335f6a00e785103665506380de233eab85e");
        let low_s = hex!("63bde20ed18273f1d59ae4411fa7abb4c929a4a7476e1934a04c4d4b05bad0e2");
        use ::p256::elliptic_curve::ops::Reduce;
        let s_scalar = ::p256::Scalar::reduce_bytes(&low_s.into());
        let high_s_scalar = -s_scalar;
        let high_s: [u8; 32] = high_s_scalar.to_bytes().into();

        let (r2, s2) = normalise_low_s(r, high_s);
        assert_eq!(r, r2);
        assert_eq!(s2, low_s, "high-s should be flipped to low-s");
    }
}
