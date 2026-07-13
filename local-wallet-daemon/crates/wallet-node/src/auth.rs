use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use rand::rngs::OsRng;
use rand::RngCore;
use subtle::ConstantTimeEq;
use thiserror::Error;

pub struct Token([u8; 32]);

impl Token {
    pub fn generate() -> Token {
        let mut bytes = [0u8; 32];
        OsRng.fill_bytes(&mut bytes);
        Token(bytes)
    }

    pub fn encoded(&self) -> String {
        URL_SAFE_NO_PAD.encode(self.0)
    }

    /// Verifies a Bearer authorization header; RFC 7235 §2.1 defines auth schemes as case-insensitive.
    pub fn verify_header(&self, header: Option<&str>) -> Result<(), AuthError> {
        let header = header.ok_or(AuthError::Missing)?;
        let trimmed = header.trim();
        let (scheme, token_str) = trimmed.split_once(' ').ok_or(AuthError::Malformed)?;
        if !scheme.eq_ignore_ascii_case("Bearer") {
            return Err(AuthError::Malformed);
        }
        // trim_start handles double-space like 'Bearer  <token>'; slight tolerance
        // change vs original but harmless — both single and double space now accepted.
        let token_str = token_str.trim_start();
        let decoded = URL_SAFE_NO_PAD
            .decode(token_str)
            .map_err(|_| AuthError::Malformed)?;

        if decoded.len() != self.0.len() {
            return Err(AuthError::Malformed);
        }

        if bool::from(decoded.as_slice().ct_eq(&self.0)) {
            Ok(())
        } else {
            Err(AuthError::Mismatch)
        }
    }
}

impl std::fmt::Debug for Token {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Token(<redacted>)")
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum AuthError {
    #[error("missing bearer token")]
    Missing,
    #[error("malformed bearer token")]
    Malformed,
    #[error("bearer token mismatch")]
    Mismatch,
}

impl AuthError {
    pub fn json_rpc_code(&self) -> i64 {
        -32001
    }
}

#[cfg(test)]
mod tests {
    use super::{AuthError, Token};

    #[test]
    fn generate_produces_43_char_encoded_string() {
        let token = Token::generate();

        assert_eq!(token.encoded().len(), 43);
    }

    #[test]
    fn consecutive_generate_calls_produce_different_tokens() {
        let first = Token::generate();
        let second = Token::generate();

        assert_ne!(first.encoded(), second.encoded());
    }

    #[test]
    fn verify_header_rejects_missing_header() {
        let token = Token::generate();

        assert_eq!(token.verify_header(None), Err(AuthError::Missing));
    }

    #[test]
    fn verify_header_rejects_non_bearer_header() {
        let token = Token::generate();

        assert_eq!(
            token.verify_header(Some("Basic abc")),
            Err(AuthError::Malformed)
        );
    }

    #[test]
    fn verify_header_accepts_lowercase_bearer() {
        let token = Token::generate();
        let header = format!("bearer {}", token.encoded());

        assert!(token.verify_header(Some(&header)).is_ok());
    }

    #[test]
    fn verify_header_accepts_uppercase_bearer() {
        let token = Token::generate();
        let header = format!("BEARER {}", token.encoded());

        assert!(token.verify_header(Some(&header)).is_ok());
    }

    #[test]
    fn verify_header_accepts_mixed_case_bearer() {
        let token = Token::generate();
        let header = format!("BeArEr {}", token.encoded());

        assert!(token.verify_header(Some(&header)).is_ok());
    }

    #[test]
    fn verify_header_accepts_extra_whitespace() {
        let token = Token::generate();
        let header = format!("Bearer  {}", token.encoded());

        // Multiple spaces after the scheme are tolerated by trimming the token start.
        assert!(token.verify_header(Some(&header)).is_ok());
    }

    #[test]
    fn verify_header_accepts_trailing_whitespace() {
        let token = Token::generate();
        let header = format!("Bearer {} ", token.encoded());

        // Header-level trim tolerates incidental surrounding whitespace.
        assert!(token.verify_header(Some(&header)).is_ok());
    }

    #[test]
    fn verify_header_rejects_short_token() {
        let token = Token::generate();

        assert_eq!(
            token.verify_header(Some("Bearer abc")),
            Err(AuthError::Malformed)
        );
    }

    #[test]
    fn verify_header_rejects_long_token() {
        let token = Token::generate();
        let header = format!("Bearer {}A", token.encoded());

        assert_eq!(
            token.verify_header(Some(&header)),
            Err(AuthError::Malformed)
        );
    }

    #[test]
    fn verify_header_rejects_invalid_base64() {
        let token = Token::generate();

        assert_eq!(
            token.verify_header(Some("Bearer not_base64!")),
            Err(AuthError::Malformed)
        );
    }

    #[test]
    fn verify_header_rejects_mismatched_token() {
        let token = Token::generate();
        let other_token = Token::generate();
        let header = format!("Bearer {}", other_token.encoded());

        assert_eq!(token.verify_header(Some(&header)), Err(AuthError::Mismatch));
    }

    #[test]
    fn verify_header_accepts_matching_token() {
        let token = Token::generate();
        let header = format!("Bearer {}", token.encoded());

        assert_eq!(token.verify_header(Some(&header)), Ok(()));
    }

    #[test]
    fn debug_redacts_token() {
        let token = Token::generate();

        assert_eq!(format!("{token:?}"), "Token(<redacted>)");
    }
}
