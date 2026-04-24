import Foundation

// DemoRPCClient handles read-only public RPC calls used by the demo shell for
// account inspection, nonce reads, and fee fallback data.
struct DemoRPCClient {
    enum RPCError: LocalizedError {
        case invalidResponse
        case rpcError(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "The RPC response could not be decoded."
            case .rpcError(let message):
                return message
            }
        }
    }

    private enum JSONValue: Encodable {
        case string(String)
        case bool(Bool)
        case object([String: JSONValue])

        func encode(to encoder: Encoder) throws {
            switch self {
            case .string(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .bool(let value):
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

    private struct BlockHeaderResponse: Decodable {
        let baseFeePerGas: String?
    }

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func inspectAccount(
        chain: ChainConfiguration,
        address: String
    ) async throws -> AccountInspection {
        async let code = call(
            method: "eth_getCode",
            params: [.string(address), .string("latest")],
            rpcURL: chain.rpcURL
        )
        async let balance = call(
            method: "eth_getBalance",
            params: [.string(address), .string("latest")],
            rpcURL: chain.rpcURL
        )

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

    func entryPointNonce(
        chain: ChainConfiguration,
        accountAddress: String,
        nonceKey: UInt64 = 0
    ) async throws -> String {
        let callData = DemoRPCClient.entryPointGetNonceCallData(
            accountAddress: accountAddress,
            nonceKey: nonceKey
        )

        return try await ethCall(
            to: chain.entryPoint,
            data: callData,
            rpcURL: chain.rpcURL
        )
    }

    func suggestedGasFees(chain: ChainConfiguration) async throws -> (maxPriorityFeePerGas: Data, maxFeePerGas: Data) {
        async let priorityFee = call(
            method: "eth_maxPriorityFeePerGas",
            params: [],
            rpcURL: chain.rpcURL
        )
        async let latestBlock = callBlockHeader(
            method: "eth_getBlockByNumber",
            params: [.string("latest"), .bool(false)],
            rpcURL: chain.rpcURL
        )

        let priorityHex = try await priorityFee
        let block = try await latestBlock

        let priority = try parseQuantity(priorityHex, field: "eth_maxPriorityFeePerGas").leftPadded(to: 32)
        let base = try parseQuantity(block.baseFeePerGas ?? "0x0", field: "baseFeePerGas").leftPadded(to: 32)

        let maxPriority = u256Data(from: priority)
        let baseFee = u256Data(from: base)
        let doubledBase = addingU256(baseFee, baseFee)
        let maxFee = addingU256(doubledBase, maxPriority)

        return (
            Data(maxPriority).leftPadded(to: 32),
            Data(maxFee).leftPadded(to: 32)
        )
    }

    private func call(
        method: String,
        params: [JSONValue],
        rpcURL: URL
    ) async throws -> String {
        var request = URLRequest(url: rpcURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(JSONRPCRequest(method: method, params: params))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw RPCError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(JSONRPCResponse<String>.self, from: data)
        if let error = decoded.error {
            throw RPCError.rpcError("RPC \(error.code): \(error.message)")
        }

        guard let result = decoded.result else {
            throw RPCError.invalidResponse
        }

        return result
    }

    private func callBlockHeader(
        method: String,
        params: [JSONValue],
        rpcURL: URL
    ) async throws -> BlockHeaderResponse {
        var request = URLRequest(url: rpcURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(JSONRPCRequest(method: method, params: params))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw RPCError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(JSONRPCResponse<BlockHeaderResponse>.self, from: data)
        if let error = decoded.error {
            throw RPCError.rpcError("RPC \(error.code): \(error.message)")
        }

        guard let result = decoded.result else {
            throw RPCError.invalidResponse
        }

        return result
    }

    private func ethCall(
        to: String,
        data: String,
        rpcURL: URL
    ) async throws -> String {
        try await call(
            method: "eth_call",
            params: [
                .object([
                    "to": .string(to),
                    "data": .string(data),
                ]),
                .string("latest"),
            ],
            rpcURL: rpcURL
        )
    }

    private func normalizedHex(_ value: String) -> String {
        let trimmed = value.lowercased()
        if trimmed == "0x0" || trimmed == "0x00" {
            return "0x"
        }
        return trimmed
    }

    private static func entryPointGetNonceCallData(
        accountAddress: String,
        nonceKey: UInt64
    ) -> String {
        let selector = "35567e1a"
        let account = (try? Data(hexString: accountAddress)) ?? Data()
        let nonceKeyData = Data.fromBigEndian(nonceKey).leftPadded(to: 32)
        let encoded = account.leftPadded(to: 32) + nonceKeyData
        return "0x" + selector + encoded.hexEncodedString
    }

    private func u256Data(from data: Data) -> [UInt8] {
        Array(data.leftPadded(to: 32))
    }

    private func addingU256(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 32)
        var carry = 0

        for index in stride(from: 31, through: 0, by: -1) {
            let sum = Int(lhs[index]) + Int(rhs[index]) + carry
            result[index] = UInt8(sum & 0xff)
            carry = sum >> 8
        }

        return result
    }

    private func parseQuantity(_ value: String, field: String) throws -> Data {
        do {
            return try Data.quantityString(value)
        } catch {
            throw RPCError.rpcError("RPC returned invalid \(field): \(value)")
        }
    }
}
