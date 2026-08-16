import Foundation
import Testing
@testable import WalletMacOSApp

final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let body = try bodyDict(request)
            let params = body["params"] as? [String]
            #expect(params?.first == "0xbeef")
            let result: [String: Any]
            switch body["method"] as? String {
            case "wallet_cancelPendingOperation":
                result = [
                    "userOpHash": "0xbeef",
                    "txHash": "0xcancelTx",
                    "replacementOf": "0xoldCancelTx",
                    "nonce": 7,
                ]
            case "wallet_speedUpPendingOperation":
                result = [
                    "userOpHash": "0xbeef",
                    "txHash": "0xspeedTx",
                    "replacementOf": "0xoldSpeedTx",
                    "nonce": 7,
                ]
            case "localwallet_getUserOperationStatus":
                result = [
                    "userOpHash": "0xbeef",
                    "status": "failed",
                    "lastError": "auto_dropped_aged_no_receipt",
                    "createdAt": 10,
                    "updatedAt": 20,
                ]
            default:
                throw URLError(.badServerResponse)
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
}

private func bodyDict(_ request: URLRequest) throws -> [String: Any] {
    let data: Data
    if let body = request.httpBody {
        data = body
    } else if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = Data()
        var temp = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&temp, maxLength: temp.count)
            if count <= 0 {
                break
            }
            buffer.append(temp, count: count)
        }
        data = buffer
    } else {
        data = Data()
    }
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func stubbedClient() -> WalletNodeClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return WalletNodeClient(
        configuration: .init(transport: .http(URL(string: "http://stub")!), bearerToken: "t"),
        session: URLSession(configuration: configuration)
    )
}

@Test func rpcErrorDescriptionIncludesDaemonDetail() {
    let error = WalletNodeClient.ClientError.rpcError(
        method: "localwallet_estimateUserOperationGas",
        code: -32002,
        message: "Not ready: helios_error",
        reason: "helios_error",
        detail: "out of sync: 42 blocks behind"
    )

    #expect(error.localizedDescription.contains("helios_error"))
    #expect(error.localizedDescription.contains("detail: out of sync: 42 blocks behind"))
}

@Test func decodesGasEstimationUnavailableError() throws {
    let body = """
    {"jsonrpc":"2.0","id":1,"error":{"code":-32002,\
    "message":"Not ready: gas_estimation_unavailable",\
    "data":{"reason":"gas_estimation_unavailable",\
    "detail":"helios_error: proof fetch failed",\
    "suggestedCallGasLimit":"0x927c0"}}}
    """
    let error = WalletNodeClient.decodeRPCError(
        from: try #require(body.data(using: .utf8)),
        method: "localwallet_estimateUserOperationGas"
    )

    guard case let .rpcError(_, code, _, reason, detail, suggested) = try #require(error) else {
        Issue.record("expected an rpcError")
        return
    }
    #expect(code == -32002)
    #expect(reason == "gas_estimation_unavailable")
    #expect(detail == "helios_error: proof fetch failed")
    #expect(suggested == 600_000)
}

@Test func treatsGasEstimationUnavailableAsRetryable() {
    let error = WalletNodeClient.ClientError.rpcError(
        method: "localwallet_estimateUserOperationGas",
        code: -32002,
        message: "Not ready: gas_estimation_unavailable",
        reason: "gas_estimation_unavailable",
        detail: nil,
        suggestedCallGasLimit: 600_000
    )

    #expect(WalletNodeWarmupRetryPolicy.isWarmupError(error))
}

@Test func encodesAcknowledgedCallGasLimitAsThirdParam() throws {
    let params = WalletNodeClient.estimateGasParams(
        userOperation: ["sender": "0x00"],
        entryPoint: "0xEP",
        acknowledgedCallGasLimit: 600_000
    )

    #expect(params.count == 3)
    let options = try #require(params[2] as? [String: String])
    #expect(options["acknowledgedCallGasLimit"] == "0x927c0")

    let omitted = WalletNodeClient.estimateGasParams(
        userOperation: ["sender": "0x00"],
        entryPoint: "0xEP",
        acknowledgedCallGasLimit: nil
    )
    #expect(omitted.count == 2)
}

@Test func decodesBundlerStatusReplacementBlock() throws {
    var json: [String: Any] = [
        "ready": true,
        "keyLoaded": true,
        "reason": NSNull(),
        "ownerScope": "default",
        "chainId": 11_155_111,
        "networkProfile": "sepolia",
        "eoa": "0xa000000000000000000000000000000000000001",
        "keyRef": "bundler-eoa:default:11155111:1",
        "balance": "0x1",
        "thresholdLow": "0x0",
        "needsTopup": false,
        "lifecycle": "active",
        "rotation": ["rotating": false, "pendingFunding": [], "retiring": []],
        "keyHistory": [[
            "ownerScope": "default",
            "chainId": 11_155_111,
            "eoa": "0xa000000000000000000000000000000000000001",
            "keyRef": "bundler-eoa:default:11155111:1",
            "lifecycle": "active",
            "createdAt": 1,
        ]],
        "compromise": [
            "suspected": false,
            "reason": NSNull(),
            "submissionBlocked": false,
        ],
    ]
    json["replacement"] = [
        "eligible": true,
        "blocked": false,
        "blockedReason": NSNull(),
        "txHash": "0xdead",
        "userOpHash": "0xbeef",
        "nonce": 7,
    ]
    let status = try WalletNodeClient.RelayerStatus(json: json)
    #expect(status.replacement?.eligible == true)
    #expect(status.replacement?.blocked == false)
    #expect(status.replacement?.blockedReason == nil)
    #expect(status.replacement?.txHash == "0xdead")
    #expect(status.replacement?.userOpHash == "0xbeef")
    #expect(status.replacement?.nonce == 7)
}

@Test func decodesBlockedReplacementWithReason() throws {
    var json: [String: Any] = [
        "ready": true,
        "keyLoaded": true,
        "reason": NSNull(),
        "ownerScope": "default",
        "chainId": 11_155_111,
        "networkProfile": "sepolia",
        "eoa": "0xa000000000000000000000000000000000000001",
        "keyRef": "bundler-eoa:default:11155111:1",
        "balance": "0x1",
        "thresholdLow": "0x0",
        "needsTopup": false,
        "lifecycle": "active",
        "rotation": ["rotating": false, "pendingFunding": [], "retiring": []],
        "keyHistory": [[
            "ownerScope": "default",
            "chainId": 11_155_111,
            "eoa": "0xa000000000000000000000000000000000000001",
            "keyRef": "bundler-eoa:default:11155111:1",
            "lifecycle": "active",
            "createdAt": 1,
        ]],
        "compromise": [
            "suspected": false,
            "reason": NSNull(),
            "submissionBlocked": false,
        ],
    ]
    json["replacement"] = [
        "eligible": false,
        "blocked": true,
        "blockedReason": "gas_relay_stuck",
        "txHash": NSNull(),
        "userOpHash": NSNull(),
        "nonce": NSNull(),
    ]
    let status = try WalletNodeClient.RelayerStatus(json: json)
    #expect(status.replacement?.blocked == true)
    #expect(status.replacement?.blockedReason == "gas_relay_stuck")
}

@Test func absentReplacementBlockFailsClosed() {
    let json: [String: Any] = [
        "ready": true,
        "keyLoaded": true,
        "reason": NSNull(),
        "ownerScope": "default",
        "chainId": 11_155_111,
        "networkProfile": "sepolia",
        "eoa": "0xa000000000000000000000000000000000000001",
        "keyRef": "bundler-eoa:default:11155111:1",
        "balance": "0x1",
        "thresholdLow": "0x0",
        "needsTopup": false,
        "lifecycle": "active",
        "rotation": ["rotating": false, "pendingFunding": [], "retiring": []],
        "keyHistory": [[
            "ownerScope": "default",
            "chainId": 11_155_111,
            "eoa": "0xa000000000000000000000000000000000000001",
            "keyRef": "bundler-eoa:default:11155111:1",
            "lifecycle": "active",
            "createdAt": 1,
        ]],
        "compromise": [
            "suspected": false,
            "reason": NSNull(),
            "submissionBlocked": false,
        ],
    ]
    #expect(throws: (any Error).self) {
        _ = try WalletNodeClient.RelayerStatus(json: json)
    }
}

@Test func decodesManagedDaemonRelayerLockState() throws {
    let json: [String: Any] = [
        "ready": false,
        "keyLoaded": false,
        "reason": "bundler_eoa_locked",
        "ownerScope": "default",
        "chainId": 11_155_111,
        "networkProfile": "sepolia",
        "eoa": "0xa000000000000000000000000000000000000001",
        "keyRef": "bundler-eoa:default:11155111:1",
        "balance": "0x1",
        "thresholdLow": "0x0",
        "needsTopup": false,
        "lifecycle": "active",
        "rotation": ["rotating": false, "pendingFunding": [], "retiring": []],
        "keyHistory": [[
            "ownerScope": "default",
            "chainId": 11_155_111,
            "eoa": "0xa000000000000000000000000000000000000001",
            "keyRef": "bundler-eoa:default:11155111:1",
            "lifecycle": "active",
            "createdAt": 1,
        ]],
        "replacement": [
            "eligible": false,
            "blocked": false,
            "blockedReason": NSNull(),
            "txHash": NSNull(),
            "userOpHash": NSNull(),
            "nonce": NSNull(),
        ],
        "compromise": [
            "suspected": false,
            "reason": NSNull(),
            "submissionBlocked": false,
        ],
    ]
    let status = try WalletNodeClient.RelayerStatus(json: json)
    #expect(status.keyLoaded == false)
    #expect(status.ready == false)
    #expect(status.reason == "bundler_eoa_locked")
}

@Test func decodesFreshReadOnlyDaemonWithoutAnActiveRelayer() throws {
    let json: [String: Any] = [
        "ready": false,
        "reason": "bundler_eoa_missing",
        "keyLoaded": false,
        "ownerScope": "default",
        "chainId": 11_155_111,
        "networkProfile": "sepolia",
        "eoa": NSNull(),
        "keyRef": NSNull(),
        "balance": "unavailable",
        "thresholdLow": "0x11c37937e08000",
        "needsTopup": false,
        "lifecycle": NSNull(),
        "rotation": ["rotating": false, "pendingFunding": [], "retiring": []],
        "keyHistory": [],
        "replacement": [
            "eligible": false,
            "blocked": false,
            "blockedReason": NSNull(),
            "txHash": NSNull(),
            "userOpHash": NSNull(),
            "nonce": NSNull(),
        ],
        "compromise": [
            "suspected": false,
            "reason": NSNull(),
            "submissionBlocked": false,
        ],
    ]
    let status = try WalletNodeClient.RelayerStatus(json: json)
    #expect(status.eoa == "Not available")
    #expect(status.lifecycle == "missing")
    #expect(status.keyLoaded == false)
    #expect(status.reason == "bundler_eoa_missing")
}

@Test func cancelPendingOperationSendsRpcAndReturnsTxHash() async throws {
    let txHash = try await stubbedClient().cancelPendingOperation(userOpHash: "0xbeef")
    #expect(txHash == "0xcancelTx")
}

@Test func speedUpPendingOperationSendsRpcAndReturnsTxHash() async throws {
    let txHash = try await stubbedClient().speedUpPendingOperation(userOpHash: "0xbeef")
    #expect(txHash == "0xspeedTx")
}

@Test func getUserOperationStatusDecodesTerminalFailure() async throws {
    let decoded = try await stubbedClient().getUserOperationStatus(userOpHash: "0xbeef")
    let status = try #require(decoded)
    #expect(status.userOpHash == "0xbeef")
    #expect(status.status == "failed")
    #expect(status.lastError == "auto_dropped_aged_no_receipt")
    #expect(status.createdAt == 10)
    #expect(status.updatedAt == 20)
}
