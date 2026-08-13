import Foundation
import Testing
@testable import WalletMacOSApp

private final class FeeOracleURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, [String: Any]) throws -> (Int, [String: Any]))?
    nonisolated(unsafe) static var responseURLOverride: URL?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let body = try Self.requestBody(request)
            let handler = try #require(Self.handler)
            let (status, payload) = try handler(request, body)
            let data = try JSONSerialization.data(withJSONObject: payload)
            let url = try #require(Self.responseURLOverride ?? request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func requestBody(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                result.append(buffer, count: count)
            }
            data = result
        } else {
            data = Data()
        }
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

@Suite(.serialized)
struct ExecutionFeeOracleTests {
    private let rpcURL = URL(string: "https://rpc.example")!
    private let chainID: UInt64 = 11_155_111

    init() {
        FeeOracleURLProtocol.handler = nil
        FeeOracleURLProtocol.responseURLOverride = nil
    }

    private func oracle() -> ExecutionFeeOracle {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeeOracleURLProtocol.self]
        return ExecutionFeeOracle(session: URLSession(configuration: configuration))
    }

    private func installValidHandler(
        chainIDHex: String = "0xaa36a7",
        oldestBlock: String = "0x64",
        baseFees: [String] = ["0x5", "0x6", "0x7", "0x7", "0x8", "0x8"],
        rewards: [[String]]? = [["0x5"], ["0x1"], ["0x9"], ["0x3"], ["0x7"]]
    ) {
        FeeOracleURLProtocol.responseURLOverride = nil
        FeeOracleURLProtocol.handler = { _, body in
            let id = try #require(body["id"] as? Int)
            switch body["method"] as? String {
            case "eth_chainId":
                return (200, ["jsonrpc": "2.0", "id": id, "result": chainIDHex])
            case "eth_feeHistory":
                let params = try #require(body["params"] as? [Any])
                #expect(params.count == 3)
                #expect(params[0] as? String == "0x5")
                #expect(params[1] as? String == "latest")
                let percentiles = try #require(params[2] as? [Double])
                #expect(percentiles == [50])
                var result: [String: Any] = [
                    "oldestBlock": oldestBlock,
                    "baseFeePerGas": baseFees,
                    "gasUsedRatio": [0.5, 0.5, 0.5, 0.5, 0.5],
                ]
                if let rewards { result["reward"] = rewards }
                return (200, ["jsonrpc": "2.0", "id": id, "result": result])
            default:
                Issue.record("unexpected RPC method")
                return (500, ["error": "unexpected method"])
            }
        }
    }

    @Test func fetchesChainBoundFeeHistoryAndRoundsEveryGrowthBlockUp() async throws {
        installValidHandler()
        let issuedAt = Date(timeIntervalSince1970: 1_000)

        let quote = try await oracle().quote(
            rpcURL: rpcURL,
            expectedChainID: chainID,
            now: issuedAt
        )

        #expect(quote.chainID == chainID)
        #expect(quote.blockNumber == 104)
        #expect(quote.issuedAt == issuedAt)
        #expect(quote.nextBlockBaseFeePerGas == Data.fromBigEndian(UInt64(8)).leftPadded(to: 32))
        #expect(quote.medianPriorityFeePerGas == Data.fromBigEndian(UInt64(5)).leftPadded(to: 32))
        // ceil growth from 8 for six blocks: 9, 11, 13, 15, 17, 20; then add the 5 wei tip.
        #expect(quote.sixBlockMaxFeePerGas == Data.fromBigEndian(UInt64(25)).leftPadded(to: 32))
    }

    @Test func rejectsWrongChainBeforeUsingFeeHistory() async {
        installValidHandler(chainIDHex: "0x1")

        await #expect(throws: ExecutionFeeOracleError.self) {
            _ = try await oracle().quote(rpcURL: rpcURL, expectedChainID: chainID)
        }
    }

    @Test func rejectsMalformedCanonicalQuantity() async {
        installValidHandler(baseFees: ["0x5", "0x6", "0x7", "0x7", "0x8", "0x00"])

        await #expect(throws: ExecutionFeeOracleError.self) {
            _ = try await oracle().quote(rpcURL: rpcURL, expectedChainID: chainID)
        }
    }

    @Test func rejectsMalformedRewardQuantityAndEmptyRewardRow() async {
        installValidHandler(rewards: [["0x5"], ["0x1"], ["0x00"], ["0x3"], ["0x7"]])
        await #expect(throws: ExecutionFeeOracleError.self) {
            _ = try await oracle().quote(rpcURL: rpcURL, expectedChainID: chainID)
        }

        installValidHandler(rewards: [["0x5"], ["0x1"], [], ["0x3"], ["0x7"]])
        await #expect(throws: ExecutionFeeOracleError.self) {
            _ = try await oracle().quote(rpcURL: rpcURL, expectedChainID: chainID)
        }
    }

    @Test func rejectsWrongFeeHistoryLengthAndOldestBlockOverflow() async {
        installValidHandler(baseFees: ["0x5", "0x6"])
        await #expect(throws: ExecutionFeeOracleError.self) {
            _ = try await oracle().quote(rpcURL: rpcURL, expectedChainID: chainID)
        }

        installValidHandler(oldestBlock: "0xffffffffffffffff")
        await #expect(throws: ExecutionFeeOracleError.self) {
            _ = try await oracle().quote(rpcURL: rpcURL, expectedChainID: chainID)
        }
    }

    @Test func rejectsMissingRewardHistory() async {
        installValidHandler(rewards: nil)

        await #expect(throws: ExecutionFeeOracleError.self) {
            _ = try await oracle().quote(rpcURL: rpcURL, expectedChainID: chainID)
        }
    }

    @Test func rejectsMaximumWidthBaseFeeAndRewardWithoutTruncation() async {
        let u256Maximum = "0x" + String(repeating: "f", count: 64)
        let cases: [(baseFees: [String], rewards: [[String]])] = [
            (
                ["0x1", "0x1", "0x1", "0x1", "0x1", u256Maximum],
                Array(repeating: ["0x1"], count: 5)
            ),
            (
                Array(repeating: "0x0", count: 6),
                Array(repeating: [u256Maximum], count: 5)
            ),
        ]

        for testCase in cases {
            installValidHandler(
                baseFees: testCase.baseFees,
                rewards: testCase.rewards
            )
            do {
                _ = try await oracle().quote(rpcURL: rpcURL, expectedChainID: chainID)
                Issue.record("A maximum-width fee quantity was accepted")
            } catch let error as ExecutionFeeOracleError {
                guard case .feePolicyViolation = error else {
                    Issue.record("Unexpected fee-oracle error: \(error)")
                    continue
                }
            } catch {
                Issue.record("Unexpected fee-oracle error type: \(error)")
            }
        }
    }

    @Test func immutableMaximumFeeCapAcceptsExactValueAndRejectsOneWeiMore() async throws {
        let base = Data.fromBigEndian(UInt64(22_500_000_000)).leftPadded(to: 32)
        let grown = try GasPricing.sixBlockBaseFeeCeiling(nextBlockBaseFeePerGas: base)
        let exactPriority = try GasPricing.checkedSubtractWei(GasPricing.appMaxFeePerGas, grown)
        let exactPriorityValue = try GasPricing.exactUInt64(exactPriority, field: "test priority")
        let baseHex = "0x" + String(22_500_000_000, radix: 16)
        let priorityHex = "0x" + String(exactPriorityValue, radix: 16)
        installValidHandler(
            baseFees: ["0x1", "0x1", "0x1", "0x1", "0x1", baseHex],
            rewards: Array(repeating: [priorityHex], count: 5)
        )
        _ = try await oracle().quote(rpcURL: rpcURL, expectedChainID: chainID)

        let overPriorityHex = "0x" + String(exactPriorityValue + 1, radix: 16)
        installValidHandler(
            baseFees: ["0x1", "0x1", "0x1", "0x1", "0x1", baseHex],
            rewards: Array(repeating: [overPriorityHex], count: 5)
        )
        await #expect(throws: ExecutionFeeOracleError.self) {
            _ = try await oracle().quote(rpcURL: rpcURL, expectedChainID: chainID)
        }
    }

    @Test func immutablePriorityCapAcceptsExactValueAndRejectsOneWeiMore() async throws {
        let exact = "0x" + String(5_000_000_000, radix: 16)
        installValidHandler(
            baseFees: Array(repeating: "0x0", count: 6),
            rewards: Array(repeating: [exact], count: 5)
        )
        _ = try await oracle().quote(rpcURL: rpcURL, expectedChainID: chainID)

        let over = "0x" + String(5_000_000_001, radix: 16)
        installValidHandler(
            baseFees: Array(repeating: "0x0", count: 6),
            rewards: Array(repeating: [over], count: 5)
        )
        await #expect(throws: ExecutionFeeOracleError.self) {
            _ = try await oracle().quote(rpcURL: rpcURL, expectedChainID: chainID)
        }
    }

    @Test func rejectsRPCFailure() async {
        FeeOracleURLProtocol.handler = { _, body in
            let id = try #require(body["id"] as? Int)
            return (200, [
                "jsonrpc": "2.0",
                "id": id,
                "error": ["code": -32_000, "message": "upstream unavailable"],
            ])
        }

        await #expect(throws: ExecutionFeeOracleError.self) {
            _ = try await oracle().quote(rpcURL: rpcURL, expectedChainID: chainID)
        }
    }

    @Test func rejectsHTTPFailure() async {
        FeeOracleURLProtocol.handler = { _, body in
            let id = try #require(body["id"] as? Int)
            return (503, ["jsonrpc": "2.0", "id": id, "result": "0xaa36a7"])
        }

        await #expect(throws: ExecutionFeeOracleError.self) {
            _ = try await oracle().quote(rpcURL: rpcURL, expectedChainID: chainID)
        }
    }

    @Test func rejectsTransportFailureAndNullResult() async {
        FeeOracleURLProtocol.handler = { _, _ in throw URLError(.timedOut) }
        await #expect(throws: ExecutionFeeOracleError.self) {
            _ = try await oracle().quote(rpcURL: rpcURL, expectedChainID: chainID)
        }

        FeeOracleURLProtocol.handler = { _, body in
            let id = try #require(body["id"] as? Int)
            return (200, ["jsonrpc": "2.0", "id": id, "result": NSNull()])
        }
        await #expect(throws: ExecutionFeeOracleError.self) {
            _ = try await oracle().quote(rpcURL: rpcURL, expectedChainID: chainID)
        }
    }

    @Test func permitsOnlyHTTPSOrLoopbackHTTP() async throws {
        installValidHandler()
        _ = try await oracle().quote(rpcURL: rpcURL, expectedChainID: chainID)
        _ = try await oracle().quote(
            rpcURL: URL(string: "http://127.0.0.1:8545")!,
            expectedChainID: chainID
        )

        await #expect(throws: ExecutionFeeOracleError.self) {
            _ = try await oracle().quote(
                rpcURL: URL(string: "http://rpc.example")!,
                expectedChainID: chainID
            )
        }
    }

    @Test func rejectsAResponseThatDowngradesToNonLoopbackHTTP() async {
        installValidHandler()
        FeeOracleURLProtocol.responseURLOverride = URL(string: "http://rpc.example")!

        await #expect(throws: ExecutionFeeOracleError.self) {
            _ = try await oracle().quote(rpcURL: rpcURL, expectedChainID: chainID)
        }
    }

    @Test func rejectsQuoteOlderThanThirtySecondsOrMoreThanTwoBlocksBehind() throws {
        let quote = ExecutionFeeQuote(
            chainID: chainID,
            blockNumber: 100,
            issuedAt: Date(timeIntervalSince1970: 1_000),
            nextBlockBaseFeePerGas: Data(repeating: 0, count: 32),
            medianPriorityFeePerGas: Data(repeating: 0, count: 32),
            sixBlockMaxFeePerGas: Data(repeating: 0, count: 32)
        )

        try quote.validateFreshness(now: Date(timeIntervalSince1970: 1_030), currentBlockNumber: 102)
        #expect(throws: ExecutionFeeOracleError.self) {
            try quote.validateFreshness(now: Date(timeIntervalSince1970: 1_030.001), currentBlockNumber: 102)
        }
        #expect(throws: ExecutionFeeOracleError.self) {
            try quote.validateFreshness(now: Date(timeIntervalSince1970: 1_010), currentBlockNumber: 103)
        }
        #expect(throws: ExecutionFeeOracleError.self) {
            try quote.validateFreshness(now: Date(timeIntervalSince1970: 999), currentBlockNumber: 100)
        }
        #expect(throws: ExecutionFeeOracleError.self) {
            try quote.validateFreshness(now: Date(timeIntervalSince1970: 1_010), currentBlockNumber: 99)
        }
    }

    @Test func networkFreshnessCheckVerifiesChainAndCurrentHead() async throws {
        let quote = ExecutionFeeQuote(
            chainID: chainID,
            blockNumber: 100,
            issuedAt: Date(timeIntervalSince1970: 1_000),
            nextBlockBaseFeePerGas: Data(repeating: 0, count: 32),
            medianPriorityFeePerGas: Data(repeating: 0, count: 32),
            sixBlockMaxFeePerGas: Data(repeating: 0, count: 32)
        )
        FeeOracleURLProtocol.handler = { _, body in
            let id = try #require(body["id"] as? Int)
            switch body["method"] as? String {
            case "eth_chainId":
                return (200, ["jsonrpc": "2.0", "id": id, "result": "0xaa36a7"])
            case "eth_blockNumber":
                return (200, ["jsonrpc": "2.0", "id": id, "result": "0x66"])
            default:
                return (500, ["jsonrpc": "2.0", "id": id, "error": ["code": -1]])
            }
        }
        try await oracle().validateFreshness(
            of: quote,
            rpcURL: rpcURL,
            expectedChainID: chainID,
            now: Date(timeIntervalSince1970: 1_030)
        )

        FeeOracleURLProtocol.handler = { _, body in
            let id = try #require(body["id"] as? Int)
            switch body["method"] as? String {
            case "eth_chainId":
                return (200, ["jsonrpc": "2.0", "id": id, "result": "0xaa36a7"])
            case "eth_blockNumber":
                return (200, ["jsonrpc": "2.0", "id": id, "result": "0x67"])
            default:
                return (500, ["jsonrpc": "2.0", "id": id, "error": ["code": -1]])
            }
        }
        await #expect(throws: ExecutionFeeOracleError.self) {
            try await oracle().validateFreshness(
                of: quote,
                rpcURL: rpcURL,
                expectedChainID: chainID,
                now: Date(timeIntervalSince1970: 1_030)
            )
        }
    }
}
