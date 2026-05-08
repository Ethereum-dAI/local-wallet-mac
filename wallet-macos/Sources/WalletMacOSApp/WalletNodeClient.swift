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

    private func call(method: String, params: [Any]) async throws -> Any {
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
        return result
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
