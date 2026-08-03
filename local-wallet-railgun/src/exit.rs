//! The ERC-4337 privacy-paymaster exit: turn a RAILGUN unshield into a landed,
//! paymaster-sponsored UserOperation submitted by a PUBLIC bundler.
//!
//! Owns the ephemeral 7702 sender, the bundler client, the gas gate, and receipt polling.
//! Knows nothing about the socket, the job map, or the app.

use std::time::Duration;

use alloy::primitives::B256;
use alloy::sol;
use userop_kit::bundler::{pimlico::PimlicoBundler, Bundler};
use userop_kit::user_operation::UserOperationHash;

use crate::fee::{delivered_lower_bound, DELIVERY_EPSILON_WEI};

sol! {
    #[sol(rpc)]
    contract WETH {
        function withdraw(uint256 wad) external;
    }
}

/// How long we poll for a receipt before reporting the op as still pending.
///
/// Deliberately NOT `PimlicoBundler::wait_for_receipt`, which hardcodes 60s while
/// `PimlicoBundler` prices at the `slow` tier (`bundler/pimlico.rs:60-62,96`). A slow-tier op
/// routinely exceeds 60s, so that helper reports `Timeout` on exits that land fine — a false
/// failure on a successful exit, with the op hash lost.
pub const RECEIPT_POLL_BUDGET: Duration = Duration::from_secs(600);
pub const RECEIPT_POLL_INTERVAL: Duration = Duration::from_secs(6);

#[derive(Debug, thiserror::Error)]
pub enum ExitError {
    #[error("fee estimate did not converge (gas is moving too fast right now)")]
    FeeDidNotConverge,
    #[error("no bundler accepted the operation: {0}")]
    BundlerRejected(String),
    #[error("the privacy paymaster is not configured for this chain")]
    PaymasterNotConfigured,
    #[error(
        "unshield landed but delivery reverted; WETH is recoverable at exit index \
         {exit_index} (op {user_op_hash})"
    )]
    DeliveryReverted {
        exit_index: u32,
        user_op_hash: String,
    },
    #[error("{0}")]
    Other(String),
}

impl ExitError {
    /// Stable wire code the app switches card state on.
    pub fn code(&self) -> &'static str {
        match self {
            ExitError::FeeDidNotConverge => "feeDidNotConverge",
            ExitError::BundlerRejected(_) => "bundlerRejected",
            ExitError::PaymasterNotConfigured => "paymasterNotConfigured",
            ExitError::DeliveryReverted { .. } => "deliveryReverted",
            ExitError::Other(_) => "error",
        }
    }
}

/// Render a UserOperation hash as the wire string carried in [`ExitSubmission`].
///
/// Paired with [`parse_op_hash`]; the two MUST be inverse or receipt polling silently misses a
/// landed op. `op_hash_survives_the_format_parse_round_trip` pins that, including the
/// leading-zero case.
pub fn format_op_hash(hash: B256) -> String {
    // alloy's `Debug for FixedBytes` is `0x` + full lowercase hex, and `FromStr` is `from_hex`,
    // so this is exactly invertible — including leading zero bytes.
    format!("{hash:?}")
}

/// Parse a wire op hash back into the bundler's hash type. Inverse of [`format_op_hash`].
pub fn parse_op_hash(hash: &str) -> Result<B256, ExitError> {
    hash.parse()
        .map_err(|e| ExitError::Other(format!("bad op hash {hash}: {e}")))
}

/// Everything known once the bundler has accepted the op. Published as the job's `submitted`
/// state so the app can show a submitted card with a real hash instead of a blank spinner.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExitSubmission {
    pub user_op_hash: String,
    pub sender: String,
    /// Wei of NATIVE ETH the callData forwards to the recipient.
    pub delivered_wei: u128,
    pub exit_index: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExitOutcome {
    pub user_op_hash: String,
    pub sender: String,
    /// Wei of NATIVE ETH forwarded to the recipient.
    pub delivered_wei: u128,
    pub exit_index: u32,
    pub included: bool,
    pub reverted: bool,
}

/// Poll for the op's receipt. A FREE FUNCTION, not a `RailgunHelper` method, so the caller does
/// NOT hold the helper's mutex while waiting — otherwise `balance` and `maxUnshieldable` would
/// block for the whole inclusion wait, which can be minutes.
///
/// A budget overrun is reported as `included: false` — NOT an error — because a `slow`-tier op
/// may still land. Treating it as failure would mark a successful exit as reverted.
pub async fn await_exit(bundler_url: &str, sub: &ExitSubmission) -> Result<ExitOutcome, ExitError> {
    await_exit_within(bundler_url, sub, RECEIPT_POLL_BUDGET, RECEIPT_POLL_INTERVAL).await
}

/// [`await_exit`] with the timings injected, so a test can exercise the poll loop in
/// milliseconds instead of ten minutes.
async fn await_exit_within(
    bundler_url: &str,
    sub: &ExitSubmission,
    budget: Duration,
    interval: Duration,
) -> Result<ExitOutcome, ExitError> {
    let bundler = PimlicoBundler::new(
        bundler_url
            .parse()
            .map_err(|e| ExitError::Other(format!("bad bundler url: {e}")))?,
    );
    let hash = UserOperationHash(parse_op_hash(&sub.user_op_hash)?);

    let outcome = |included: bool, reverted: bool| ExitOutcome {
        user_op_hash: sub.user_op_hash.clone(),
        sender: sub.sender.clone(),
        delivered_wei: sub.delivered_wei,
        exit_index: sub.exit_index,
        included,
        reverted,
    };

    let started = std::time::Instant::now();
    loop {
        if started.elapsed() > budget {
            return Ok(outcome(false, false));
        }
        match bundler.wait_for_receipt(hash).await {
            Ok(receipt) if receipt.success => return Ok(outcome(true, false)),
            // `success == false` is a real on-chain verdict, not a polling hiccup. The
            // unshield already executed during paymaster validation and an execution-phase
            // revert does NOT roll it back, so this is genuinely terminal — do not soften it.
            Ok(_) => {
                return Err(ExitError::DeliveryReverted {
                    exit_index: sub.exit_index,
                    user_op_hash: sub.user_op_hash.clone(),
                })
            }
            // EVERY poll error is retryable, not just `Timeout`. `wait_for_receipt`'s own 60s
            // timeout is not our budget, and a transport error — a 502 from the public
            // bundler, a dropped connection, one malformed response — carries no more
            // information about inclusion than a timeout does. Returning an error here would
            // show the user a "reverted" card for an exit whose funds arrived seconds later,
            // which is the worst outcome in this path.
            //
            // Safe against a permanently-failing poll: we only reach `await_exit` after
            // `send_user_operation` returned a hash, so the op demonstrably exists. The budget
            // stays the single bound, and the honest worst case is waiting it out and saying
            // "pending".
            Err(e) => {
                tracing::warn!(
                    "receipt poll for op {} failed, retrying: {e}",
                    sub.user_op_hash
                );
                tokio::time::sleep(interval).await;
            }
        }
    }
}

/// Wei of native ETH to unwrap and forward: the conservative delivered lower bound, less the
/// epsilon guard. Saturating, so a tiny exit yields 0 rather than underflowing.
pub fn forward_amount(value: u128, fee_bps: u16) -> u128 {
    delivered_lower_bound(value, fee_bps).saturating_sub(DELIVERY_EPSILON_WEI)
}

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

    #[test]
    fn error_codes_are_stable_wire_strings() {
        // The app switches card state on these; renaming one silently breaks the UI.
        assert_eq!(ExitError::FeeDidNotConverge.code(), "feeDidNotConverge");
        assert_eq!(
            ExitError::BundlerRejected("nope".into()).code(),
            "bundlerRejected"
        );
        assert_eq!(
            ExitError::PaymasterNotConfigured.code(),
            "paymasterNotConfigured"
        );
        assert_eq!(
            ExitError::DeliveryReverted {
                exit_index: 3,
                user_op_hash: "0xabc".into()
            }
            .code(),
            "deliveryReverted"
        );
        assert_eq!(ExitError::Other("x".into()).code(), "error");
    }

    #[test]
    fn delivery_reverted_names_the_recoverable_index() {
        // The whole point of a DERIVED sender: the message must carry the index, because
        // that is what makes the stranded funds re-derivable.
        let e = ExitError::DeliveryReverted {
            exit_index: 42,
            user_op_hash: "0xdead".into(),
        };
        let msg = e.to_string();
        assert!(msg.contains("42"), "message must name the index: {msg}");
        assert!(
            msg.contains("0xdead"),
            "message must name the op hash: {msg}"
        );
    }

    #[test]
    fn forwarded_amount_is_delivered_minus_epsilon() {
        // 10_000 wei drained → floor(10_000 * 9975/10000) = 9975 delivered,
        // minus the 1000 wei guard = 8975 forwarded.
        assert_eq!(forward_amount(10_000, 25), 8_975);
    }

    #[test]
    fn forward_amount_is_zero_when_below_the_guard() {
        // Must never underflow into a huge value that would revert the withdraw.
        assert_eq!(forward_amount(100, 25), 0);
    }

    fn submission() -> ExitSubmission {
        ExitSubmission {
            user_op_hash: "0x1c3fa5b0e2d47c8916aa0b3d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7081"
                .to_string(),
            sender: "0x0000000000000000000000000000000000000001".to_string(),
            delivered_wei: 8_975,
            exit_index: 7,
        }
    }

    #[tokio::test]
    async fn transient_poll_errors_end_as_pending_not_failure() {
        // Port 1 has no listener, so every `eth_getUserOperationReceipt` fails at the transport
        // layer — a real `BundlerError::Other`, not a `Timeout`. That must NOT become a
        // terminal error: the op already has a hash, so it may land at any moment, and an
        // `Err` here would render a "reverted" card for an exit whose funds arrive seconds
        // later. The budget is the only bound, and exhausting it means "we do not know yet".
        let sub = submission();
        let out = await_exit_within(
            "http://127.0.0.1:1/",
            &sub,
            Duration::from_millis(60),
            Duration::from_millis(1),
        )
        .await
        .expect("a transport error must not be reported as a failed exit");

        assert!(!out.included, "unknown inclusion must not claim included");
        assert!(!out.reverted, "a poll error is not an on-chain revert");
        // The submission's facts survive the poll unchanged.
        assert_eq!(out.user_op_hash, sub.user_op_hash);
        assert_eq!(out.sender, sub.sender);
        assert_eq!(out.delivered_wei, sub.delivered_wei);
        assert_eq!(out.exit_index, sub.exit_index);
    }

    #[tokio::test]
    async fn a_malformed_bundler_url_still_fails_fast() {
        // Retrying is for POLL errors. A URL that cannot be parsed is a caller bug that no
        // amount of waiting fixes, so it must not be swallowed into a pending outcome.
        let err = await_exit_within(
            "not-a-url",
            &submission(),
            Duration::from_millis(10),
            Duration::from_millis(1),
        )
        .await
        .expect_err("an unparseable bundler url must be reported, not polled");
        assert_eq!(err.code(), "error");
    }

    #[test]
    fn op_hash_survives_the_format_parse_round_trip() {
        // `try_submit` hands the hash across the wire as a String and `await_exit` parses it
        // back to poll for the receipt. If the two were not inverse, the op would land and we
        // would never see it — a silent false "still pending" on a successful exit.
        for hex in [
            "0x1c3fa5b0e2d47c8916aa0b3d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7081",
            // Leading zero byte: catches any numeric-style formatting that would drop it.
            "0x00000000000000000000000000000000000000000000000000000000000000ff",
            "0x0000000000000000000000000000000000000000000000000000000000000000",
        ] {
            let raw: B256 = hex.parse().expect("test vector is valid hex");
            assert_eq!(format_op_hash(raw), hex, "formatting must be plain 0x-hex");
            assert_eq!(
                parse_op_hash(&format_op_hash(raw)).expect("round trip"),
                raw,
                "parse must invert format"
            );
        }
    }
}
