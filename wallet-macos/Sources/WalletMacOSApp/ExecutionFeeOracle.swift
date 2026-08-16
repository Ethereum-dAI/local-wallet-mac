import Foundation

private final class ExecutionFeeRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Fee authorization never follows redirects. Besides preventing an
        // HTTPS-to-HTTP downgrade, this binds both RPC calls to the configured
        // endpoint instead of silently changing trust domains.
        completionHandler(nil)
    }
}

struct ExecutionFeeQuote: Equatable, Sendable {
    static let maximumAge: TimeInterval = 30
    static let maximumHeadAdvance: UInt64 = 2

    let chainID: UInt64
    let blockNumber: UInt64
    let issuedAt: Date
    let nextBlockBaseFeePerGas: Data
    let medianPriorityFeePerGas: Data
    let sixBlockMaxFeePerGas: Data

    func validateFreshness(now: Date, currentBlockNumber: UInt64) throws {
        let age = now.timeIntervalSince(issuedAt)
        guard age >= 0 else {
            throw ExecutionFeeOracleError.quoteIssuedInFuture
        }
        guard age <= Self.maximumAge else {
            throw ExecutionFeeOracleError.staleQuote(age: age)
        }
        guard currentBlockNumber >= blockNumber else {
            throw ExecutionFeeOracleError.headBehindQuote(
                quoteBlock: blockNumber,
                currentBlock: currentBlockNumber
            )
        }
        guard currentBlockNumber - blockNumber <= Self.maximumHeadAdvance else {
            throw ExecutionFeeOracleError.headAdvancedTooFar(
                quoteBlock: blockNumber,
                currentBlock: currentBlockNumber
            )
        }
    }
}

enum ExecutionFeeOracleError: Error, Equatable, LocalizedError {
    case invalidRPCURL
    case insecureRPCURL
    case invalidAddress
    case transportFailure
    case httpStatus(Int)
    case malformedResponse(method: String)
    case rpcFailure(method: String, code: Int, message: String)
    case invalidQuantity(field: String, value: String)
    case wrongChain(expected: UInt64, actual: UInt64)
    case invalidFeeHistory
    case missingRewards
    case arithmeticOverflow
    case feePolicyViolation(String)
    case quoteIssuedInFuture
    case staleQuote(age: TimeInterval)
    case headBehindQuote(quoteBlock: UInt64, currentBlock: UInt64)
    case headAdvancedTooFar(quoteBlock: UInt64, currentBlock: UInt64)

    var errorDescription: String? {
        switch self {
        case .invalidRPCURL:
            return "The execution RPC URL is invalid."
        case .insecureRPCURL:
            return "The execution RPC must use HTTPS, except for loopback development endpoints."
        case .invalidAddress:
            return "The balance address is not a valid Ethereum address."
        case .transportFailure:
            return "The execution RPC could not be reached."
        case .httpStatus(let status):
            return "The execution RPC returned HTTP status \(status)."
        case .malformedResponse(let method):
            return "The execution RPC returned a malformed \(method) response."
        case .rpcFailure(let method, let code, let message):
            return "The execution RPC \(method) call failed (\(code)): \(message)"
        case .invalidQuantity(let field, let value):
            return "The execution RPC returned an invalid \(field) quantity: \(value)"
        case .wrongChain(let expected, let actual):
            return "The execution RPC is on chain \(actual), expected \(expected)."
        case .invalidFeeHistory:
            return "The execution RPC returned an incomplete fee history."
        case .missingRewards:
            return "The execution RPC did not return priority-fee rewards."
        case .arithmeticOverflow:
            return "The execution RPC fee data exceeds the supported numeric range."
        case .feePolicyViolation(let detail):
            return detail
        case .quoteIssuedInFuture:
            return "The fee quote timestamp is in the future."
        case .staleQuote:
            return "The fee quote is older than 30 seconds."
        case .headBehindQuote:
            return "The execution RPC head is behind the quoted block."
        case .headAdvancedTooFar:
            return "The execution RPC advanced more than two blocks after the fee quote."
        }
    }
}

/// Reads EIP-1559 fee data directly from the configured execution RPC. This is
/// intentionally independent of wallet-node: helper-provided fee tiers are not
/// an authorization input.
struct ExecutionFeeOracle: @unchecked Sendable {
    private static let historyBlockCount = 5
    private static let redirectDelegate = ExecutionFeeRedirectDelegate()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func quote(
        rpcURL: URL,
        expectedChainID: UInt64,
        now: Date = Date()
    ) async throws -> ExecutionFeeQuote {
        try Self.validateRPCURL(rpcURL)
        let chainID = try await validatedChainID(rpcURL: rpcURL, expected: expectedChainID)
        let result = try await rpcResult(
            method: "eth_feeHistory",
            params: ["0x5", "latest", [50.0]],
            rpcURL: rpcURL
        )
        guard let history = result as? [String: Any],
              let oldestText = history["oldestBlock"] as? String,
              let baseFeeTexts = history["baseFeePerGas"] as? [String],
              baseFeeTexts.count == Self.historyBlockCount + 1
        else {
            throw ExecutionFeeOracleError.invalidFeeHistory
        }

        let oldestBlock = try Self.parseUInt64Quantity(oldestText, field: "oldestBlock")
        let newestOffset = UInt64(Self.historyBlockCount - 1)
        let (blockNumber, blockOverflow) = oldestBlock.addingReportingOverflow(newestOffset)
        guard !blockOverflow else {
            throw ExecutionFeeOracleError.arithmeticOverflow
        }

        let baseFees = try baseFeeTexts.enumerated().map { index, value in
            try Self.parseQuantity(value, field: "baseFeePerGas[\(index)]")
        }
        guard let nextBlockBaseFee = baseFees.last else {
            throw ExecutionFeeOracleError.invalidFeeHistory
        }

        guard let rewardTexts = history["reward"] as? [[String]],
              rewardTexts.count == Self.historyBlockCount,
              rewardTexts.allSatisfy({ $0.isEmpty == false })
        else {
            throw ExecutionFeeOracleError.missingRewards
        }
        let rewards = try rewardTexts.enumerated().map { index, values in
            try Self.parseQuantity(values[0], field: "reward[\(index)][0]")
        }.sorted(by: GasPricing.isWeiLessThan)
        let medianReward = rewards[rewards.count / 2]

        do {
            let grownBase = try GasPricing.sixBlockBaseFeeCeiling(
                nextBlockBaseFeePerGas: nextBlockBaseFee
            )
            let maxFee = try GasPricing.checkedAddWei(grownBase, medianReward)
            try GasPricing.validateAppCaps(
                maxFeePerGas: maxFee,
                maxPriorityFeePerGas: medianReward
            )
            return ExecutionFeeQuote(
                chainID: chainID,
                blockNumber: blockNumber,
                issuedAt: now,
                nextBlockBaseFeePerGas: nextBlockBaseFee,
                medianPriorityFeePerGas: medianReward,
                sixBlockMaxFeePerGas: maxFee
            )
        } catch let error as GasPricing.FeeError {
            throw ExecutionFeeOracleError.feePolicyViolation(error.localizedDescription)
        } catch {
            throw ExecutionFeeOracleError.arithmeticOverflow
        }
    }

    func currentBlockNumber(rpcURL: URL, expectedChainID: UInt64) async throws -> UInt64 {
        try Self.validateRPCURL(rpcURL)
        _ = try await validatedChainID(rpcURL: rpcURL, expected: expectedChainID)
        let result = try await rpcResult(method: "eth_blockNumber", params: [], rpcURL: rpcURL)
        guard let value = result as? String else {
            throw ExecutionFeeOracleError.malformedResponse(method: "eth_blockNumber")
        }
        return try Self.parseUInt64Quantity(value, field: "blockNumber")
    }

    /// Reads a public account balance directly from the configured execution RPC.
    /// The chain ID is checked first so onboarding cannot accept funding observed
    /// on a different network, and the result must be a canonical JSON-RPC quantity.
    func balanceWeiHex(
        address: String,
        rpcURL: URL,
        expectedChainID: UInt64
    ) async throws -> String {
        try Self.validateRPCURL(rpcURL)
        guard address.count == 42,
              address.hasPrefix("0x"),
              address.dropFirst(2).allSatisfy(\.isHexDigit) else {
            throw ExecutionFeeOracleError.invalidAddress
        }

        _ = try await validatedChainID(rpcURL: rpcURL, expected: expectedChainID)
        let result = try await rpcResult(
            method: "eth_getBalance",
            params: [address, "latest"],
            rpcURL: rpcURL
        )
        guard let value = result as? String else {
            throw ExecutionFeeOracleError.malformedResponse(method: "eth_getBalance")
        }
        _ = try Self.parseQuantity(value, field: "balance")
        return value.lowercased()
    }

    func validateFreshness(
        of quote: ExecutionFeeQuote,
        rpcURL: URL,
        expectedChainID: UInt64,
        now: Date = Date()
    ) async throws {
        guard quote.chainID == expectedChainID else {
            throw ExecutionFeeOracleError.wrongChain(
                expected: expectedChainID,
                actual: quote.chainID
            )
        }
        let head = try await currentBlockNumber(
            rpcURL: rpcURL,
            expectedChainID: expectedChainID
        )
        try quote.validateFreshness(now: now, currentBlockNumber: head)
    }

    private func validatedChainID(rpcURL: URL, expected: UInt64) async throws -> UInt64 {
        let result = try await rpcResult(method: "eth_chainId", params: [], rpcURL: rpcURL)
        guard let value = result as? String else {
            throw ExecutionFeeOracleError.malformedResponse(method: "eth_chainId")
        }
        let actual = try Self.parseUInt64Quantity(value, field: "chainId")
        guard actual == expected else {
            throw ExecutionFeeOracleError.wrongChain(expected: expected, actual: actual)
        }
        return actual
    }

    private func rpcResult(method: String, params: [Any], rpcURL: URL) async throws -> Any {
        var request = URLRequest(url: rpcURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params,
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(
                for: request,
                delegate: Self.redirectDelegate
            )
        } catch {
            throw ExecutionFeeOracleError.transportFailure
        }
        guard let http = response as? HTTPURLResponse else {
            throw ExecutionFeeOracleError.malformedResponse(method: method)
        }
        guard let responseURL = http.url else {
            throw ExecutionFeeOracleError.malformedResponse(method: method)
        }
        try Self.validateRPCURL(responseURL)
        guard (200..<300).contains(http.statusCode) else {
            throw ExecutionFeeOracleError.httpStatus(http.statusCode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExecutionFeeOracleError.malformedResponse(method: method)
        }
        if let failure = object["error"] as? [String: Any] {
            let code = (failure["code"] as? NSNumber)?.intValue ?? -32_000
            let message = failure["message"] as? String ?? "unknown RPC error"
            throw ExecutionFeeOracleError.rpcFailure(method: method, code: code, message: message)
        }
        guard let result = object["result"], !(result is NSNull) else {
            throw ExecutionFeeOracleError.malformedResponse(method: method)
        }
        return result
    }

    private static func validateRPCURL(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else {
            throw ExecutionFeeOracleError.invalidRPCURL
        }
        if scheme == "https" {
            return
        }
        let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
        guard scheme == "http", loopbackHosts.contains(host) else {
            throw ExecutionFeeOracleError.insecureRPCURL
        }
    }

    private static func parseQuantity(_ value: String, field: String) throws -> Data {
        guard value.hasPrefix("0x") else {
            throw ExecutionFeeOracleError.invalidQuantity(field: field, value: value)
        }
        let body = value.dropFirst(2)
        guard !body.isEmpty,
              body.allSatisfy({ $0.isHexDigit }),
              body == "0" || body.first != "0"
        else {
            throw ExecutionFeeOracleError.invalidQuantity(field: field, value: value)
        }
        let parsed: Data
        do {
            parsed = try Data.quantityString(value)
        } catch {
            throw ExecutionFeeOracleError.invalidQuantity(field: field, value: value)
        }
        guard parsed.count <= 32 else {
            throw ExecutionFeeOracleError.invalidQuantity(field: field, value: value)
        }
        return parsed.leftPadded(to: 32)
    }

    private static func parseUInt64Quantity(_ value: String, field: String) throws -> UInt64 {
        let data = try parseQuantity(value, field: field)
        do {
            return try GasPricing.exactUInt64(data, field: field)
        } catch {
            throw ExecutionFeeOracleError.invalidQuantity(field: field, value: value)
        }
    }
}
