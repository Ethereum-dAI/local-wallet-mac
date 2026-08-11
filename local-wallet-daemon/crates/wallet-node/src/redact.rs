//! Making an RPC endpoint safe to say out loud.
//!
//! Most Ethereum RPC providers put the API key in the URL — Alchemy in the path
//! (`/v2/<key>`), others in a query parameter or in HTTP basic-auth userinfo. The
//! daemon names its execution RPC in startup errors and warnings, and both reach
//! the app: a startup failure becomes a user-visible `AppError` and is appended to
//! the debug report, and the daemon's log tail is embedded in that same report.
//! The debug report is the thing users paste into GitHub issues, so an unredacted
//! URL there is a published credential.
//!
//! Scheme and host are the whole diagnostic value ("it was pointed at drpc, not
//! alchemy"); the path and query never are.

/// `https://user:pw@host:443/v2/KEY?token=KEY` -> `https://host:443/…`.
///
/// Deliberately string-level rather than a URL parse: this runs on a path where
/// the URL may already be malformed (that can be *why* startup failed), and
/// falling back to a parse error would be how the credential escapes. Anything
/// unrecognisable collapses to `<redacted>` rather than being passed through.
pub fn redact_url(raw: &str) -> String {
    let Some((scheme, rest)) = raw.split_once("://") else {
        return "<redacted>".to_string();
    };
    // Userinfo, if present, is credentials by definition.
    let authority_and_path = rest.rsplit_once('@').map_or(rest, |(_, after)| after);
    let authority = authority_and_path
        .split(['/', '?', '#'])
        .next()
        .unwrap_or_default();
    if authority.is_empty() {
        return "<redacted>".to_string();
    }
    let had_more = authority_and_path.len() > authority.len();
    if had_more {
        format!("{scheme}://{authority}/…")
    } else {
        format!("{scheme}://{authority}")
    }
}

#[cfg(test)]
mod tests {
    use super::redact_url;

    #[test]
    fn strips_an_api_key_from_the_path() {
        assert_eq!(
            redact_url("https://eth-mainnet.g.alchemy.com/v2/SECRET-KEY"),
            "https://eth-mainnet.g.alchemy.com/…"
        );
    }

    #[test]
    fn strips_a_query_string() {
        assert_eq!(
            redact_url("https://rpc.example.com?apikey=SECRET"),
            "https://rpc.example.com/…"
        );
    }

    #[test]
    fn strips_basic_auth_userinfo() {
        assert_eq!(
            redact_url("https://user:hunter2@rpc.example.com/v1"),
            "https://rpc.example.com/…"
        );
    }

    #[test]
    fn keeps_the_port_because_it_is_diagnostic_and_not_secret() {
        assert_eq!(redact_url("http://127.0.0.1:8545"), "http://127.0.0.1:8545");
    }

    #[test]
    fn a_bare_host_needs_no_ellipsis() {
        assert_eq!(
            redact_url("https://sepolia.drpc.org"),
            "https://sepolia.drpc.org"
        );
    }

    /// A trailing slash is not a secret, but it is also not worth a special case:
    /// what matters is that nothing after the authority survives.
    #[test]
    fn a_trailing_slash_collapses_like_any_other_path() {
        assert_eq!(
            redact_url("https://sepolia.drpc.org/"),
            "https://sepolia.drpc.org/…"
        );
    }

    /// The URL being malformed can be the reason startup failed, so this path is
    /// reachable — and it must not fall through to printing the raw string.
    #[test]
    fn something_that_is_not_a_url_is_withheld_entirely() {
        assert_eq!(redact_url("not a url"), "<redacted>");
        assert_eq!(redact_url("https://"), "<redacted>");
        assert_eq!(redact_url(""), "<redacted>");
    }
}
