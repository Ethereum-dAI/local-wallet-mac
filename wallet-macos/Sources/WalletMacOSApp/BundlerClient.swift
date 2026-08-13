import Foundation

// BundlerClient wraps the hosted ERC-4337 bundler RPC methods used by the demo
// app. It stays transport-focused and leaves signing / intent decisions to the
// higher-level AppModel and builder layers.
struct BundlerClient {
    enum BundlerError: LocalizedError {
        case invalidResponse
        case rpcError(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "The bundler response could not be decoded."
            case .rpcError(let message):
                return message
            }
        }
    }

    struct BundlerGasEstimate: Equatable {
        let callGasLimit: Data
        let verificationGasLimit: Data
        let preVerificationGas: Data
    }

    struct BundlerGasPriceTier: Equatable {
        let maxFeePerGas: Data
        let maxPriorityFeePerGas: Data
    }

    struct UserOperationReceipt: Decodable, Equatable {
        struct BundleReceipt: Decodable, Equatable {
            let transactionHash: String?
            let blockNumber: String?
            let blockHash: String?
            let status: String?
        }

        let userOpHash: String
        let entryPoint: String
        let sender: String
        let nonce: String
        let paymaster: String?
        let actualGasCost: String
        let actualGasUsed: String
        let success: Bool
        let reason: String?
        let receipt: BundleReceipt?
    }

    private enum JSONValue: Encodable {
        case string(String)
        case object([String: JSONValue])

        func encode(to encoder: Encoder) throws {
            switch self {
            case .string(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .object(let values):
                var container = encoder.container(keyedBy: DynamicCodingKey.self)
                for (key, value) in values {
                    try container.encode(value, forKey: DynamicCodingKey(stringValue: key))
                }
            }
        }
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            return nil
        }
    }

    private struct JSONRPCRequest: Encodable {
        let jsonrpc = "2.0"
        let id = 1
        let method: String
        let params: [JSONValue]
    }

    private struct JSONRPCResponse<Result: Decodable>: Decodable {
        struct RPCFailure: Decodable {
            let code: Int
            let message: String
        }

        let result: Result?
        let error: RPCFailure?
    }

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func supportedEntryPoints(chain: ChainConfiguration) async throws -> [String] {
        guard let bundlerURL = chain.bundlerURL else {
            throw AppError.bundlerNotConfigured
        }

        var request = URLRequest(url: bundlerURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            JSONRPCRequest(method: "eth_supportedEntryPoints", params: [])
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw BundlerError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(JSONRPCResponse<[String]>.self, from: data)
        if let error = decoded.error {
            throw BundlerError.rpcError("Bundler RPC \(error.code): \(error.message)")
        }

        guard let result = decoded.result else {
            throw BundlerError.invalidResponse
        }

        return result
    }

    func assertEntryPointSupport(chain: ChainConfiguration) async throws {
        let supported = try await supportedEntryPoints(chain: chain)
            .map { $0.lowercased() }

        guard supported.contains(chain.entryPoint.lowercased()) else {
            throw AppError.unsupportedBundlerEntryPoint
        }
    }

    func estimateUserOperationGas(
        chain: ChainConfiguration,
        draft: UserOperationDraft,
        dummySignature: Data
    ) async throws -> BundlerGasEstimate {
        guard let bundlerURL = chain.bundlerURL else {
            throw AppError.bundlerNotConfigured
        }

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

        var request = URLRequest(url: bundlerURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            JSONRPCRequest(
                method: "eth_estimateUserOperationGas",
                params: [
                    .object(userOperation.jsonValue),
                    .string(chain.entryPoint),
                ]
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw BundlerError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(JSONRPCResponse<EstimateResponse>.self, from: data)
        if let error = decoded.error {
            throw BundlerError.rpcError("Bundler RPC \(error.code): \(error.message)")
        }

        guard let result = decoded.result else {
            throw BundlerError.invalidResponse
        }

        return BundlerGasEstimate(
            callGasLimit: try parseQuantity(result.callGasLimit, field: "callGasLimit").leftPadded(to: 32),
            verificationGasLimit: try parseQuantity(result.verificationGasLimit, field: "verificationGasLimit").leftPadded(to: 32),
            preVerificationGas: try parseQuantity(result.preVerificationGas, field: "preVerificationGas").leftPadded(to: 32)
        )
    }

    func sendUserOperation(
        chain: ChainConfiguration,
        operation: SignedUserOperation
    ) async throws -> String {
        guard let bundlerURL = chain.bundlerURL else {
            throw AppError.bundlerNotConfigured
        }

        let userOperation = rpcUserOperation(
            draft: operation.draft,
            signature: operation.signature
        )

        var request = URLRequest(url: bundlerURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            JSONRPCRequest(
                method: "eth_sendUserOperation",
                params: [
                    .object(userOperation.jsonValue),
                    .string(chain.entryPoint),
                ]
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw BundlerError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(JSONRPCResponse<String>.self, from: data)
        if let error = decoded.error {
            throw BundlerError.rpcError("Bundler RPC \(error.code): \(error.message)")
        }

        guard let result = decoded.result else {
            throw BundlerError.invalidResponse
        }
        return try operation.validatingReturnedHash(result)
    }

    func getUserOperationReceipt(
        chain: ChainConfiguration,
        userOpHash: String
    ) async throws -> UserOperationReceipt? {
        guard let bundlerURL = chain.bundlerURL else {
            throw AppError.bundlerNotConfigured
        }

        var request = URLRequest(url: bundlerURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            JSONRPCRequest(
                method: "eth_getUserOperationReceipt",
                params: [.string(userOpHash)]
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw BundlerError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(JSONRPCResponse<UserOperationReceipt?>.self, from: data)
        if let error = decoded.error {
            throw BundlerError.rpcError("Bundler RPC \(error.code): \(error.message)")
        }

        return decoded.result ?? nil
    }

    func userOperationGasPrice(
        chain: ChainConfiguration
    ) async throws -> (slow: BundlerGasPriceTier, standard: BundlerGasPriceTier, fast: BundlerGasPriceTier) {
        guard let bundlerURL = chain.bundlerURL else {
            throw AppError.bundlerNotConfigured
        }

        var request = URLRequest(url: bundlerURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            JSONRPCRequest(
                method: "pimlico_getUserOperationGasPrice",
                params: []
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw BundlerError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(JSONRPCResponse<GasPriceResponse>.self, from: data)
        if let error = decoded.error {
            throw BundlerError.rpcError("Bundler RPC \(error.code): \(error.message)")
        }

        guard let result = decoded.result else {
            throw BundlerError.invalidResponse
        }

        return (
            slow: try parseGasPriceTier(result.slow),
            standard: try parseGasPriceTier(result.standard),
            fast: try parseGasPriceTier(result.fast)
        )
    }

    private struct EstimateResponse: Decodable {
        let preVerificationGas: String
        let verificationGasLimit: String
        let callGasLimit: String
    }

    private struct GasPriceResponse: Decodable {
        let slow: GasPriceTierResponse
        let standard: GasPriceTierResponse
        let fast: GasPriceTierResponse
    }

    private struct GasPriceTierResponse: Decodable {
        let maxFeePerGas: String
        let maxPriorityFeePerGas: String
    }

    private struct RPCOverrides {
        let callGasLimit: String
        let verificationGasLimit: String
        let preVerificationGas: String
        let maxFeePerGas: String
        let maxPriorityFeePerGas: String
    }

    private struct RPCUserOperation {
        let sender: String
        let nonce: String
        let factory: String?
        let factoryData: String?
        let callData: String
        let callGasLimit: String
        let verificationGasLimit: String
        let preVerificationGas: String
        let maxFeePerGas: String
        let maxPriorityFeePerGas: String
        let signature: String

        var jsonValue: [String: JSONValue] {
            var object: [String: JSONValue] = [
                "sender": .string(sender),
                "nonce": .string(nonce),
                "callData": .string(callData),
                "callGasLimit": .string(callGasLimit),
                "verificationGasLimit": .string(verificationGasLimit),
                "preVerificationGas": .string(preVerificationGas),
                "maxFeePerGas": .string(maxFeePerGas),
                "maxPriorityFeePerGas": .string(maxPriorityFeePerGas),
                "signature": .string(signature),
            ]

            if let factory, let factoryData {
                object["factory"] = .string(factory)
                object["factoryData"] = .string(factoryData)
            }

            return object
        }
    }

    private func rpcUserOperation(
        draft: UserOperationDraft,
        signature: Data,
        overrides: RPCOverrides? = nil
    ) -> RPCUserOperation {
        let deploymentParts = splitInitCode(draft.initCode)

        return RPCUserOperation(
            sender: draft.sender,
            nonce: hexString(draft.nonce),
            factory: deploymentParts.factory,
            factoryData: deploymentParts.factoryData,
            callData: hexString(draft.callData),
            callGasLimit: overrides?.callGasLimit ?? hexString(draft.gasPlan.callGasLimit),
            verificationGasLimit: overrides?.verificationGasLimit ?? hexString(draft.gasPlan.verificationGasLimit),
            preVerificationGas: overrides?.preVerificationGas ?? hexString(draft.gasPlan.preVerificationGas),
            maxFeePerGas: overrides?.maxFeePerGas ?? hexString(draft.gasPlan.maxFeePerGas),
            maxPriorityFeePerGas: overrides?.maxPriorityFeePerGas ?? hexString(draft.gasPlan.maxPriorityFeePerGas),
            signature: hexString(signature)
        )
    }

    private func splitInitCode(_ initCode: Data) -> (factory: String?, factoryData: String?) {
        guard !initCode.isEmpty else {
            return (nil, nil)
        }

        let factory = Data(initCode.prefix(20))
        let factoryData = Data(initCode.dropFirst(20))
        return (
            "0x" + factory.hexEncodedString,
            "0x" + factoryData.hexEncodedString
        )
    }

    private func hexString(_ data: Data) -> String {
        "0x" + data.hexEncodedString
    }

    private func parseQuantity(_ value: String, field: String) throws -> Data {
        do {
            let decoded = try Data.quantityString(value)
            guard decoded.count <= 32 else {
                throw BundlerError.rpcError(
                    "Bundler returned oversized \(field): \(decoded.count) bytes"
                )
            }
            return decoded
        } catch {
            if let error = error as? BundlerError {
                throw error
            }
            throw BundlerError.rpcError("Bundler returned invalid \(field): \(value)")
        }
    }

    private func parseGasPriceTier(_ value: GasPriceTierResponse) throws -> BundlerGasPriceTier {
        BundlerGasPriceTier(
            maxFeePerGas: try parseQuantity(value.maxFeePerGas, field: "maxFeePerGas").leftPadded(to: 32),
            maxPriorityFeePerGas: try parseQuantity(value.maxPriorityFeePerGas, field: "maxPriorityFeePerGas").leftPadded(to: 32)
        )
    }
}
