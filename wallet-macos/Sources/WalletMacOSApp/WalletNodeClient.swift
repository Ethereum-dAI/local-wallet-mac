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

        struct ReplacementStatus: Equatable {
            let eligible: Bool
            let blocked: Bool
            let blockedReason: String?
            let txHash: String?
            let userOpHash: String?
            let nonce: Int?
        }

        let ready: Bool
        /// Whether the active relayer secret is present in wallet-node's in-memory key store.
        /// Durable metadata and a funded address are not enough to submit after a daemon restart.
        let keyLoaded: Bool
        let reason: String?
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
        let replacement: ReplacementStatus?

        var availableEOA: String? {
            guard eoa.hasPrefix("0x"), eoa.count == 42 else { return nil }
            return eoa
        }
    }

    struct NetworkStatus: Equatable {
        struct BlockHead: Equatable {
            let number: UInt64
            let hash: String
        }

        struct Helios: Equatable {
            let ready: Bool
            let checkpointLoaded: Bool
            let checkpointAgeDays: Double?
            let head: BlockHead?
        }

        struct ReadVerification: Equatable {
            let mode: String
            let verified: Bool
        }

        struct Bundler: Equatable {
            let ready: Bool
            let needsTopup: Bool?
            let reason: String?
            let eoa: String?
        }

        struct P256Precompile: Equatable {
            let status: String
            /// Effective decision the app must encode into on-chain WebAuthn
            /// signatures: `true` routes verification through the RIP-7212 precompile.
            let usePrecompiled: Bool
            let reason: String?
        }

        let status: String
        let reason: String?
        let chainId: UInt64
        let networkProfile: String
        let readVerification: ReadVerification
        let helios: Helios
        let bundler: Bundler?
        let p256Precompile: P256Precompile?
    }

    /// The two numbers EntryPoint v0.7 measures a UserOperation's prefund
    /// against: the account's own balance and its EntryPoint deposit. Read
    /// together from one `wallet_walletStatus` call so they come from the same
    /// verified head.
    struct WalletStatus: Equatable {
        let accountBalance: Data
        let entryPointDeposit: Data

        init(json: [String: Any]) throws {
            guard let balance = json["accountBalance"] as? String,
                  let deposit = json["entryPointDeposit"] as? String,
                  let balanceData = try? Data.quantityString(balance).leftPadded(to: 32),
                  let depositData = try? Data.quantityString(deposit).leftPadded(to: 32)
            else {
                throw ClientError.invalidResponse
            }
            self.accountBalance = balanceData
            self.entryPointDeposit = depositData
        }
    }

    struct UserOperationGasEstimate: Equatable {
        let callGasLimit: Data
        let verificationGasLimit: Data
        let preVerificationGas: Data
        /// EntryPoint v0.7's balance floor for this op, as the daemon computed it
        /// from the limits it resolved times the `maxFeePerGas` we submitted
        /// (`wallet-bundler/src/user_operation.rs:178`). Zero when the daemon
        /// omitted the field, or when we submitted zero fees.
        let requiredPrefund: Data
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

    struct UserOperationStatus: Equatable {
        let userOpHash: String
        let status: String
        let lastError: String?
        let createdAt: Int
        let updatedAt: Int
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
        case rpcError(
            method: String,
            code: Int,
            message: String,
            reason: String?,
            detail: String? = nil,
            suggestedCallGasLimit: UInt64? = nil
        )

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "wallet-node returned an invalid response"
            case let .transport(message):
                return message
            case let .rpcError(method, code, message, reason, detail, _):
                var context: [String] = []
                if let reason {
                    context.append(reason)
                }
                if let detail {
                    context.append("detail: \(detail)")
                }
                guard context.isEmpty == false else {
                    return "wallet-node RPC \(method) \(code): \(message)"
                }
                return "wallet-node RPC \(method) \(code): \(message) (\(context.joined(separator: "; ")))"
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

    func hasSameConnection(as other: WalletNodeClient) -> Bool {
        guard configuration.bearerToken == other.configuration.bearerToken else { return false }
        switch (configuration.transport, other.configuration.transport) {
        case let (.http(lhs), .http(rhs)):
            return lhs == rhs
        case let (.unixSocket(lhs), .unixSocket(rhs)):
            return lhs == rhs
        default:
            return false
        }
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

    func networkStatus() async throws -> NetworkStatus {
        let result = try await call(method: "wallet_networkStatus", params: [])
        guard let object = result as? [String: Any] else {
            throw ClientError.invalidResponse
        }
        return try NetworkStatus(json: object)
    }

    func walletStatus(smartAccount: String) async throws -> WalletStatus {
        let result = try await call(method: "wallet_walletStatus", params: [smartAccount])
        guard let object = result as? [String: Any] else {
            throw ClientError.invalidResponse
        }
        return try WalletStatus(json: object)
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

    static func decodeGasEstimate(_ object: [String: Any]) throws -> UserOperationGasEstimate {
        func quantity(_ value: String, _ field: String) throws -> Data {
            do {
                return try Data.quantityString(value).leftPadded(to: 32)
            } catch {
                throw ClientError.transport("wallet-node returned invalid \(field): \(value)")
            }
        }

        guard let callGasLimit = object["callGasLimit"] as? String,
              let verificationGasLimit = object["verificationGasLimit"] as? String,
              let preVerificationGas = object["preVerificationGas"] as? String
        else {
            throw ClientError.invalidResponse
        }

        var requiredPrefund = Data(repeating: 0, count: 32)
        if let raw = object["requiredPrefund"] as? String {
            requiredPrefund = try quantity(raw, "requiredPrefund")
        }

        return UserOperationGasEstimate(
            callGasLimit: try quantity(callGasLimit, "callGasLimit"),
            verificationGasLimit: try quantity(verificationGasLimit, "verificationGasLimit"),
            preVerificationGas: try quantity(preVerificationGas, "preVerificationGas"),
            requiredPrefund: requiredPrefund
        )
    }

    static func estimateGasParams(
        userOperation: Any,
        entryPoint: String,
        acknowledgedCallGasLimit: UInt64?
    ) -> [Any] {
        var params: [Any] = [userOperation, entryPoint]
        if let acknowledgedCallGasLimit {
            // Only sent when the user has explicitly consented to submitting
            // without a real estimate. The daemon validates this value
            // unconditionally (it can reject with a policy-cap error before any
            // estimation runs) and only *honours* it as the call-gas limit when
            // estimation turns out to be unavailable -- a successful estimate
            // or a detected revert always take precedence over it.
            params.append([
                "acknowledgedCallGasLimit": "0x" + String(acknowledgedCallGasLimit, radix: 16)
            ])
        }
        return params
    }

    func estimateUserOperationGas(
        draft: UserOperationDraft,
        dummySignature: Data,
        acknowledgedCallGasLimit: UInt64? = nil
    ) async throws -> UserOperationGasEstimate {
        let userOperation = rpcUserOperation(
            draft: draft,
            signature: dummySignature,
            overrides: RPCOverrides(
                // The daemon resolves these itself; a client-invented limit
                // would be measured by the estimate-time funding check, which
                // runs before that resolution.
                callGasLimit: "0x0",
                verificationGasLimit: "0x0",
                preVerificationGas: "0x0",
                // Real fees, so the response's requiredPrefund is a real number
                // rather than (limits × 0). AppModel quotes fees before calling.
                maxFeePerGas: "0x" + draft.gasPlan.maxFeePerGas.hexEncodedString,
                maxPriorityFeePerGas: "0x" + draft.gasPlan.maxPriorityFeePerGas.hexEncodedString
            )
        )
        let result = try await call(
            method: "localwallet_estimateUserOperationGas",
            params: Self.estimateGasParams(
                userOperation: userOperation,
                entryPoint: draft.entryPoint,
                acknowledgedCallGasLimit: acknowledgedCallGasLimit
            )
        )
        guard let object = result as? [String: Any] else {
            throw ClientError.invalidResponse
        }
        return try Self.decodeGasEstimate(object)
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

    func getUserOperationStatus(userOpHash: String) async throws -> UserOperationStatus? {
        let result = try await call(
            method: "localwallet_getUserOperationStatus",
            params: [userOpHash],
            allowsNullResult: true
        )
        if result is NSNull {
            return nil
        }
        guard let object = result as? [String: Any] else {
            throw ClientError.invalidResponse
        }
        return try UserOperationStatus(json: object)
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

    func kernelCurrentNonce(accountAddress: String) async throws -> UInt32 {
        let account = try Data(hexString: accountAddress)
        guard account.count == 20 else {
            throw AppError.invalidExecutionAddress
        }
        let result = try await ethCall(to: accountAddress, data: ChainReadCallData.kernelCurrentNonce())
        let data = try Data(hexString: result)
        guard data.count <= 32 else {
            throw AppError.invalidHexString
        }
        return data.leftPadded(to: 32).suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
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

    func entryPointNonce(
        entryPoint: String,
        accountAddress: String,
        nonceKey192: Data
    ) async throws -> String {
        let callData = try ChainReadCallData.entryPointGetNonce(
            accountAddress: accountAddress,
            nonceKey192: nonceKey192
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

    func cancelPendingOperation(userOpHash: String) async throws -> String? {
        let result = try await call(
            method: "wallet_cancelPendingOperation",
            params: [userOpHash],
            allowsNullResult: true
        )
        return try replacementTxHash(from: result)
    }

    func speedUpPendingOperation(userOpHash: String) async throws -> String? {
        let result = try await call(
            method: "wallet_speedUpPendingOperation",
            params: [userOpHash],
            allowsNullResult: true
        )
        return try replacementTxHash(from: result)
    }

    private func replacementTxHash(from result: Any) throws -> String? {
        if result is NSNull {
            return nil
        }
        if let txHash = result as? String {
            return txHash
        }
        if let object = result as? [String: Any],
           let txHash = object["txHash"] as? String {
            return txHash
        }
        throw ClientError.invalidResponse
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
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ClientError.invalidResponse
            }
            if !(200..<300).contains(httpResponse.statusCode), responseData.isEmpty {
                throw ClientError.transport("wallet-node returned HTTP \(httpResponse.statusCode) without a response body")
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
        if object["error"] is [String: Any] {
            throw Self.decodeRPCError(from: data, method: method) ?? ClientError.invalidResponse
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

    static func decodeRPCError(from data: Data, method: String) -> ClientError? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any]
        else {
            return nil
        }
        let errorData = error["data"] as? [String: Any]
        return .rpcError(
            method: method,
            code: error["code"] as? Int ?? 0,
            message: error["message"] as? String ?? "RPC error",
            reason: errorDataString(errorData?["reason"]),
            detail: errorDataString(errorData?["detail"]),
            suggestedCallGasLimit: hexQuantity(errorData?["suggestedCallGasLimit"])
        )
    }

    private static func hexQuantity(_ value: Any?) -> UInt64? {
        guard let text = value as? String, text.hasPrefix("0x") else {
            return nil
        }
        return UInt64(text.dropFirst(2), radix: 16)
    }

    private static func errorDataString(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else {
            return nil
        }
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8)
        else {
            return String(describing: value)
        }
        return string
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
        guard !response.isEmpty else {
            throw WalletNodeClient.ClientError.transport("wallet-node closed the connection without a response")
        }
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
              let status = Int(parts[1])
        else {
            throw WalletNodeClient.ClientError.invalidResponse
        }
        let body = response[range.upperBound...]
        if !(200..<300).contains(status), body.isEmpty {
            throw WalletNodeClient.ClientError.transport("wallet-node returned HTTP \(status) without a response body")
        }
        return body
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

extension WalletNodeClient.RelayerStatus {
    init(json: [String: Any]) throws {
        guard let ready = json["ready"] as? Bool,
              let ownerScope = json["ownerScope"] as? String,
              let chainId = json["chainId"] as? Int,
              let networkProfile = json["networkProfile"] as? String,
              let balance = json["balance"] as? String,
              let thresholdLow = json["thresholdLow"] as? String,
              let needsTopup = json["needsTopup"] as? Bool
        else {
            throw WalletNodeClient.ClientError.invalidResponse
        }

        // A fresh read-only daemon intentionally has no active relayer row. The managed daemon
        // returns nulls for those two fields; decoding that ordinary locked state must not turn
        // a passive status read into an error.
        let eoa = json["eoa"] as? String ?? "Not available"
        let lifecycle = json["lifecycle"] as? String ?? "missing"

        let rotation = json["rotation"] as? [String: Any]
        let pendingFunding = rotation?["pendingFunding"] as? [[String: Any]] ?? []
        let retiring = rotation?["retiring"] as? [String] ?? []
        let keyHistory = (json["keyHistory"] as? [[String: Any]] ?? []).compactMap {
            WalletNodeClient.RelayerStatus.KeyHistoryEntry(json: $0)
        }
        let auditEvents = json["auditEvents"] as? [[String: Any]] ?? []
        let latestAuditEvent = auditEvents.first?["event_type"] as? String
        let replacement = (json["replacement"] as? [String: Any]).flatMap {
            WalletNodeClient.RelayerStatus.ReplacementStatus(json: $0)
        }

        self.init(
            ready: ready,
            // Older externally managed daemons do not expose this field. Preserve compatibility
            // there; the managed daemon always sends the authoritative value.
            keyLoaded: json["keyLoaded"] as? Bool ?? true,
            reason: json["reason"] as? String,
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
            latestAuditEvent: latestAuditEvent,
            replacement: replacement
        )
    }
}

extension WalletNodeClient.NetworkStatus {
    init(json: [String: Any]) throws {
        guard let status = json["status"] as? String,
              let chainId = Self.uint64(from: json["chainId"]),
              let networkProfile = json["networkProfile"] as? String,
              let heliosJSON = json["helios"] as? [String: Any]
        else {
            throw WalletNodeClient.ClientError.invalidResponse
        }

        self.init(
            status: status,
            reason: Self.optionalString(json["reason"]),
            chainId: chainId,
            networkProfile: networkProfile,
            readVerification: (json["readVerification"] as? [String: Any]).flatMap {
                ReadVerification(json: $0)
            } ?? ReadVerification(mode: "helios", verified: true),
            helios: try Helios(json: heliosJSON),
            bundler: (json["bundler"] as? [String: Any]).flatMap { Bundler(json: $0) },
            p256Precompile: (json["p256Precompile"] as? [String: Any]).flatMap {
                P256Precompile(json: $0)
            }
        )
    }

    private static func optionalString(_ value: Any?) -> String? {
        if value == nil || value is NSNull {
            return nil
        }
        return value as? String
    }

    private static func uint64(from value: Any?) -> UInt64? {
        if let value = value as? UInt64 {
            return value
        }
        if let value = value as? Int, value >= 0 {
            return UInt64(value)
        }
        if let value = value as? NSNumber {
            return value.uint64Value
        }
        if let value = value as? String {
            return UInt64(value)
        }
        return nil
    }
}

extension WalletNodeClient.NetworkStatus.ReadVerification {
    init?(json: [String: Any]) {
        guard let mode = json["mode"] as? String,
              let verified = json["verified"] as? Bool
        else {
            return nil
        }
        self.init(mode: mode, verified: verified)
    }
}

extension WalletNodeClient.NetworkStatus.Helios {
    init(json: [String: Any]) throws {
        guard let ready = json["ready"] as? Bool,
              let checkpointLoaded = json["checkpointLoaded"] as? Bool
        else {
            throw WalletNodeClient.ClientError.invalidResponse
        }

        self.init(
            ready: ready,
            checkpointLoaded: checkpointLoaded,
            checkpointAgeDays: json["checkpointAgeDays"] as? Double,
            head: (json["head"] as? [String: Any]).flatMap {
                WalletNodeClient.NetworkStatus.BlockHead(json: $0)
            }
        )
    }
}

extension WalletNodeClient.NetworkStatus.BlockHead {
    init?(json: [String: Any]) {
        guard let number = Self.uint64(from: json["number"]),
              let hash = json["hash"] as? String
        else {
            return nil
        }
        self.init(number: number, hash: hash)
    }

    private static func uint64(from value: Any?) -> UInt64? {
        if let value = value as? UInt64 {
            return value
        }
        if let value = value as? Int, value >= 0 {
            return UInt64(value)
        }
        if let value = value as? NSNumber {
            return value.uint64Value
        }
        if let value = value as? String {
            return UInt64(value)
        }
        return nil
    }
}

extension WalletNodeClient.NetworkStatus.P256Precompile {
    init?(json: [String: Any]) {
        guard let status = json["status"] as? String,
              let usePrecompiled = json["usePrecompiled"] as? Bool
        else {
            return nil
        }
        self.init(
            status: status,
            usePrecompiled: usePrecompiled,
            reason: json["reason"] as? String
        )
    }
}

extension WalletNodeClient.NetworkStatus.Bundler {
    init?(json: [String: Any]) {
        guard let ready = json["ready"] as? Bool else {
            return nil
        }
        self.init(
            ready: ready,
            needsTopup: json["needsTopup"] as? Bool,
            reason: Self.optionalString(json["reason"]),
            eoa: Self.optionalString(json["eoa"])
        )
    }

    private static func optionalString(_ value: Any?) -> String? {
        if value == nil || value is NSNull {
            return nil
        }
        return value as? String
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

extension WalletNodeClient.RelayerStatus.ReplacementStatus {
    init?(json: [String: Any]) {
        guard let eligible = json["eligible"] as? Bool,
              let blocked = json["blocked"] as? Bool
        else {
            return nil
        }
        self.init(
            eligible: eligible,
            blocked: blocked,
            blockedReason: json["blockedReason"] as? String,
            txHash: json["txHash"] as? String,
            userOpHash: json["userOpHash"] as? String,
            nonce: json["nonce"] as? Int
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

private extension WalletNodeClient.UserOperationStatus {
    init(json: [String: Any]) throws {
        guard let userOpHash = json["userOpHash"] as? String,
              let status = json["status"] as? String,
              let createdAt = json["createdAt"] as? Int,
              let updatedAt = json["updatedAt"] as? Int
        else {
            throw WalletNodeClient.ClientError.invalidResponse
        }

        self.init(
            userOpHash: userOpHash,
            status: status,
            lastError: json["lastError"] as? String,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
