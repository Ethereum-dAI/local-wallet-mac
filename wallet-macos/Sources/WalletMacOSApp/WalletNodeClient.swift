import Darwin
import Foundation

struct WalletNodeClient {
    struct Configuration {
        enum Transport {
            case http(URL)
            case unixSocket(String)
        }

        let transport: Transport
        let bearerToken: String

        static func fromEnvironment(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Configuration? {
            let endpointString = environment["LOCAL_WALLET_NODE_HTTP_URL"]
                ?? environment["WALLET_NODE_HTTP_URL"]
            let token = environment["LOCAL_WALLET_NODE_TOKEN"]
                ?? environment["WALLET_NODE_TOKEN"]

            guard let endpointString,
                  let endpoint = URL(string: endpointString),
                  let token,
                  !token.isEmpty
            else {
                return nil
            }

            return Configuration(transport: .http(endpoint), bearerToken: token)
        }
    }

    struct AdminChallenge {
        let adminActionId: String
        let nonce: String
        let summary: String
    }

    struct AdminAuthorization {
        let adminActionId: String
        let nonce: String

        var json: [String: Any] {
            [
                "adminActionId": adminActionId,
                "nonce": nonce,
            ]
        }
    }

    struct RelayerStatus {
        struct KeyHistoryEntry {
            let eoa: String
            let keyRef: String
            let lifecycle: String
            let createdAt: Int?
            let retiredAt: Int?
            let deletedAt: Int?
            let lastExportedAt: Int?

            var canExport: Bool {
                lifecycle == "active" || lifecycle == "retiring" || lifecycle == "retired"
            }

            var canDelete: Bool {
                lifecycle != "deleted"
            }

            var displayTitle: String {
                "\(lifecycle.uppercased()) \(eoa.walletNodeShortAddress)"
            }
        }

        let ready: Bool
        let ownerScope: String
        let chainId: Int
        let networkProfile: String
        let eoa: String
        let keyRef: String?
        let balance: String
        let thresholdLow: String
        let needsTopup: Bool
        let lifecycle: String
        let pendingFundingAddress: String?
        let pendingFundingCount: Int
        let retiringCount: Int
        let keyHistory: [KeyHistoryEntry]
        let latestAuditEvent: String?
    }

    struct UserOperationGasEstimate: Equatable {
        let callGasLimit: Data
        let verificationGasLimit: Data
        let preVerificationGas: Data
    }

    struct UserOperationGasPriceTier: Equatable {
        let maxFeePerGas: Data
        let maxPriorityFeePerGas: Data
    }

    struct UserOperationGasPrice: Equatable {
        let slow: UserOperationGasPriceTier
        let standard: UserOperationGasPriceTier
        let fast: UserOperationGasPriceTier
    }

    struct UserOperationReceipt: Equatable {
        let userOpHash: String
        let txHash: String
        let success: Bool
        let actualGasCost: String?
        let actualGasUsed: String?
        let revertReason: String?
        let tentative: Bool
        let invalidated: Bool
    }

    struct ResolvedName: Equatable {
        let input: String
        let normalizedName: String
        let address: String
        let resolver: String
        let resolutionChainId: Int
        let resolutionChainName: String
        let addressRecord: String
        let coinType: Int
        let ccipReadUsed: Bool
    }

    struct SwapQuoteResponse: Equatable {
        let chainID: UInt64
        let factory: String
        let router: String
        let quoter: String
        let tokenIn: String
        let tokenOut: String
        let amountIn: Data
        let quoteAmountOut: Data
        let amountOutMinimum: Data
        let slippageBps: UInt64
        let path: Data
        let hops: [SwapQuoteHop]
        let gasEstimate: String
        let allowance: Data?
        let requiresApproval: Bool
    }

    enum ClientError: LocalizedError {
        case invalidResponse
        case transport(String)
        case rpcError(code: Int, message: String, reason: String?)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "wallet-node returned an invalid response"
            case let .transport(message):
                return message
            case let .rpcError(code, message, reason):
                if let reason {
                    return "wallet-node RPC \(code): \(message) (\(reason))"
                }
                return "wallet-node RPC \(code): \(message)"
            }
        }
    }

    private let configuration: Configuration
    private let session: URLSession

    var usesUnixSocketTransport: Bool {
        if case .unixSocket = configuration.transport {
            return true
        }
        return false
    }

    static func isRecoverableUnixSocketFailure(_ error: Error) -> Bool {
        guard case let ClientError.transport(message) = error else {
            return false
        }

        return message.contains("failed to connect to wallet-node socket")
            || message.contains("wallet-node socket closed while writing")
            || message.contains("failed to write wallet-node request")
            || message.contains("failed to read wallet-node response")
    }

    init(configuration: Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func bundlerStatus() async throws -> RelayerStatus {
        let result = try await call(method: "wallet_bundlerStatus", params: [])
        guard let object = result as? [String: Any] else {
            throw ClientError.invalidResponse
        }
        return try RelayerStatus(json: object)
    }

    func supportedEntryPoints() async throws -> [String] {
        let result = try await call(method: "localwallet_supportedEntryPoints", params: [])
        guard let entryPoints = result as? [String] else {
            throw ClientError.invalidResponse
        }
        return entryPoints
    }

    func assertEntryPointSupport(_ entryPoint: String) async throws {
        let supported = try await supportedEntryPoints().map { $0.lowercased() }
        guard supported.contains(entryPoint.lowercased()) else {
            throw AppError.unsupportedBundlerEntryPoint
        }
    }

    func estimateUserOperationGas(
        draft: UserOperationDraft,
        dummySignature: Data
    ) async throws -> UserOperationGasEstimate {
        let userOperation = rpcUserOperation(
            draft: draft,
            signature: dummySignature,
            overrides: RPCOverrides(
                callGasLimit: "0x0",
                verificationGasLimit: "0x0",
                preVerificationGas: "0x0",
                maxFeePerGas: "0x0",
                maxPriorityFeePerGas: "0x0"
            )
        )
        let result = try await call(
            method: "localwallet_estimateUserOperationGas",
            params: [userOperation, draft.entryPoint]
        )
        guard let object = result as? [String: Any],
              let callGasLimit = object["callGasLimit"] as? String,
              let verificationGasLimit = object["verificationGasLimit"] as? String,
              let preVerificationGas = object["preVerificationGas"] as? String
        else {
            throw ClientError.invalidResponse
        }

        return UserOperationGasEstimate(
            callGasLimit: try parseQuantity(callGasLimit, field: "callGasLimit").leftPadded(to: 32),
            verificationGasLimit: try parseQuantity(verificationGasLimit, field: "verificationGasLimit").leftPadded(to: 32),
            preVerificationGas: try parseQuantity(preVerificationGas, field: "preVerificationGas").leftPadded(to: 32)
        )
    }

    func sendUserOperation(
        draft: UserOperationDraft,
        signature: Data
    ) async throws -> String {
        let result = try await call(
            method: "localwallet_sendUserOperation",
            params: [
                rpcUserOperation(draft: draft, signature: signature),
                draft.entryPoint,
            ]
        )
        guard let userOpHash = result as? String else {
            throw ClientError.invalidResponse
        }
        return userOpHash
    }

    func getUserOperationReceipt(userOpHash: String) async throws -> UserOperationReceipt? {
        let result = try await call(
            method: "localwallet_getUserOperationReceipt",
            params: [userOpHash],
            allowsNullResult: true
        )
        if result is NSNull {
            return nil
        }
        guard let object = result as? [String: Any] else {
            throw ClientError.invalidResponse
        }
        return try UserOperationReceipt(json: object)
    }

    func userOperationGasPrice() async throws -> UserOperationGasPrice {
        let result = try await call(method: "localwallet_getUserOperationGasPrice", params: [])
        guard let object = result as? [String: Any] else {
            throw ClientError.invalidResponse
        }
        return UserOperationGasPrice(
            slow: try parseGasPriceTier(object["slow"], field: "slow"),
            standard: try parseGasPriceTier(object["standard"], field: "standard"),
            fast: try parseGasPriceTier(object["fast"], field: "fast")
        )
    }

    func inspectAccount(address: String) async throws -> AccountInspection {
        async let code = ethCode(address: address)
        async let balance = ethBalance(address: address)

        let codeHex = try await code
        let balanceHex = try await balance
        let isDeployed = normalizedHex(codeHex) != "0x"

        return AccountInspection(
            address: address,
            isDeployed: isDeployed,
            balanceWeiHex: balanceHex,
            codeHex: codeHex
        )
    }

    func ethBalance(address: String, block: String = "latest") async throws -> String {
        let result = try await call(method: "eth_getBalance", params: [address, block])
        guard let value = result as? String else {
            throw ClientError.invalidResponse
        }
        return value
    }

    func ethCode(address: String, block: String = "latest") async throws -> String {
        let result = try await call(method: "eth_getCode", params: [address, block])
        guard let value = result as? String else {
            throw ClientError.invalidResponse
        }
        return value
    }

    func ethCall(to: String, data: String, block: String = "latest") async throws -> String {
        let result = try await call(
            method: "eth_call",
            params: [
                [
                    "to": to,
                    "data": data,
                ],
                block,
            ]
        )
        guard let value = result as? String else {
            throw ClientError.invalidResponse
        }
        return value
    }

    func erc20Balance(tokenAddress: String, ownerAddress: String) async throws -> String {
        let callData = try ChainReadCallData.erc20BalanceOf(ownerAddress: ownerAddress)
        return try await ethCall(to: tokenAddress, data: callData)
    }

    func entryPointNonce(
        entryPoint: String,
        accountAddress: String,
        nonceKey: UInt64 = 0
    ) async throws -> String {
        let callData = try ChainReadCallData.entryPointGetNonce(
            accountAddress: accountAddress,
            nonceKey: nonceKey
        )
        return try await ethCall(to: entryPoint, data: callData)
    }

    func resolveName(_ name: String, sendChainId: Int) async throws -> ResolvedName {
        let result = try await call(
            method: "localwallet_resolveName",
            params: [[
                "name": name,
                "sendChainId": sendChainId,
            ]]
        )
        guard let object = result as? [String: Any] else {
            throw ClientError.invalidResponse
        }
        return try ResolvedName(json: object)
    }

    func quoteSwap(
        sendChainId: UInt64,
        tokenIn: String,
        tokenOut: String,
        amountIn: Data,
        owner: String?,
        tokenInIsNative: Bool,
        slippageBps: UInt64,
        intermediates: [String]
    ) async throws -> SwapQuoteResponse {
        var request: [String: Any] = [
            "sendChainId": sendChainId,
            "tokenIn": tokenIn,
            "tokenOut": tokenOut,
            "amountIn": hexString(amountIn),
            "tokenInIsNative": tokenInIsNative,
            "slippageBps": slippageBps,
            "intermediates": intermediates,
        ]
        if let owner {
            request["owner"] = owner
        }

        let result = try await call(method: "localwallet_quoteSwap", params: [request])
        guard let object = result as? [String: Any] else {
            throw ClientError.invalidResponse
        }
        return try SwapQuoteResponse(json: object)
    }

    func beginAdminAction(action: String, chainId: Int, keyRef: String? = nil) async throws -> AdminChallenge {
        var request: [String: Any] = [
            "action": action,
            "ownerScope": "default",
            "chainId": chainId,
        ]
        if let keyRef {
            request["keyRef"] = keyRef
        }

        let result = try await call(method: "wallet_beginAdminAction", params: [request])
        guard let object = result as? [String: Any],
              let adminActionId = object["adminActionId"] as? String,
              let nonce = object["nonce"] as? String,
              let summary = object["summary"] as? String
        else {
            throw ClientError.invalidResponse
        }

        return AdminChallenge(
            adminActionId: adminActionId,
            nonce: nonce,
            summary: summary
        )
    }

    func rotateBundlerEOA(authorization: AdminAuthorization) async throws -> RelayerStatus {
        _ = try await call(
            method: "wallet_rotateBundlerEOA",
            params: [["authorization": authorization.json]]
        )
        return try await bundlerStatus()
    }

    func installBundlerEOA(
        keyRef: String,
        secret: Data,
        authorization: AdminAuthorization
    ) async throws -> RelayerStatus {
        _ = try await call(
            method: "wallet_installBundlerEOA",
            params: [[
                "keyRef": keyRef,
                "secret": "0x" + secret.lowercaseHexString,
                "authorization": authorization.json,
            ]]
        )
        return try await bundlerStatus()
    }

    func deleteBundlerEOA(
        keyRef: String,
        unsafeReset: Bool,
        acknowledgedPending: [String] = [],
        authorization: AdminAuthorization
    ) async throws {
        _ = try await call(
            method: "wallet_deleteBundlerEOA",
            params: [[
                "keyRef": keyRef,
                "unsafeReset": unsafeReset,
                "acknowledgedPending": acknowledgedPending,
                "authorization": authorization.json,
            ]]
        )
    }

    private func call(
        method: String,
        params: [Any],
        allowsNullResult: Bool = false
    ) async throws -> Any {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params,
        ])

        let data: Data
        switch configuration.transport {
        case let .http(endpoint):
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = body

            let (responseData, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode)
            else {
                throw ClientError.invalidResponse
            }
            data = responseData
        case let .unixSocket(socketPath):
            data = try await UnixSocketJSONRPCTransport.call(
                socketPath: socketPath,
                bearerToken: configuration.bearerToken,
                body: body
            )
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.invalidResponse
        }
        if let error = object["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? 0
            let message = error["message"] as? String ?? "RPC error"
            let reason = (error["data"] as? [String: Any])?["reason"] as? String
            throw ClientError.rpcError(code: code, message: message, reason: reason)
        }
        guard let result = object["result"] else {
            throw ClientError.invalidResponse
        }
        if result is NSNull, !allowsNullResult {
            throw ClientError.invalidResponse
        }
        return result
    }

    private struct RPCOverrides {
        let callGasLimit: String
        let verificationGasLimit: String
        let preVerificationGas: String
        let maxFeePerGas: String
        let maxPriorityFeePerGas: String
    }

    private func rpcUserOperation(
        draft: UserOperationDraft,
        signature: Data,
        overrides: RPCOverrides? = nil
    ) -> [String: Any] {
        let deploymentParts = splitInitCode(draft.initCode)
        var object: [String: Any] = [
            "sender": draft.sender,
            "nonce": hexString(draft.nonce),
            "callData": hexString(draft.callData),
            "callGasLimit": overrides?.callGasLimit ?? hexString(draft.gasPlan.callGasLimit),
            "verificationGasLimit": overrides?.verificationGasLimit ?? hexString(draft.gasPlan.verificationGasLimit),
            "preVerificationGas": overrides?.preVerificationGas ?? hexString(draft.gasPlan.preVerificationGas),
            "maxFeePerGas": overrides?.maxFeePerGas ?? hexString(draft.gasPlan.maxFeePerGas),
            "maxPriorityFeePerGas": overrides?.maxPriorityFeePerGas ?? hexString(draft.gasPlan.maxPriorityFeePerGas),
            "signature": hexString(signature),
        ]
        if let factory = deploymentParts.factory, let factoryData = deploymentParts.factoryData {
            object["factory"] = factory
            object["factoryData"] = factoryData
        }
        return object
    }

    private func splitInitCode(_ initCode: Data) -> (factory: String?, factoryData: String?) {
        guard !initCode.isEmpty else {
            return (nil, nil)
        }
        return (
            "0x" + Data(initCode.prefix(20)).hexEncodedString,
            "0x" + Data(initCode.dropFirst(20)).hexEncodedString
        )
    }

    private func hexString(_ data: Data) -> String {
        "0x" + data.hexEncodedString
    }

    private func parseQuantity(_ value: String, field: String) throws -> Data {
        do {
            return try Data.quantityString(value)
        } catch {
            throw ClientError.transport("wallet-node returned invalid \(field): \(value)")
        }
    }

    private func normalizedHex(_ value: String) -> String {
        let trimmed = value.lowercased()
        if trimmed == "0x0" || trimmed == "0x00" {
            return "0x"
        }
        return trimmed
    }

    private func parseGasPriceTier(_ value: Any?, field: String) throws -> UserOperationGasPriceTier {
        guard let object = value as? [String: Any],
              let maxFeePerGas = object["maxFeePerGas"] as? String,
              let maxPriorityFeePerGas = object["maxPriorityFeePerGas"] as? String
        else {
            throw ClientError.invalidResponse
        }
        return UserOperationGasPriceTier(
            maxFeePerGas: try parseQuantity(maxFeePerGas, field: "\(field).maxFeePerGas").leftPadded(to: 32),
            maxPriorityFeePerGas: try parseQuantity(maxPriorityFeePerGas, field: "\(field).maxPriorityFeePerGas").leftPadded(to: 32)
        )
    }
}

private enum UnixSocketJSONRPCTransport {
    static func call(socketPath: String, bearerToken: String, body: Data) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try callBlocking(socketPath: socketPath, bearerToken: bearerToken, body: body)
        }.value
    }

    private static func callBlocking(socketPath: String, bearerToken: String, body: Data) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw WalletNodeClient.ClientError.transport("failed to create wallet-node socket: errno \(errno)")
        }
        defer {
            close(fd)
        }

        try connect(fd: fd, socketPath: socketPath)

        var request = Data()
        request.append("POST / HTTP/1.1\r\n")
        request.append("Host: localhost\r\n")
        request.append("Content-Type: application/json\r\n")
        request.append("Authorization: Bearer \(bearerToken)\r\n")
        request.append("Content-Length: \(body.count)\r\n")
        request.append("Connection: close\r\n\r\n")
        request.append(body)
        try writeAll(fd: fd, data: request)

        let response = try readAll(fd: fd)
        return try parseHTTPBody(response)
    }

    private static func connect(fd: Int32, socketPath: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        let encoded = Array(socketPath.utf8)
        guard encoded.count < maxLength else {
            throw WalletNodeClient.ClientError.transport("wallet-node socket path is too long")
        }

        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            if let baseAddress = buffer.baseAddress {
                baseAddress.initializeMemory(as: UInt8.self, repeating: 0, count: buffer.count)
            }
            buffer.copyBytes(from: encoded)
        }

        let length = socklen_t(MemoryLayout<sa_family_t>.size + encoded.count + 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(fd, socketAddress, length)
            }
        }
        guard result == 0 else {
            throw WalletNodeClient.ClientError.transport("failed to connect to wallet-node socket: errno \(errno)")
        }
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(fd, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw WalletNodeClient.ClientError.transport("failed to write wallet-node request: errno \(errno)")
                }
                if written == 0 {
                    throw WalletNodeClient.ClientError.transport("wallet-node socket closed while writing")
                }
                offset += written
            }
        }
    }

    private static func readAll(fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw WalletNodeClient.ClientError.transport("failed to read wallet-node response: errno \(errno)")
            }
            if count == 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func parseHTTPBody(_ response: Data) throws -> Data {
        guard let separator = "\r\n\r\n".data(using: .utf8),
              let range = response.range(of: separator)
        else {
            throw WalletNodeClient.ClientError.invalidResponse
        }
        let head = response[..<range.lowerBound]
        guard let headText = String(data: head, encoding: .utf8),
              let statusLine = headText.components(separatedBy: "\r\n").first
        else {
            throw WalletNodeClient.ClientError.invalidResponse
        }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2,
              let status = Int(parts[1]),
              (200..<300).contains(status)
        else {
            throw WalletNodeClient.ClientError.invalidResponse
        }
        return response[range.upperBound...]
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(contentsOf: string.utf8)
    }
}

private extension String {
    var walletNodeShortAddress: String {
        guard count > 14 else {
            return self
        }
        return "\(prefix(8))...\(suffix(6))"
    }
}

private extension WalletNodeClient.RelayerStatus {
    init(json: [String: Any]) throws {
        guard let ready = json["ready"] as? Bool,
              let ownerScope = json["ownerScope"] as? String,
              let chainId = json["chainId"] as? Int,
              let networkProfile = json["networkProfile"] as? String,
              let eoa = json["eoa"] as? String,
              let balance = json["balance"] as? String,
              let thresholdLow = json["thresholdLow"] as? String,
              let needsTopup = json["needsTopup"] as? Bool,
              let lifecycle = json["lifecycle"] as? String
        else {
            throw WalletNodeClient.ClientError.invalidResponse
        }

        let rotation = json["rotation"] as? [String: Any]
        let pendingFunding = rotation?["pendingFunding"] as? [[String: Any]] ?? []
        let retiring = rotation?["retiring"] as? [String] ?? []
        let keyHistory = (json["keyHistory"] as? [[String: Any]] ?? []).compactMap {
            WalletNodeClient.RelayerStatus.KeyHistoryEntry(json: $0)
        }
        let auditEvents = json["auditEvents"] as? [[String: Any]] ?? []
        let latestAuditEvent = auditEvents.first?["event_type"] as? String

        self.init(
            ready: ready,
            ownerScope: ownerScope,
            chainId: chainId,
            networkProfile: networkProfile,
            eoa: eoa,
            keyRef: json["keyRef"] as? String,
            balance: balance,
            thresholdLow: thresholdLow,
            needsTopup: needsTopup,
            lifecycle: lifecycle,
            pendingFundingAddress: pendingFunding.first?["eoa"] as? String,
            pendingFundingCount: pendingFunding.count,
            retiringCount: retiring.count,
            keyHistory: keyHistory,
            latestAuditEvent: latestAuditEvent
        )
    }
}

private extension WalletNodeClient.RelayerStatus.KeyHistoryEntry {
    init?(json: [String: Any]) {
        guard let eoa = json["eoa"] as? String,
              let keyRef = json["keyRef"] as? String,
              let lifecycle = json["lifecycle"] as? String
        else {
            return nil
        }

        self.init(
            eoa: eoa,
            keyRef: keyRef,
            lifecycle: lifecycle,
            createdAt: json["createdAt"] as? Int,
            retiredAt: json["retiredAt"] as? Int,
            deletedAt: json["deletedAt"] as? Int,
            lastExportedAt: json["lastExportedAt"] as? Int
        )
    }
}

private extension WalletNodeClient.ResolvedName {
    init(json: [String: Any]) throws {
        guard let input = json["input"] as? String,
              let normalizedName = json["normalizedName"] as? String,
              let address = json["address"] as? String,
              let resolver = json["resolver"] as? String,
              let resolutionChainId = json["resolutionChainId"] as? Int,
              let resolutionChainName = json["resolutionChainName"] as? String,
              let addressRecord = json["addressRecord"] as? String,
              let coinType = json["coinType"] as? Int,
              let ccipReadUsed = json["ccipReadUsed"] as? Bool
        else {
            throw WalletNodeClient.ClientError.invalidResponse
        }

        self.init(
            input: input,
            normalizedName: normalizedName,
            address: address,
            resolver: resolver,
            resolutionChainId: resolutionChainId,
            resolutionChainName: resolutionChainName,
            addressRecord: addressRecord,
            coinType: coinType,
            ccipReadUsed: ccipReadUsed
        )
    }
}

private extension WalletNodeClient.SwapQuoteResponse {
    init(json: [String: Any]) throws {
        guard let chainID = json["chainId"] as? UInt64 ?? (json["chainId"] as? Int).map(UInt64.init),
              let factory = json["factory"] as? String,
              let router = json["router"] as? String,
              let quoter = json["quoter"] as? String,
              let tokenIn = json["tokenIn"] as? String,
              let tokenOut = json["tokenOut"] as? String,
              let amountIn = json["amountIn"] as? String,
              let quoteAmountOut = json["quoteAmountOut"] as? String,
              let amountOutMinimum = json["amountOutMinimum"] as? String,
              let slippageBps = json["slippageBps"] as? UInt64 ?? (json["slippageBps"] as? Int).map(UInt64.init),
              let path = json["path"] as? String,
              let gasEstimate = json["gasEstimate"] as? String,
              let requiresApproval = json["requiresApproval"] as? Bool
        else {
            throw WalletNodeClient.ClientError.invalidResponse
        }

        let hops = try (json["hops"] as? [[String: Any]] ?? []).map { try SwapQuoteHop(json: $0) }
        let allowance = try (json["allowance"] as? String).map {
            try Data.quantityString($0).leftPadded(to: 32)
        }

        self.init(
            chainID: chainID,
            factory: factory,
            router: router,
            quoter: quoter,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: try Data.quantityString(amountIn).leftPadded(to: 32),
            quoteAmountOut: try Data.quantityString(quoteAmountOut).leftPadded(to: 32),
            amountOutMinimum: try Data.quantityString(amountOutMinimum).leftPadded(to: 32),
            slippageBps: slippageBps,
            path: try Data(hexString: path),
            hops: hops,
            gasEstimate: gasEstimate,
            allowance: allowance,
            requiresApproval: requiresApproval
        )
    }
}

private extension SwapQuoteHop {
    init(json: [String: Any]) throws {
        guard let tokenIn = json["tokenIn"] as? String,
              let tokenOut = json["tokenOut"] as? String,
              let fee = json["fee"] as? Int,
              let pool = json["pool"] as? String,
              let liquidity = json["liquidity"] as? String
        else {
            throw WalletNodeClient.ClientError.invalidResponse
        }

        self.init(
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            pool: pool,
            liquidity: liquidity
        )
    }
}

private extension WalletNodeClient.UserOperationReceipt {
    init(json: [String: Any]) throws {
        guard let userOpHash = json["userOpHash"] as? String,
              let txHash = json["txHash"] as? String,
              let success = json["success"] as? Bool,
              let tentative = json["tentative"] as? Bool,
              let invalidated = json["invalidated"] as? Bool
        else {
            throw WalletNodeClient.ClientError.invalidResponse
        }

        self.init(
            userOpHash: userOpHash,
            txHash: txHash,
            success: success,
            actualGasCost: json["actualGasCost"] as? String,
            actualGasUsed: json["actualGasUsed"] as? String,
            revertReason: json["revertReason"] as? String,
            tentative: tentative,
            invalidated: invalidated
        )
    }
}
