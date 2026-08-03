//! The ERC-4337 privacy-paymaster exit: turn a RAILGUN unshield into a landed,
//! paymaster-sponsored UserOperation submitted by a PUBLIC bundler.
//!
//! Owns the ephemeral 7702 sender, the bundler client, the gas gate, and receipt polling.
//! Knows nothing about the socket, the job map, or the app.

/// The keyless public Pimlico endpoint. Hardcoded on purpose: an API key in the URL is a
/// stable identifier attached to every exit, so a paid keyed endpoint would be WORSE for
/// privacy than the free public one. There is no production override.
pub fn bundler_url_for(chain_id: u64) -> String {
    format!("https://public.pimlico.io/v2/{chain_id}/rpc")
}

/// Resolve the bundler URL, allowing a fork-fixture override.
///
/// Only compiled under `fork-sync`, so a production build has no override path at all.
#[cfg(feature = "fork-sync")]
pub fn resolve_bundler_url(chain_id: u64) -> String {
    std::env::var("RAILGUN_BUNDLER_URL").unwrap_or_else(|_| bundler_url_for(chain_id))
}

#[cfg(not(feature = "fork-sync"))]
pub fn resolve_bundler_url(chain_id: u64) -> String {
    bundler_url_for(chain_id)
}

/// Whether to spend another round of proofs after a fee-convergence failure.
///
/// `prepare_userop` errors after 5 Groth16 proofs if the estimated fee keeps RISING. A blind
/// retry into a climbing market just burns 5 more proofs, so gate on a fresh gas sample:
/// retry only when gas is flat or falling. kohaku-cli does not retry at all, but it is a CLI
/// where the user can press up-arrow; ours drives an async card.
pub fn should_retry_after_convergence_failure(baseline_max_fee: u128, fresh_max_fee: u128) -> bool {
    fresh_max_fee <= baseline_max_fee
}

/// Sample `pimlico_getUserOperationGasPrice` and return the `slow` tier's `maxFeePerGas`.
///
/// `PimlicoBundler` computes this inside `estimate_gas` and does not expose it, so this is a
/// direct JSON-RPC call. It must match the tier `PimlicoBundler` actually prices at
/// (`bundler/pimlico.rs:96` uses `slow`), or the gate compares unlike numbers.
pub async fn fetch_max_fee_per_gas(bundler_url: &str) -> Result<u128, String> {
    let body = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "pimlico_getUserOperationGasPrice",
        "params": []
    });
    let resp: serde_json::Value = reqwest::Client::new()
        .post(bundler_url)
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("bundler gas price request: {e}"))?
        .json()
        .await
        .map_err(|e| format!("bundler gas price decode: {e}"))?;

    let hex = resp
        .get("result")
        .and_then(|r| r.get("slow"))
        .and_then(|s| s.get("maxFeePerGas"))
        .and_then(|v| v.as_str())
        .ok_or_else(|| format!("bundler gas price: unexpected response {resp}"))?;
    u128::from_str_radix(hex.trim_start_matches("0x"), 16)
        .map_err(|e| format!("bundler gas price parse {hex}: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundler_url_is_the_keyless_public_endpoint() {
        // Keyless on purpose: an API key in the URL is a stable identifier attached to
        // every exit, so a keyed endpoint would be a privacy regression, not an upgrade.
        assert_eq!(
            bundler_url_for(11155111),
            "https://public.pimlico.io/v2/11155111/rpc"
        );
        assert!(!bundler_url_for(11155111).contains("apikey"));
    }

    #[test]
    fn retries_only_when_gas_is_not_climbing() {
        // Flat or falling gas → the failure was noise, retry is worth 5 more proofs.
        assert!(should_retry_after_convergence_failure(100, 100));
        assert!(should_retry_after_convergence_failure(100, 90));
        // Climbing gas → the loop will fail again; refuse in one RPC instead of ~5 minutes.
        assert!(!should_retry_after_convergence_failure(100, 101));
        assert!(!should_retry_after_convergence_failure(100, 1_000));
    }
}
