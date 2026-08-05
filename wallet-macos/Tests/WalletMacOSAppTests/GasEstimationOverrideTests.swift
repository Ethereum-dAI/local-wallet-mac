import Testing
@testable import WalletMacOSApp

@Suite struct GasEstimationOverrideTests {
    @Test func derivesGasEstimationUnavailableFromPersistedToolResponse() throws {
        let json = """
        {"status":"gas_estimation_unavailable","intent_id":"ABC",\
        "detail":"helios_error: proof fetch failed","suggested_call_gas_limit":600000}
        """
        let status = ChatIntentExecutionStatus.fromToolResponse(json)

        guard case let .gasEstimationUnavailable(detail, suggested) = try #require(status) else {
            Issue.record("expected gasEstimationUnavailable")
            return
        }
        #expect(detail == "helios_error: proof fetch failed")
        #expect(suggested == 600_000)
    }

    @Test func unrelatedStatusesStillDecode() throws {
        let failed = ChatIntentExecutionStatus.fromToolResponse(
            #"{"status":"failed","error":"boom"}"#
        )
        #expect(failed == .failed("boom"))

        #expect(ChatIntentExecutionStatus.fromToolResponse("not json") == nil)
    }

    @Test func buildsGasEstimationUnavailableStatusFromClientError() throws {
        let error = WalletNodeClient.ClientError.rpcError(
            method: "localwallet_estimateUserOperationGas",
            code: -32002,
            message: "Not ready: gas_estimation_unavailable",
            reason: "gas_estimation_unavailable",
            detail: "helios_error: proof fetch failed",
            suggestedCallGasLimit: 600_000
        )

        let status = try #require(ChatIntentExecutionStatus.gasEstimationUnavailable(from: error))
        #expect(status == .gasEstimationUnavailable(
            detail: "helios_error: proof fetch failed",
            suggestedCallGasLimit: 600_000
        ))

        // A -32002 without a suggestion is an ordinary failure, not an override offer.
        let plain = WalletNodeClient.ClientError.rpcError(
            method: "localwallet_estimateUserOperationGas",
            code: -32002,
            message: "Not ready: rpc_error",
            reason: "rpc_error"
        )
        #expect(ChatIntentExecutionStatus.gasEstimationUnavailable(from: plain) == nil)
    }

    @Test func derivesPrefundShortfallFromPersistedToolResponse() throws {
        let json = """
        {"status":"prefund_shortfall","intent_id":"ABC",\
        "required_prefund":"0xaa87bee538000","available":"0x2386f26fc10000",\
        "deficit":"0x71afd498d0000","effective_call_gas_limit":600000}
        """
        let status = ChatIntentExecutionStatus.fromToolResponse(json)

        #expect(status == .prefundShortfall(
            PrefundPrecheck.Report(
                requiredPrefundWeiHex: "0xaa87bee538000",
                availableWeiHex: "0x2386f26fc10000",
                deficitWeiHex: "0x71afd498d0000",
                effectiveCallGasLimit: 600_000
            )
        ))
    }

    @Test func prefundShortfallWithNegativeLimitDegradesToFailed() throws {
        // chat.sqlite round trip: a negative Int must not trap on UInt64.init.
        let json = """
        {"status":"prefund_shortfall","required_prefund":"0x1",\
        "available":"0x0","deficit":"0x1","effective_call_gas_limit":-3}
        """
        guard case .failed = try #require(ChatIntentExecutionStatus.fromToolResponse(json)) else {
            Issue.record("expected a degraded .failed")
            return
        }
    }

    @Test func buildsPrefundShortfallStatusFromAppError() throws {
        let report = PrefundPrecheck.Report(
            requiredPrefundWeiHex: "0xaa87bee538000",
            availableWeiHex: "0x2386f26fc10000",
            deficitWeiHex: "0x71afd498d0000",
            effectiveCallGasLimit: 600_000
        )
        let error = AppError.prefundShortfall(report)

        #expect(ChatIntentExecutionStatus.prefundShortfall(from: error) == .prefundShortfall(report))
        #expect(ChatIntentExecutionStatus.prefundShortfall(from: AppError.invalidAmount) == nil)
    }
}
