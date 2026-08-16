import Foundation
import Testing
import WalletSignature
@testable import WalletMacOSApp

final class UserOperationSubmissionURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseHash = ""
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedSignature: String?
    nonisolated(unsafe) static var capturedParams: [Any]?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let body = try Self.readBody(request)
            Self.capturedMethod = body["method"] as? String
            if let params = body["params"] as? [Any],
               let userOperation = params.first as? [String: Any] {
                Self.capturedParams = params
                Self.capturedSignature = userOperation["signature"] as? String
            }

            let data = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "id": 1,
                "result": Self.responseHash,
            ])
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readBody(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

final class PostSignFreshnessURLProtocol: URLProtocol {
    nonisolated(unsafe) static var chainID = "0xaa36a7"
    nonisolated(unsafe) static var blockNumbers = ["0x64"]
    nonisolated(unsafe) static var requestedMethods: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let body = try Self.readBody(request)
            let method = try #require(body["method"] as? String)
            Self.requestedMethods.append(method)
            let result: String
            switch method {
            case "eth_chainId":
                result = Self.chainID
            case "eth_blockNumber":
                result = try #require(Self.blockNumbers.first)
                Self.blockNumbers.removeFirst()
            default:
                Issue.record("Unexpected execution RPC method: \(method)")
                result = "0x0"
            }
            let data = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "id": 1,
                "result": result,
            ])
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readBody(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

@Suite(.serialized) struct UserOperationSubmissionTests {
    @Test func walletNodeSubmitsSignedOperationAndReturnsCanonicalLocalHash() async throws {
        let operation = try makeSignedOperation()
        UserOperationSubmissionURLProtocol.responseHash = operation.userOpHashHex.uppercased()
        Self.resetCapture()

        let result = try await walletNodeClient().sendUserOperation(
            operation: operation,
            expectedRelayer: try expectedRelayer(for: operation)
        )

        #expect(result == operation.userOpHashHex)
        #expect(UserOperationSubmissionURLProtocol.capturedMethod == "localwallet_sendUserOperation")
        #expect(UserOperationSubmissionURLProtocol.capturedSignature == "0xaabb")
        #expect(UserOperationSubmissionURLProtocol.capturedParams?.count == 3)
    }

    @Test func walletNodeBindsSubmissionToExpectedRelayerIdentity() async throws {
        let operation = try makeSignedOperation()
        let expectedRelayer = try VerifiedRelayerIdentity(
            chainID: operation.draft.chainId,
            keyRef: "bundler-eoa:default:\(operation.draft.chainId):7",
            address: "0x2222222222222222222222222222222222222222"
        )
        UserOperationSubmissionURLProtocol.responseHash = operation.userOpHashHex
        Self.resetCapture()

        let result = try await walletNodeClient().sendUserOperation(
            operation: operation,
            expectedRelayer: expectedRelayer
        )

        #expect(result == operation.userOpHashHex)
        let params = try #require(UserOperationSubmissionURLProtocol.capturedParams)
        #expect(params.count == 3)
        let binding = try #require(params[2] as? [String: Any])
        #expect(Set(binding.keys) == ["chainId", "keyRef", "address"])
        #expect((binding["chainId"] as? NSNumber)?.uint64Value == operation.draft.chainId)
        #expect(binding["keyRef"] as? String == expectedRelayer.keyRef)
        #expect(binding["address"] as? String == expectedRelayer.address)
    }

    @Test func walletNodeRejectsReturnedHashThatDoesNotMatchSignedOperation() async throws {
        let operation = try makeSignedOperation()
        let wrongHash = "0x" + String(repeating: "ff", count: 32)
        UserOperationSubmissionURLProtocol.responseHash = wrongHash
        Self.resetCapture()

        await #expect(
            throws: UserOperationBoundaryError.returnedHashMismatch(
                expected: operation.userOpHashHex,
                actual: wrongHash
            )
        ) {
            _ = try await walletNodeClient().sendUserOperation(
                operation: operation,
                expectedRelayer: try expectedRelayer(for: operation)
            )
        }
    }

    @Test func returnedHashMismatchPreventsEveryAcceptanceSideEffect() async throws {
        let operation = try makeSignedOperation(usedSession: true)
        let wrongHash = "0x" + String(repeating: "fe", count: 32)
        let probe = SubmissionAcceptanceProbe()
        UserOperationSubmissionURLProtocol.responseHash = wrongHash
        Self.resetCapture()

        await #expect(
            throws: UserOperationBoundaryError.returnedHashMismatch(
                expected: operation.userOpHashHex,
                actual: wrongHash
            )
        ) {
            _ = try await submitAndRecordAcceptance(
                operation: operation,
                probe: probe
            )
        }

        #expect(probe.optimisticNonceWrites == 0)
        #expect(probe.historyWrites == 0)
        #expect(probe.sessionStateWrites == 0)
    }

    @Test func matchingReturnedHashAllowsAcceptanceSideEffectsOnce() async throws {
        let operation = try makeSignedOperation(usedSession: true)
        let probe = SubmissionAcceptanceProbe()
        UserOperationSubmissionURLProtocol.responseHash = operation.userOpHashHex
        Self.resetCapture()

        let result = try await submitAndRecordAcceptance(
            operation: operation,
            probe: probe
        )

        #expect(result == operation.userOpHashHex)
        #expect(probe.optimisticNonceWrites == 1)
        #expect(probe.historyWrites == 1)
        #expect(probe.sessionStateWrites == 1)
    }

    @Test func bundlerSubmitsSignedOperationAndReturnsCanonicalLocalHash() async throws {
        let operation = try makeSignedOperation()
        UserOperationSubmissionURLProtocol.responseHash = operation.userOpHashHex
        Self.resetCapture()

        let result = try await bundlerClient().sendUserOperation(
            chain: bundlerChain(),
            operation: operation
        )

        #expect(result == operation.userOpHashHex)
        #expect(UserOperationSubmissionURLProtocol.capturedMethod == "eth_sendUserOperation")
        #expect(UserOperationSubmissionURLProtocol.capturedSignature == "0xaabb")
    }

    @Test func bundlerRejectsReturnedHashThatDoesNotMatchSignedOperation() async throws {
        let operation = try makeSignedOperation()
        let wrongHash = "0x" + String(repeating: "11", count: 32)
        UserOperationSubmissionURLProtocol.responseHash = wrongHash
        Self.resetCapture()

        await #expect(
            throws: UserOperationBoundaryError.returnedHashMismatch(
                expected: operation.userOpHashHex,
                actual: wrongHash
            )
        ) {
            _ = try await bundlerClient().sendUserOperation(
                chain: bundlerChain(),
                operation: operation
            )
        }
    }

    @MainActor
    @Test func postSignGateRejectsOwnerOperationThatAgedDuringAuthenticationWithoutTransport() async throws {
        let operation = try makeSignedOperation()
        Self.resetFreshnessRPC(blockNumber: 100)
        var transportCalls = 0

        await #expect(
            throws: ExecutionFeeOracleError.staleQuote(
                age: ExecutionFeeQuote.maximumAge + 1
            )
        ) {
            _ = try await UserOperationSubmission.submit(
                operation: operation,
                rpcURL: Self.freshnessRPCURL,
                expectedChainID: operation.draft.chainId,
                oracle: freshnessOracle(),
                now: {
                    operation.operation.feeQuote.issuedAt.addingTimeInterval(
                        ExecutionFeeQuote.maximumAge + 1
                    )
                },
                transport: { _ in
                    transportCalls += 1
                    return operation.userOpHashHex
                }
            )
        }

        #expect(operation.usedSession == false)
        #expect(transportCalls == 0)
        #expect(PostSignFreshnessURLProtocol.requestedMethods == ["eth_chainId", "eth_blockNumber"])
    }

    @MainActor
    @Test func postSignGateRejectsSessionOperationAfterHeadAdvancesWithoutTransport() async throws {
        let operation = try makeSignedOperation(usedSession: true)
        Self.resetFreshnessRPC(
            blockNumber: operation.operation.feeQuote.blockNumber
                + ExecutionFeeQuote.maximumHeadAdvance
                + 1
        )
        var transportCalls = 0

        await #expect(
            throws: ExecutionFeeOracleError.headAdvancedTooFar(
                quoteBlock: operation.operation.feeQuote.blockNumber,
                currentBlock: operation.operation.feeQuote.blockNumber
                    + ExecutionFeeQuote.maximumHeadAdvance
                    + 1
            )
        ) {
            _ = try await UserOperationSubmission.submit(
                operation: operation,
                rpcURL: Self.freshnessRPCURL,
                expectedChainID: operation.draft.chainId,
                oracle: freshnessOracle(),
                now: { operation.operation.feeQuote.issuedAt.addingTimeInterval(1) },
                transport: { _ in
                    transportCalls += 1
                    return operation.userOpHashHex
                }
            )
        }

        #expect(operation.usedSession)
        #expect(transportCalls == 0)
        #expect(PostSignFreshnessURLProtocol.requestedMethods == ["eth_chainId", "eth_blockNumber"])
    }

    @MainActor
    @Test func postSignGateSubmitsFreshSignedOperationExactlyOnce() async throws {
        let operation = try makeSignedOperation()
        Self.resetFreshnessRPC(
            blockNumber: operation.operation.feeQuote.blockNumber
                + ExecutionFeeQuote.maximumHeadAdvance
        )
        var submittedOperation: SignedUserOperation?

        let result = try await UserOperationSubmission.submit(
            operation: operation,
            rpcURL: Self.freshnessRPCURL,
            expectedChainID: operation.draft.chainId,
            oracle: freshnessOracle(),
            now: {
                operation.operation.feeQuote.issuedAt.addingTimeInterval(
                    ExecutionFeeQuote.maximumAge
                )
            },
            transport: { candidate in
                submittedOperation = candidate
                return candidate.userOpHashHex
            }
        )

        #expect(result == operation.userOpHashHex)
        #expect(submittedOperation == operation)
        #expect(PostSignFreshnessURLProtocol.requestedMethods == ["eth_chainId", "eth_blockNumber"])
    }

    @MainActor
    @Test func relaunchRetryRechecksHeadAndRejectsStaleQuoteWithoutSecondTransport() async throws {
        let operation = try makeSignedOperation()
        Self.resetFreshnessRPC(blockNumbers: [
            operation.operation.feeQuote.blockNumber,
            operation.operation.feeQuote.blockNumber
                + ExecutionFeeQuote.maximumHeadAdvance
                + 1,
        ])
        var transportCalls = 0
        var recoverableFailures = 0

        do {
            for attempt in 0..<2 {
                do {
                    _ = try await UserOperationSubmission.submit(
                        operation: operation,
                        rpcURL: Self.freshnessRPCURL,
                        expectedChainID: operation.draft.chainId,
                        oracle: freshnessOracle(),
                        now: { operation.operation.feeQuote.issuedAt.addingTimeInterval(1) },
                        transport: { _ in
                            transportCalls += 1
                            throw SimulatedRecoverableWalletNodeFailure.socketClosed
                        }
                    )
                } catch is SimulatedRecoverableWalletNodeFailure where attempt == 0 {
                    recoverableFailures += 1
                    continue
                }
            }
            Issue.record("A stale signed operation reached the relaunched transport")
        } catch {
            #expect(
                error as? ExecutionFeeOracleError == .headAdvancedTooFar(
                    quoteBlock: operation.operation.feeQuote.blockNumber,
                    currentBlock: operation.operation.feeQuote.blockNumber
                        + ExecutionFeeQuote.maximumHeadAdvance
                        + 1
                )
            )
        }

        #expect(recoverableFailures == 1)
        #expect(transportCalls == 1)
        #expect(PostSignFreshnessURLProtocol.requestedMethods == [
            "eth_chainId",
            "eth_blockNumber",
            "eth_chainId",
            "eth_blockNumber",
        ])
    }

    private static func resetCapture() {
        UserOperationSubmissionURLProtocol.capturedMethod = nil
        UserOperationSubmissionURLProtocol.capturedSignature = nil
        UserOperationSubmissionURLProtocol.capturedParams = nil
    }

    private static let freshnessRPCURL = URL(string: "http://127.0.0.1:8545")!

    private static func resetFreshnessRPC(blockNumber: UInt64) {
        resetFreshnessRPC(blockNumbers: [blockNumber])
    }

    private static func resetFreshnessRPC(blockNumbers: [UInt64]) {
        PostSignFreshnessURLProtocol.chainID = "0xaa36a7"
        PostSignFreshnessURLProtocol.blockNumbers = blockNumbers.map {
            "0x" + String($0, radix: 16)
        }
        PostSignFreshnessURLProtocol.requestedMethods = []
    }

    private func submitAndRecordAcceptance(
        operation: SignedUserOperation,
        probe: SubmissionAcceptanceProbe
    ) async throws -> String {
        let hash = try await walletNodeClient().sendUserOperation(
            operation: operation,
            expectedRelayer: try expectedRelayer(for: operation)
        )
        probe.optimisticNonceWrites += 1
        probe.historyWrites += 1
        probe.sessionStateWrites += 1
        return hash
    }

    private func expectedRelayer(
        for operation: SignedUserOperation
    ) throws -> VerifiedRelayerIdentity {
        try VerifiedRelayerIdentity(
            chainID: operation.draft.chainId,
            keyRef: "bundler-eoa:default:\(operation.draft.chainId):7",
            address: "0x2222222222222222222222222222222222222222"
        )
    }

    private func makeSignedOperation(usedSession: Bool = false) throws -> SignedUserOperation {
        let draft = UserOperationDraft(
            sender: "0x1111111111111111111111111111111111111111",
            nonce: Data(repeating: 0, count: 32),
            initCode: Data(),
            callData: Data([0xde, 0xad]),
            gasPlan: .placeholder,
            entryPoint: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
            chainId: 11_155_111
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let blockNumber: UInt64 = 100
        let baseFee = Self.word(1_000_000_000)
        let priorityFee = Self.word(1_000_000_000)
        let grownBaseFee = try GasPricing.sixBlockBaseFeeCeiling(
            nextBlockBaseFeePerGas: baseFee
        )
        let maxFee = try GasPricing.checkedAddWei(grownBaseFee, priorityFee)
        let operation = try UserOperationGasAuthorizer.authorize(
            draft: draft,
            callGasLimit: Self.word(125_000),
            verificationGasLimit: Self.word(250_000),
            maxPriorityFeePerGas: priorityFee,
            maxFeePerGas: maxFee,
            expectedSignatureLength: 2,
            authorizationScope: .owner,
            feeQuote: ExecutionFeeQuote(
                chainID: draft.chainId,
                blockNumber: blockNumber,
                issuedAt: now,
                nextBlockBaseFeePerGas: baseFee,
                medianPriorityFeePerGas: priorityFee,
                sixBlockMaxFeePerGas: maxFee
            )
        )
        return try UserOperationSigning.signForSend(
            operation: operation,
            currentBlockNumber: blockNumber,
            now: now,
            session: usedSession
                ? UserOperationSigning.SessionContext(
                    keyRef: "session:test",
                    mode: .installed,
                    enableData: Data(),
                    selectorData: Data(),
                    enableSig: Data()
                )
                : nil,
            passkeySigner: { _ in
                SignatureComponents(
                    rawRepresentation: Data(repeating: 0xaa, count: 64),
                    r: Data(repeating: 0xbb, count: 32),
                    s: Data(repeating: 0x01, count: 32)
                )
            },
            passkeyWrapper: { _, _ in Data([0xaa, 0xbb]) },
            sessionSecretReader: { _ in Data([0x01]) },
            sessionWrapper: { _, _, _, _, _, _ in Data([0xaa, 0xbb]) }
        )
    }

    private static func word(_ value: UInt64) -> Data {
        Data.fromBigEndian(value).leftPadded(to: 32)
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UserOperationSubmissionURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func walletNodeClient() -> WalletNodeClient {
        WalletNodeClient(
            configuration: .init(
                transport: .http(URL(string: "http://wallet-node.stub")!),
                bearerToken: "test-token"
            ),
            session: session()
        )
    }

    private func freshnessOracle() -> ExecutionFeeOracle {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PostSignFreshnessURLProtocol.self]
        return ExecutionFeeOracle(session: URLSession(configuration: configuration))
    }

    private func bundlerClient() -> BundlerClient {
        BundlerClient(session: session())
    }

    private func bundlerChain() -> ChainConfiguration {
        let base = ChainConfiguration.ethereumSepolia
        return ChainConfiguration(
            id: base.id,
            name: base.name,
            shortName: base.shortName,
            rpcURL: base.rpcURL,
            archiveRPCURL: base.archiveRPCURL,
            consensusRPCURL: base.consensusRPCURL,
            bundlerURL: URL(string: "http://bundler.stub")!,
            entryPoint: base.entryPoint,
            kernel: base.kernel,
            abiResources: base.abiResources
        )
    }
}

private enum SimulatedRecoverableWalletNodeFailure: Error {
    case socketClosed
}

private final class SubmissionAcceptanceProbe {
    var optimisticNonceWrites = 0
    var historyWrites = 0
    var sessionStateWrites = 0
}
