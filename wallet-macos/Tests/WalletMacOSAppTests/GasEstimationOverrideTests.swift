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
}
