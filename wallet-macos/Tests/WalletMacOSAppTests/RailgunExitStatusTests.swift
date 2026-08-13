import XCTest
@testable import WalletMacOSApp

/// Pins the wire shapes `railgun-helper` actually emits (see
/// `local-wallet-railgun/src/bin/railgun-helper.rs`, `submitted_and_done_share_one_schema_with_hex_wei_amounts`
/// and `error_status_carries_the_stable_code`), so the decoders here match reality and not a
/// stale draft of it.
final class RailgunExitStatusTests: XCTestCase {
    func testDecodesSubmittedStatusWithDeliveredAsset() throws {
        // `deliveredWei` on the wire is ALWAYS a 0x-hex string, never a JSON number (see
        // below) — this fixture uses a real hex string rather than a bare number so the test
        // cannot pass against a Double/Int-backed decode by accident.
        let json = """
        {"status":"submitted","deliveredAsset":"ETH","result":{"userOpHash":"0xabc","sender":"0xdef","deliveredWei":"0x230F","exitIndex":3,"included":false}}
        """.data(using: .utf8)!
        let st = try JSONDecoder().decode(RailgunHelperClient.UnshieldStatus.self, from: json)
        XCTAssertEqual(st.status, "submitted")
        XCTAssertEqual(st.deliveredAsset, "ETH")
        XCTAssertNil(st.code)
    }

    func testDecodesErrorStatusWithStableCode() throws {
        let json = """
        {"status":"error","code":"feeDidNotConverge","error":"gas is moving too fast"}
        """.data(using: .utf8)!
        let st = try JSONDecoder().decode(RailgunHelperClient.UnshieldStatus.self, from: json)
        XCTAssertEqual(st.code, "feeDidNotConverge")
        XCTAssertNil(st.submitted, "codes with an unambiguous meaning carry no submitted bit")
    }

    /// `bundlerRejected` is the one code that spans both sides of `eth_sendUserOperation`, so the
    /// sidecar sends a `submitted` bit alongside it (`error_status` in `railgun-helper.rs`). Losing
    /// it in the decoder would collapse the two situations back into one and re-introduce the
    /// false "Reverted" this pair of fields exists to prevent.
    func testDecodesTheSubmittedBitOnBothBundlerRejections() throws {
        func decode(_ submitted: Bool) throws -> RailgunHelperClient.UnshieldStatus {
            let json = """
            {"status":"error","code":"bundlerRejected","submitted":\(submitted),"error":"whatever"}
            """.data(using: .utf8)!
            return try JSONDecoder().decode(RailgunHelperClient.UnshieldStatus.self, from: json)
        }
        XCTAssertEqual(try decode(false).submitted, false)
        XCTAssertEqual(try decode(true).submitted, true)
    }

    /// `deliveredAsset` is not merely decoded — it is CHECKED, because the card renders
    /// `deliveredWei` with an " ETH" suffix. If the exit's tail call ever stopped unwrapping WETH,
    /// a silently ignored field would show the user a WETH amount labelled as ETH.
    func testATerminalResultRefusesADeliveredAssetTheAppCannotRender() throws {
        func status(asset: String?) throws -> RailgunHelperClient.UnshieldStatus {
            let assetField = asset.map { "\"deliveredAsset\":\"\($0)\"," } ?? ""
            let json = """
            {"status":"done",\(assetField)"result":{"deliveredWei":"0x230F","included":true}}
            """.data(using: .utf8)!
            return try JSONDecoder().decode(RailgunHelperClient.UnshieldStatus.self, from: json)
        }
        XCTAssertNoThrow(try status(asset: "ETH").exitResult())
        // Absent is tolerated (the field is optional on the wire); a WRONG value is not.
        XCTAssertNoThrow(try status(asset: nil).exitResult())
        XCTAssertThrowsError(try status(asset: "WETH").exitResult()) { error in
            guard case RailgunHelperClient.ClientError.decodeFailed(let m) = error else {
                return XCTFail("expected decodeFailed, got \(error)")
            }
            XCTAssertTrue(m.contains("WETH"), "must name what it got: \(m)")
        }
    }

    func testDecodesMaxUnshieldable() throws {
        let json = """
        {"maxValueWei":"0x2710","receivableAtMaxWei":"0x2317","reserveWei":"0x64"}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(RailgunHelperClient.MaxUnshieldable.self, from: json)
        XCTAssertEqual(m.maxValueWei, "0x2710")
        XCTAssertEqual(m.receivableAtMaxWei, "0x2317")
        XCTAssertEqual(m.reserveWei, "0x64")
    }

    func testBreakdownStatesTheTreasuryFeeAndGasReserve() {
        let text = RailgunExitCopy.unshieldBreakdown(
            requestedWei: "0x2710",       // 10000
            receivableWei: "0x230F",      // 8975 = floor(10000*9975/10000) − 1000 guard
            reserveWei: "0x64"            // 100
        )
        XCTAssertTrue(text.contains("0.25%"), "must name the treasury fee: \(text)")
        XCTAssertTrue(text.lowercased().contains("gas"), "must explain the gas reserve: \(text)")
    }

    /// `WeiFormatter.ethDisplayString` already appends the " ETH" unit suffix, so the
    /// breakdown template must NOT append its own " ETH" after each interpolated value —
    /// caught by hand-inspecting the actual rendered string, since the substring assertions
    /// above pass either way ("0 ETH" is a substring of "0 ETH ETH" too).
    func testBreakdownDoesNotDoubleTheEthUnit() {
        let text = RailgunExitCopy.unshieldBreakdown(
            requestedWei: "0x2710",
            receivableWei: "0x230F",
            reserveWei: "0x64"
        )
        XCTAssertFalse(text.contains("ETH ETH"), "must not double the ETH unit: \(text)")
    }

    /// The brief is explicit that BOTH deductions must be visible, not just named in prose —
    /// a user who sees only the fee percentage (or only the word "gas") with no numbers to
    /// match against their balance will think the figures don't add up. Pin that the actual
    /// formatted amounts for both the recipient's net and the gas reserve appear verbatim.
    func testBreakdownNamesBothDeductionsWithTheirAmounts() {
        let text = RailgunExitCopy.unshieldBreakdown(
            requestedWei: "0x2710",
            receivableWei: "0x230F",
            reserveWei: "0x64"
        )
        let receivable = WeiFormatter.ethDisplayString(fromHexWei: "0x230F")
        let reserve = WeiFormatter.ethDisplayString(fromHexWei: "0x64")
        XCTAssertTrue(text.contains(receivable), "must show what the recipient nets: \(text)")
        XCTAssertTrue(text.contains(reserve), "must show the gas reserve held back: \(text)")
    }

    /// The two fields on `MaxUnshieldable` are NOT interchangeable: `maxValueWei` is what the
    /// sidecar will accept as `amountWei` (and so what the Max button must fill in / validate
    /// against), while `receivableAtMaxWei` is only what the recipient would net at that amount
    /// — display-only. Swapping them would either reject a valid Max request (if receivable is
    /// smaller) or attempt to move more than the sidecar allows.
    func testMaxAffordanceFillsMaxValueNotReceivable() {
        let max = RailgunHelperClient.MaxUnshieldable(
            maxValueWei: "0x2710",
            receivableAtMaxWei: "0x230F",
            reserveWei: "0x64"
        )
        XCTAssertEqual(RailgunExitCopy.maxUnshieldFillAmountWei(max), max.maxValueWei)
        XCTAssertNotEqual(
            RailgunExitCopy.maxUnshieldFillAmountWei(max), max.receivableAtMaxWei,
            "the fixture's two values differ on purpose — this must fail if the wrong field is wired"
        )
    }

    /// The Max breakdown must not survive an edit that moves the composer away from what Max
    /// filled in — the failure mode being guarded against is a stale "you will receive" figure
    /// for an amount the user is no longer about to send, which is worse than no figure at all.
    func testMaxBreakdownIsClearedOnceTheComposerNoLongerMatchesTheFill() {
        let filled = "/unshield 0.01 to <recipient>"
        // The exact string Max just wrote: no clear.
        XCTAssertFalse(
            RailgunExitCopy.shouldClearMaxBreakdown(composerText: filled, lastMaxFillComposerText: filled)
        )
        // The user edited the amount down: clear.
        XCTAssertTrue(
            RailgunExitCopy.shouldClearMaxBreakdown(
                composerText: "/unshield 0.001 to <recipient>", lastMaxFillComposerText: filled
            )
        )
        // The user typed the recipient in (still nominally "the same command" to a human, but
        // NOT the same string Max wrote): clear. This is deliberately strict — the predicate
        // does not try to parse the amount back out, it only compares the whole string.
        XCTAssertTrue(
            RailgunExitCopy.shouldClearMaxBreakdown(
                composerText: "/unshield 0.01 to 0xRecipient", lastMaxFillComposerText: filled
            )
        )
        // The user switched to a completely different command: clear.
        XCTAssertTrue(
            RailgunExitCopy.shouldClearMaxBreakdown(composerText: "/shield 0.01", lastMaxFillComposerText: filled)
        )
        // Max has never been used yet (`lastMaxFillComposerText == nil`): any composer text —
        // even empty — compares unequal to `nil`, so this returns true too. That's harmless
        // (there's no breakdown to clear yet, so the model just assigns `nil` to `nil`), and
        // the important thing pinned here is that the predicate doesn't crash on a `nil`
        // `lastMaxFillComposerText` — the state before Max is ever used.
        XCTAssertTrue(
            RailgunExitCopy.shouldClearMaxBreakdown(composerText: "", lastMaxFillComposerText: nil)
        )
    }

    /// Guards the load-bearing detail from the wire contract: `deliveredWei` MUST decode as a
    /// string, never a number. 2^53 wei is only 0.009 ETH, so a Double-backed decode would
    /// silently corrupt essentially every real delivered amount. This value (1 ETH in wei) is
    /// chosen specifically because it is already past 2^53.
    func testDeliveredWeiSurvivesAsHexStringPastDoublePrecision() throws {
        let json = """
        {"status":"done","deliveredAsset":"ETH","result":{"userOpHash":"0x1c3fa5b0e2d47c8916aa0b3d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7081","sender":"0x4b39f7b0624b9db86ad293686bc38b903142dbbc","deliveredWei":"0xde0b6b3a7640000","exitIndex":3,"included":true}}
        """.data(using: .utf8)!
        let st = try JSONDecoder().decode(RailgunHelperClient.UnshieldStatus.self, from: json)
        guard case let .object(result)? = st.result,
              case let .string(deliveredWei)? = result["deliveredWei"] else {
            XCTFail("deliveredWei must decode as a JSON string, not a number")
            return
        }
        XCTAssertEqual(deliveredWei, "0xde0b6b3a7640000")
    }

    /// `submitted` and `done` are asserted to share one non-optional `result` schema (the
    /// sidecar's own test pins the same thing on the Rust side) — a client that required
    /// `included` to already be `true` would fail to decode the `submitted` phase.
    func testSubmittedAndDoneShareOneResultSchema() throws {
        func decode(_ status: String, included: Bool) throws -> RailgunHelperClient.UnshieldStatus {
            let json = """
            {"status":"\(status)","deliveredAsset":"ETH","result":{"userOpHash":"0xabc","sender":"0xdef","deliveredWei":"0x64","exitIndex":1,"included":\(included)}}
            """.data(using: .utf8)!
            return try JSONDecoder().decode(RailgunHelperClient.UnshieldStatus.self, from: json)
        }
        let submitted = try decode("submitted", included: false)
        let done = try decode("done", included: true)
        XCTAssertEqual(submitted.result?["exitIndex"], done.result?["exitIndex"])
        XCTAssertEqual(submitted.result?["userOpHash"], done.result?["userOpHash"])
    }

    func testExitFailureCopyIsActionablePerCode() {
        let converge = RailgunExitCopy.exitFailureMessage(
            code: "feeDidNotConverge", message: "raw rust error"
        )
        XCTAssertFalse(converge.contains("raw rust error"), "must not leak the raw error")
        XCTAssertTrue(converge.lowercased().contains("try again"), "must tell the user what to do")

        // Reassurance belongs ONLY where nothing was submitted.
        for code in ["feeDidNotConverge", "bundlerUnavailable", "paymasterNotConfigured"] {
            let copy = RailgunExitCopy.exitFailureMessage(code: code, message: "raw")
            XCTAssertTrue(
                copy.lowercased().contains("untouched"),
                "\(code) cannot have submitted anything, so it must reassure: \(copy)"
            )
        }

        // `bundlerRejected` is the trap: the sidecar words it as "did not confirm" precisely
        // because a lost response leaves the op in the mempool, where it may still land and
        // execute the unshield. Claiming the funds are untouched would invite a double exit, and
        // dropping the message would discard the exit index + sender that locate already-spent
        // notes (see `ExitError::BundlerRejected` and
        // `bundler_rejection_names_the_recoverable_index_and_sender`).
        let rejected = RailgunExitCopy.exitFailureMessage(
            code: "bundlerRejected", message: "recoverable at index 11 (sender 0xsender)"
        )
        XCTAssertFalse(
            rejected.lowercased().contains("untouched"),
            "must NOT claim the funds are untouched — the op may have landed: \(rejected)"
        )
        XCTAssertTrue(
            rejected.contains("recoverable at index 11 (sender 0xsender)"),
            "the recovery pointer must survive: \(rejected)"
        )

        // deliveryReverted is the one case where the detail matters for a bug report.
        let reverted = RailgunExitCopy.exitFailureMessage(
            code: "deliveryReverted", message: "index 7"
        )
        XCTAssertTrue(reverted.contains("index 7"), "recovery detail must survive")
        // Nothing shipped here can sweep an exit sender, so the copy must route the user to a
        // developer rather than imply recovery is something they can perform.
        XCTAssertTrue(
            reverted.lowercased().contains("developer"),
            "must not promise self-service recovery: \(reverted)"
        )
        XCTAssertFalse(
            reverted.contains("funds are recoverable"),
            "the unqualified claim is what this copy exists to avoid: \(reverted)"
        )

        // Unknown codes must fall through, never be swallowed into a generic string.
        XCTAssertEqual(
            RailgunExitCopy.exitFailureMessage(code: "somethingNew", message: "verbatim"),
            "verbatim"
        )
        // A missing code means the generic `error`, which is also a fall-through.
        XCTAssertEqual(
            RailgunExitCopy.exitFailureMessage(code: nil, message: "verbatim"),
            "verbatim"
        )
    }

    /// Both sidecar failure paths carry a code and must reach the same copy: a synchronous
    /// rejection (`error.data.code`) and an async job failure (`status: error` + `code`). A
    /// non-RAILGUN error must pass through untouched so its own handler keeps its message.
    func testFailureCopyIsSelectedByCodeFromBothErrorCases() {
        XCTAssertEqual(
            RailgunExitCopy.failureCopy(
                for: RailgunHelperClient.ClientError.exitFailed(
                    code: "bundlerRejected", message: "raw", submitted: true
                )
            ),
            RailgunExitCopy.exitFailureMessage(code: "bundlerRejected", message: "raw", submitted: true)
        )
        XCTAssertEqual(
            RailgunExitCopy.failureCopy(
                for: RailgunHelperClient.ClientError.rpcError(code: "insufficientShieldedBalance", message: "5 wei exceeds 3 wei")
            ),
            RailgunExitCopy.exitFailureMessage(code: "insufficientShieldedBalance", message: "5 wei exceeds 3 wei")
        )
        XCTAssertNil(
            RailgunExitCopy.failureCopy(for: RailgunHelperClient.ClientError.ioFailed("socket")),
            "transport failures have no domain code and must keep their own description"
        )
        XCTAssertNil(RailgunExitCopy.failureCopy(for: URLError(.timedOut)))
    }

    /// The invariant that matters most in this feature: a card is flipped to Reverted ONLY when
    /// the sidecar itself reported the job failed. Every other error describes the POLL, and each
    /// of these has a routine cause that coexists with a perfectly successful exit — so
    /// reverting on one would tell a user whose funds arrived that they didn't.
    func testOnlyASidecarReportedFailureRevertsTheCard() {
        XCTAssertTrue(
            RailgunExitCopy.shouldRevertCard(
                for: RailgunHelperClient.ClientError.exitFailed(
                    code: "deliveryReverted", message: "index 7", submitted: nil
                )
            ),
            "a terminal job failure is the one thing that justifies Reverted"
        )
        // An exitFailed with no code is still the sidecar reporting `status: error`.
        XCTAssertTrue(
            RailgunExitCopy.shouldRevertCard(
                for: RailgunHelperClient.ClientError.exitFailed(
                    code: nil, message: "unshield failed", submitted: nil
                )
            )
        )

        // The sidecar evicts terminal jobs ON READ, and phase 1 returns on `done` as well as
        // `submitted` — so a fast inclusion consumes the job and a later poll legitimately finds
        // nothing, with the card already correctly Done.
        XCTAssertFalse(
            RailgunExitCopy.shouldRevertCard(
                for: RailgunHelperClient.ClientError.rpcError(code: "unknownJobId", message: "unknown jobId: job-1")
            ),
            "an evicted terminal job means the exit SUCCEEDED, not that it failed"
        )
        // The helper was re-spawned (RPC/chain switch) under a detached poll.
        XCTAssertFalse(
            RailgunExitCopy.shouldRevertCard(for: RailgunHelperClient.ClientError.connectFailed("ENOENT"))
        )
        // A poll queued behind a long UTXO sync, or phase 1's own deadline. The sidecar calls
        // phase 1 unbounded, so any fixed client deadline can be exceeded mid-flight.
        XCTAssertFalse(
            RailgunExitCopy.shouldRevertCard(
                for: RailgunHelperClient.ClientError.ioFailed("unshield job job-1 was not submitted before the deadline")
            )
        )
        XCTAssertFalse(
            RailgunExitCopy.shouldRevertCard(for: RailgunHelperClient.ClientError.decodeFailed("UnshieldStatus"))
        )
        XCTAssertFalse(
            RailgunExitCopy.shouldRevertCard(for: RailgunHelperClient.ClientError.httpError("HTTP/1.1 401"))
        )
        // Every other sync rejection is about the request, not the exit's outcome.
        XCTAssertFalse(
            RailgunExitCopy.shouldRevertCard(
                for: RailgunHelperClient.ClientError.rpcError(code: "badRequest", message: "missing jobId")
            )
        )
        XCTAssertFalse(RailgunExitCopy.shouldRevertCard(for: URLError(.timedOut)))
    }

    /// The branch's only outcome misreport, pinned from both sides.
    ///
    /// `bundlerRejected` covers two situations the sidecar can tell apart but one wire code
    /// cannot: refused during gas estimation (nothing sent, nothing moved) and a lost response to
    /// `eth_sendUserOperation` (the op may be in the mempool and the unshield may execute). The
    /// card must revert for the first and must NOT for the second, so the decision reads
    /// `submitted`.
    func testBundlerRejectionRevertsOnlyWhenNothingWasSubmitted() {
        func error(_ submitted: Bool?) -> RailgunHelperClient.ClientError {
            .exitFailed(code: "bundlerRejected", message: "recoverable at index 11 (sender 0xs)", submitted: submitted)
        }
        // Pre-send: nothing moved, so Reverted is the accurate card.
        XCTAssertTrue(
            RailgunExitCopy.shouldRevertCard(for: error(false)),
            "a rejection during gas estimation moved nothing — Reverted is correct"
        )
        // Possibly submitted: the unshield may still execute, so reverting would be a false report.
        XCTAssertFalse(
            RailgunExitCopy.shouldRevertCard(for: error(true)),
            "the op may be in the mempool — must not claim it reverted"
        )
        // A missing bit takes the hedged branch: a card left Submitted for a failed exit is
        // recoverable by looking at the chain; telling a user their landed exit reverted is not.
        XCTAssertFalse(RailgunExitCopy.shouldRevertCard(for: error(nil)))

        // Every OTHER coded exit failure still reverts — the refinement is scoped to this one code.
        XCTAssertTrue(
            RailgunExitCopy.shouldRevertCard(
                for: RailgunHelperClient.ClientError.exitFailed(
                    code: "feeDidNotConverge", message: "raw", submitted: nil
                )
            )
        )
    }

    /// Both halves of `bundlerRejected` must read correctly, and they are opposites: the pre-send
    /// half is the ONLY one allowed to reassure, and the possibly-submitted half is the only one
    /// that must carry the recovery pointer.
    func testBundlerRejectionCopySplitsOnWhetherAnythingWasSubmitted() {
        let preSend = RailgunExitCopy.exitFailureMessage(
            code: "bundlerRejected", message: "rejected during gas estimation: AA33 reverted",
            submitted: false
        )
        XCTAssertTrue(
            preSend.lowercased().contains("untouched"),
            "nothing was submitted, so this must reassure: \(preSend)"
        )
        XCTAssertTrue(preSend.contains("AA33"), "must keep the cause for a bug report: \(preSend)")

        let maybeSubmitted = RailgunExitCopy.exitFailureMessage(
            code: "bundlerRejected", message: "recoverable at index 11 (sender 0xsender)",
            submitted: true
        )
        XCTAssertFalse(
            maybeSubmitted.lowercased().contains("untouched"),
            "the op may have landed — must not claim the funds are safe: \(maybeSubmitted)"
        )
        XCTAssertTrue(
            maybeSubmitted.contains("recoverable at index 11 (sender 0xsender)"),
            "the recovery pointer must survive: \(maybeSubmitted)"
        )
        XCTAssertNotEqual(preSend, maybeSubmitted, "the two situations must not share one sentence")
    }

    /// The note shown when the wallet stops waiting but does NOT revert the card. For a
    /// possibly-submitted `bundlerRejected` the generic sentence would silently drop the exit index
    /// and sender that locate already-spent notes, which is the whole reason the sidecar sends them.
    func testTheInFlightNoticeKeepsARecoveryPointerWhenThereIsOne() {
        let hedged = RailgunExitCopy.inFlightNotice(
            for: RailgunHelperClient.ClientError.exitFailed(
                code: "bundlerRejected", message: "recoverable at index 11 (sender 0xsender)",
                submitted: true
            )
        )
        XCTAssertTrue(hedged.contains("index 11"), "must keep the recovery pointer: \(hedged)")

        // A transport failure has no domain code, so it falls back to the generic note.
        XCTAssertEqual(
            RailgunExitCopy.inFlightNotice(for: RailgunHelperClient.ClientError.ioFailed("read: errno 60")),
            RailgunExitCopy.exitStillInFlightMessage
        )
    }

    /// The sidecar's `insufficientShieldedBalance` sentence is deliberately number-free (naming the
    /// ceiling and the reserve would write the user's shielded balance — exactly their sum — into
    /// the macOS unified log), so the app's copy must carry the explanation itself and must not
    /// echo raw wei integers at the user.
    func testInsufficientBalanceCopyIsSelfContainedAndShowsNoRawWei() {
        let copy = RailgunExitCopy.exitFailureMessage(
            code: "insufficientShieldedBalance",
            message: "that amount is more than can currently leave the pool: gas for the exit is paid by a fee note inside the pool, so some of the shielded balance has to stay behind"
        )
        XCTAssertTrue(copy.lowercased().contains("gas"), "must explain why: \(copy)")
        XCTAssertTrue(copy.lowercased().contains("max"), "must point at the Max affordance: \(copy)")
        XCTAssertFalse(copy.contains("wei"), "must not surface raw wei to the user: \(copy)")
        XCTAssertFalse(
            copy.contains(" more than can currently leave the pool"),
            "must not append the sidecar's sentence verbatim: \(copy)"
        )
    }

    /// Max must never fill `/unshield 0 to <recipient>`: with an empty pool — or gas high enough
    /// that the in-pool fee reserve exceeds the whole balance — the ceiling saturates to zero, and
    /// a "receives 0 ETH" breakdown looks like a working affordance right up until the send fails.
    func testMaxIsGuardedWhenNothingIsUnshieldable() {
        // Zero wei in each of the forms the sidecar could plausibly emit.
        for hex in ["0x0", "0x00000", "0", "0X0"] {
            XCTAssertTrue(
                RailgunExitCopy.hasNothingToUnshield(maxValueWei: hex, renderedAmount: "0"),
                "\(hex) is zero and must be guarded"
            )
        }
        // Non-zero wei that still RENDERS as zero: the composer scaffold takes a decimal ETH
        // string, so this fills the same useless command.
        XCTAssertTrue(
            RailgunExitCopy.hasNothingToUnshield(maxValueWei: "0x1", renderedAmount: "0.000000")
        )
        // A real ceiling must not be guarded away.
        XCTAssertFalse(
            RailgunExitCopy.hasNothingToUnshield(maxValueWei: "0x2386f26fc10000", renderedAmount: "0.01")
        )
        // An unparseable rendering is left alone rather than guessed at.
        XCTAssertFalse(
            RailgunExitCopy.hasNothingToUnshield(maxValueWei: "0x2710", renderedAmount: "Unavailable")
        )
        // The copy has to say BOTH that nothing is unshieldable and why; a bare "0" reads as a bug.
        let copy = RailgunExitCopy.nothingUnshieldableMessage
        XCTAssertTrue(copy.lowercased().contains("nothing can be unshielded"), copy)
        XCTAssertTrue(copy.lowercased().contains("gas"), "must say why: \(copy)")
    }

    /// The copy for a give-up must not read as a failure, and must steer away from a retry that
    /// would exit twice.
    func testStillInFlightCopyDoesNotReadAsFailure() {
        let copy = RailgunExitCopy.exitStillInFlightMessage
        XCTAssertTrue(copy.lowercased().contains("still in progress"))
        XCTAssertTrue(
            copy.lowercased().contains("before trying again"),
            "must steer the user away from an immediate retry: \(copy)"
        )
        for banned in ["failed", "reverted", "untouched"] {
            XCTAssertFalse(copy.lowercased().contains(banned), "must not claim \(banned): \(copy)")
        }
    }

    /// The stable code travels in the JSON-RPC error's `data.code`, not its transport-level
    /// integer `code`. Dropping it would force the view layer back to substring-matching a
    /// message the sidecar deliberately stripped of its prefix.
    func testSyncRejectionCarriesTheStableCodeFromErrorData() throws {
        let body = """
        {"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"5 wei exceeds the spendable maximum 3 wei","data":{"code":"insufficientShieldedBalance"}}}
        """
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n\(body)".utf8)
        do {
            _ = try RailgunHelperClient.parseBody(raw)
            XCTFail("an error body must throw")
        } catch let RailgunHelperClient.ClientError.rpcError(code, message) {
            XCTAssertEqual(code, "insufficientShieldedBalance")
            XCTAssertEqual(message, "5 wei exceeds the spendable maximum 3 wei")
        }
    }

    /// A peer that sends no `data.code` (or a transport-level JSON-RPC error like an unknown
    /// method) has no domain code to recover, so it must read as "no code" rather than crash or
    /// invent one.
    func testSyncRejectionWithoutDataCodeHasNoCode() throws {
        let body = """
        {"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"unknown method: nope"}}
        """
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n\(body)".utf8)
        do {
            _ = try RailgunHelperClient.parseBody(raw)
            XCTFail("an error body must throw")
        } catch let RailgunHelperClient.ClientError.rpcError(code, message) {
            XCTAssertNil(code)
            XCTAssertEqual(message, "unknown method: nope")
        }
    }
}
