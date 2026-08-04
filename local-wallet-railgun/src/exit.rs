//! The ERC-4337 privacy-paymaster exit: turn a RAILGUN unshield into a landed,
//! paymaster-sponsored UserOperation submitted by a PUBLIC bundler.
//!
//! Owns the ephemeral 7702 sender, the bundler client, the amount guards, and receipt polling.
//! Knows nothing about the socket, the job map, or the app.

use std::time::Duration;

use alloy::primitives::{B256, U256};
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

sol! {
    /// The one RailgunSmartWallet getter we need. The pinned SDK's own ABI
    /// (`railgun/src/abis/railgun.rs`) declares only `rootHistory`/`shield`/`transact`, so we
    /// declare this ourselves — the same thing we already do for `WETH.withdraw`, not an SDK
    /// patch.
    ///
    /// `unshieldFee` is a `uint120` state variable on RailgunLogic, but a public getter for any
    /// `uintN` ABI-encodes as one left-padded 32-byte word, so decoding it as `uint256` is
    /// exact. Verified live: selector `0x053ed12a` returns 25 on both mainnet
    /// (`0xFA7093CD…`) and Sepolia (`0xeCFCf3b4…`).
    #[sol(rpc)]
    contract RailgunSmartWallet {
        function unshieldFee() external view returns (uint256);
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
    /// The bundler would not take the operation. TWO materially different situations share this
    /// code, told apart by `submitted` — and conflating them is an outcome MISREPORT, not a copy
    /// nicety:
    ///
    /// - `submitted: false` — rejected during gas estimation, i.e. before
    ///   `eth_sendUserOperation` was ever called. Nothing was submitted, nothing moved, and the
    ///   shielded notes are still in the pool. The card must revert.
    /// - `submitted: true` — the send POST may have reached the bundler and the response was lost
    ///   (connection reset, read timeout). The op may already be in the mempool, where it can
    ///   land, pass validation and execute the unshield. The card must NOT revert, and the
    ///   message carries the recovery pointer for exactly that case — the same reason
    ///   `DeliveryReverted` does.
    ///
    /// One wire code cannot distinguish those, which is why `submitted` travels alongside it (see
    /// [`ExitError::submitted`]).
    #[error("{}", render_bundler_rejection(*submitted, message, *exit_index, sender))]
    BundlerRejected {
        message: String,
        exit_index: u32,
        sender: String,
        /// Whether `eth_sendUserOperation` was actually attempted. See the variant docs.
        submitted: bool,
    },
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

/// Word a bundler refusal according to whether `eth_sendUserOperation` was actually attempted.
///
/// A pre-send refusal must state plainly that nothing moved; a lost-response refusal must NOT,
/// and must carry the index + sender that locate the notes if the op does land. Rendering both
/// from one hedged sentence is what made the app show "Reverted" for an exit that may still be
/// executing.
fn render_bundler_rejection(
    submitted: bool,
    message: &str,
    exit_index: u32,
    sender: &str,
) -> String {
    if submitted {
        format!(
            "bundler did not confirm the operation ({message}); if it was submitted, the exit is \
             recoverable at index {exit_index} (sender {sender})"
        )
    } else {
        format!(
            "the bundler refused the operation before it was submitted ({message}); nothing left \
             the pool"
        )
    }
}

impl ExitError {
    /// Stable wire code the app switches card state on.
    pub fn code(&self) -> &'static str {
        match self {
            ExitError::FeeDidNotConverge => "feeDidNotConverge",
            ExitError::BundlerRejected { .. } => "bundlerRejected",
            ExitError::PaymasterNotConfigured => "paymasterNotConfigured",
            ExitError::DeliveryReverted { .. } => "deliveryReverted",
            ExitError::Other(_) => "error",
        }
    }

    /// Whether a UserOperation may already be in the bundler's mempool, i.e. whether the
    /// unshield may still execute despite this failure.
    ///
    /// `None` for every code whose meaning is already unambiguous: `FeeDidNotConverge`,
    /// `PaymasterNotConfigured` and the pre-send `Other` cases never reached
    /// `eth_sendUserOperation`, and `DeliveryReverted` is a landed on-chain verdict that the app
    /// already treats as terminal. Only `BundlerRejected` needs the extra bit, because it is the
    /// one code that spans both sides of the send. Travelling as a separate field rather than a
    /// second code keeps the code space (and the app's copy map) stable.
    pub fn submitted(&self) -> Option<bool> {
        match self {
            ExitError::BundlerRejected { submitted, .. } => Some(*submitted),
            _ => None,
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

/// Serialise a wei amount as a `0x`-hex STRING. The in-memory type stays `u128`.
///
/// A JSON *number* here would be a silent correctness bug, not a style question. 2^53 wei is
/// **0.009 ETH**, so essentially every real exit is already past the point a Double-backed
/// JSON decoder can represent exactly, and beyond ~18.44 ETH it leaves `u64` too — the app
/// would render a subtly wrong "you received" figure with no error raised anywhere. Hex
/// strings also match what `BalanceSplit` and `maxUnshieldable` already put on the wire, so
/// every wei amount crossing this boundary has one form.
fn hex_wei<S: serde::Serializer>(v: &u128, s: S) -> Result<S::Ok, S::Error> {
    s.serialize_str(&format!("0x{v:x}"))
}

/// Everything known once the bundler has accepted the op.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExitSubmission {
    pub user_op_hash: String,
    pub sender: String,
    /// Wei of NATIVE ETH the callData forwards to the recipient.
    #[serde(serialize_with = "hex_wei")]
    pub delivered_wei: u128,
    pub exit_index: u32,
}

impl ExitSubmission {
    /// The outcome as known at submission time: every fact except inclusion, which is not yet
    /// determined.
    ///
    /// This is what lets the sidecar publish its `submitted` state in the SAME schema that
    /// receipt polling will later overwrite it with. Publishing a bare `ExitSubmission` there
    /// instead would put two different shapes behind one status string — one with `included`,
    /// one without — and a client decoder with a non-optional `included` would decode the
    /// phase-2 form and fail the phase-1 form.
    pub fn pending_outcome(&self) -> ExitOutcome {
        ExitOutcome {
            user_op_hash: self.user_op_hash.clone(),
            sender: self.sender.clone(),
            delivered_wei: self.delivered_wei,
            exit_index: self.exit_index,
            included: false,
        }
    }
}

/// The result of waiting on a submitted exit — and, with `included: false`, also the state
/// published the moment the bundler accepts the op (see [`ExitSubmission::pending_outcome`]).
///
/// There is no `reverted` field: a revert is `ExitError::DeliveryReverted`, so the only two
/// outcomes here are "landed successfully" (`included: true`) and "not yet known"
/// (`included: false`). A `reverted` flag could only ever be constructed `false`, which would
/// hand the RPC handler and the app card a branch that can never fire.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExitOutcome {
    pub user_op_hash: String,
    pub sender: String,
    /// Wei of NATIVE ETH forwarded to the recipient.
    #[serde(serialize_with = "hex_wei")]
    pub delivered_wei: u128,
    pub exit_index: u32,
    pub included: bool,
}

/// Fail closed when RailgunSmartWallet's live unshield fee disagrees with the rate our
/// arithmetic assumed.
///
/// `configured_bps` comes from Kohaku's `ChainConfig`, where 25 is a HARDCODED constant, but
/// `unshieldFee` is a governance-settable state variable on the contract. At 50 bps,
/// `delivered_lower_bound` would over-claim by ~2.5e15 wei on a 1 ETH exit — five orders of
/// magnitude past the 1000-wei epsilon — so `WETH.withdraw` would revert in the EXECUTION
/// phase, *after* the unshield already executed during paymaster validation. That strands the
/// full amount, on every exit thereafter, silently.
///
/// We refuse rather than adapt: an unexpected rate means the arithmetic assumptions need
/// re-checking by a human, which is this project's fail-closed convention.
pub fn check_unshield_fee_matches(configured_bps: u16, onchain_bps: U256) -> Result<(), ExitError> {
    if onchain_bps == U256::from(configured_bps) {
        return Ok(());
    }
    Err(ExitError::Other(format!(
        "RailgunSmartWallet reports an unshield fee of {onchain_bps} bps but this build's \
         amount arithmetic assumes {configured_bps} bps; refusing to exit until the fee \
         handling is re-checked"
    )))
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

    // Built from `pending_outcome` so the polled outcome and the `submitted` state the handler
    // already published can never drift apart in any field but `included`.
    let outcome = |included: bool| ExitOutcome {
        included,
        ..sub.pending_outcome()
    };

    let started = std::time::Instant::now();
    loop {
        if started.elapsed() > budget {
            return Ok(outcome(false));
        }
        match bundler.wait_for_receipt(hash).await {
            Ok(receipt) if receipt.success => return Ok(outcome(true)),
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
///
/// `fee_bps` must be the rate the contract will ACTUALLY charge, not just the one Kohaku's
/// `ChainConfig` hardcodes — the caller verifies that against `unshieldFee()` via
/// [`check_unshield_fee_matches`] before sizing anything on this result.
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
    fn error_codes_are_stable_wire_strings() {
        // The app switches card state on these; renaming one silently breaks the UI.
        assert_eq!(ExitError::FeeDidNotConverge.code(), "feeDidNotConverge");
        assert_eq!(
            ExitError::BundlerRejected {
                message: "nope".into(),
                exit_index: 4,
                sender: "0xbeef".into(),
                submitted: true,
            }
            .code(),
            "bundlerRejected"
        );
        // `submitted` must NOT fork the code — it is a separate field precisely so the code
        // space (and the app's copy map) stays stable across both situations.
        assert_eq!(
            ExitError::BundlerRejected {
                message: "nope".into(),
                exit_index: 4,
                sender: "0xbeef".into(),
                submitted: false,
            }
            .code(),
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
    fn a_submitted_bundler_rejection_names_the_recoverable_index_and_sender() {
        // `send_user_operation` can POST successfully and lose the response, leaving the op in
        // the mempool: it lands, validation runs, the unshield executes. So this error must
        // carry the same recovery pointer as DeliveryReverted, and must NOT claim the op was
        // rejected or that the funds are safe.
        let e = ExitError::BundlerRejected {
            message: "connection reset".into(),
            exit_index: 11,
            sender: "0xsender".into(),
            submitted: true,
        };
        assert_eq!(e.submitted(), Some(true));
        let msg = e.to_string();
        assert!(msg.contains("11"), "must name the index: {msg}");
        assert!(msg.contains("0xsender"), "must name the sender: {msg}");
        assert!(
            msg.contains("connection reset"),
            "must keep the cause: {msg}"
        );
        assert!(
            !msg.contains("no bundler accepted"),
            "must not assert the op was rejected: {msg}"
        );
        assert!(
            !msg.contains("nothing left the pool"),
            "must not claim the funds are safe — the op may land: {msg}"
        );
    }

    #[test]
    fn an_unsubmitted_bundler_rejection_says_plainly_that_nothing_moved() {
        // The gas-estimation rejection reaches the app under the SAME code, and this is the half
        // that must read as a clean failure: `eth_sendUserOperation` was never called, so no op
        // exists anywhere and the notes are still in the pool. Hedging here is what made the app
        // show a permanently-Submitted card for an exit that provably never started.
        let e = ExitError::BundlerRejected {
            message: "rejected during gas estimation: AA33 reverted".into(),
            exit_index: 11,
            sender: "0xsender".into(),
            submitted: false,
        };
        assert_eq!(e.submitted(), Some(false));
        let msg = e.to_string();
        assert!(
            msg.contains("nothing left the pool"),
            "must state plainly that nothing moved: {msg}"
        );
        assert!(msg.contains("AA33"), "must keep the cause: {msg}");
        assert!(
            !msg.contains("if it was submitted"),
            "must not hedge about a send that never happened: {msg}"
        );
    }

    #[test]
    fn only_a_bundler_rejection_reports_a_submitted_bit() {
        // Every other code's meaning is already unambiguous, so `submitted` stays absent from the
        // wire for them rather than inviting the app to branch on a value it can't interpret.
        assert_eq!(ExitError::FeeDidNotConverge.submitted(), None);
        assert_eq!(ExitError::PaymasterNotConfigured.submitted(), None);
        assert_eq!(
            ExitError::DeliveryReverted {
                exit_index: 3,
                user_op_hash: "0xabc".into()
            }
            .submitted(),
            None
        );
        assert_eq!(ExitError::Other("x".into()).submitted(), None);
    }

    #[test]
    fn matching_unshield_fee_passes_and_a_changed_one_fails_closed() {
        // The rate our arithmetic assumes must be the rate the contract charges. Verified live
        // at the time of writing: unshieldFee() == 25 on both mainnet and Sepolia.
        assert!(check_unshield_fee_matches(25, U256::from(25)).is_ok());

        // A governance change to 50 bps would make delivered_lower_bound over-claim by ~2.5e15
        // wei on a 1 ETH exit, so `withdraw` reverts AFTER the unshield already executed —
        // stranding the full amount. Refuse instead of adapting.
        let err = check_unshield_fee_matches(25, U256::from(50))
            .expect_err("a changed fee must fail closed");
        let msg = err.to_string();
        assert!(
            msg.contains("50") && msg.contains("25"),
            "names both: {msg}"
        );
        assert_eq!(err.code(), "error");

        // A fee *drop* is also a mismatch: it means our model of the contract is stale.
        assert!(check_unshield_fee_matches(25, U256::from(0)).is_err());
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
