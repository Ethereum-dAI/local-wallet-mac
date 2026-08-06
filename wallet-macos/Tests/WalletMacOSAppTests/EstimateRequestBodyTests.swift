import Foundation
import Testing
@testable import WalletMacOSApp

/// Captures the outbound JSON-RPC body so the request shape can be asserted.
/// `nonisolated(unsafe)` static storage is safe because the suite below is
/// `.serialized`.
final class CapturingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedUserOperation: [String: Any]?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let body = Self.readBody(request),
           let params = body["params"] as? [Any],
           let userOperation = params.first as? [String: Any] {
            Self.capturedUserOperation = userOperation
        }
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "result": [
                "callGasLimit": "0x927c0",
                "verificationGasLimit": "0xf4240",
                "preVerificationGas": "0xd903",
                "requiredPrefund": "0xaa87bee538000",
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(_ request: URLRequest) -> [String: Any]? {
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
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

@Suite(.serialized) struct EstimateRequestBodyTests {
    private func client() -> WalletNodeClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CapturingURLProtocol.self]
        return WalletNodeClient(
            configuration: .init(
                transport: .http(URL(string: "http://stub")!),
                bearerToken: "t"
            ),
            session: URLSession(configuration: configuration)
        )
    }

    private func pricedDraft() -> UserOperationDraft {
        UserOperationDraft(
            sender: "0x1111111111111111111111111111111111111111",
            nonce: Data(repeating: 0, count: 32),
            initCode: Data(),
            callData: Data([0xde, 0xad]),
            gasPlan: UserOperationGasPlan(
                accountGasLimits: Data(repeating: 0, count: 32),
                preVerificationGas: Data(repeating: 0, count: 32),
                // maxPriorityFeePerGas = 1 gwei, maxFeePerGas = 30 gwei.
                gasFees: Data.fromBigEndian(UInt64(1_000_000_000)).leftPadded(to: 16)
                    + Data.fromBigEndian(UInt64(30_000_000_000)).leftPadded(to: 16),
                paymasterAndData: Data()
            ),
            entryPoint: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
            chainId: 11_155_111
        )
    }

    @Test func forwardsDraftFeesAndKeepsLimitsZeroed() async throws {
        CapturingURLProtocol.capturedUserOperation = nil

        let estimate = try await client().estimateUserOperationGas(
            draft: pricedDraft(),
            dummySignature: Data([0x01]),
            acknowledgedCallGasLimit: 600_000
        )

        let sent = try #require(CapturingURLProtocol.capturedUserOperation)

        // Load-bearing: requiredPrefund is (limits × maxFeePerGas). Zeroed fees
        // make it zero and every downstream check inert.
        #expect(sent["maxFeePerGas"] as? String
            == "0x" + Data.fromBigEndian(UInt64(30_000_000_000)).leftPadded(to: 32).hexEncodedString)
        #expect(sent["maxPriorityFeePerGas"] as? String
            == "0x" + Data.fromBigEndian(UInt64(1_000_000_000)).leftPadded(to: 32).hexEncodedString)

        // Equally load-bearing: the limits stay zeroed. Sending client-invented
        // limits would wake the daemon's estimate-time funding check, which runs
        // before it resolves the real limits.
        #expect(sent["callGasLimit"] as? String == "0x0")
        #expect(sent["verificationGasLimit"] as? String == "0x0")
        #expect(sent["preVerificationGas"] as? String == "0x0")

        #expect(estimate.requiredPrefund.count == 32)
    }
}
