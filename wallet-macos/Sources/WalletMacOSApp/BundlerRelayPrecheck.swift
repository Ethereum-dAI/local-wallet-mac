import Foundation

/// Verifies that the local bundler EOA can afford the exact finalized
/// UserOperation before any protected signing material is accessed.
///
/// The arithmetic mirrors wallet-node's submission guard. The locally
/// authorized UserOperation pays its own gas envelope, while the outer
/// `handleOps` transaction reserves an additional 150,000 gas.
enum BundlerRelayPrecheck {
    static let handleOpsOverheadGas: UInt64 = 150_000

    enum Error: Swift.Error, Equatable {
        case statusUnavailable
        case wrongChain(expected: UInt64, actual: Int)
        case wrongEOA(expected: String, actual: String)
        case malformedQuantity(String)
        case arithmeticOverflow
        case inconsistentRequiredPrefund
    }

    struct Report: Equatable {
        let balanceWeiHex: String
        let requiredBalanceWeiHex: String
        let requiredMaxCostWeiHex: String
        let deficitWeiHex: String
    }

    enum Decision: Equatable {
        case proceed
        case externalFundingRequired(Report)

        var canRelay: Bool { self == .proceed }
    }

    static func evaluate(
        gasPlan: UserOperationGasPlan,
        requiredPrefund: Data,
        status: WalletNodeClient.RelayerStatus,
        expectedChainID: UInt64,
        expectedEOA: String
    ) throws -> Decision {
        guard UInt64(exactly: status.chainId) == expectedChainID else {
            throw Error.wrongChain(expected: expectedChainID, actual: status.chainId)
        }
        guard status.eoa.caseInsensitiveCompare(expectedEOA) == .orderedSame else {
            throw Error.wrongEOA(expected: expectedEOA, actual: status.eoa)
        }
        // A passive status read may legitimately report the active key as
        // locked: this operation is precisely what will authorize loading it.
        // Every other non-ready reason is an authoritative submission blocker
        // and must stop before Touch ID. Also reject contradictory status
        // shapes instead of guessing which field is stale.
        guard status.lifecycle == "active",
              status.compromiseSubmissionBlocked == false else {
            throw Error.statusUnavailable
        }
        if status.ready {
            guard status.keyLoaded, status.reason == nil else {
                throw Error.statusUnavailable
            }
        } else {
            guard status.keyLoaded == false,
                  status.reason == "bundler_eoa_locked" else {
                throw Error.statusUnavailable
            }
        }
        guard let balance = BundlerFundingPolicy.quantity(status.balance),
              let threshold = BundlerFundingPolicy.quantity(status.thresholdLow) else {
            throw Error.statusUnavailable
        }
        // A single daemon response must not contradict its own threshold. Do
        // not make an authorization decision from an internally stale status.
        if status.needsTopup && !GasPricing.isWeiLessThan(balance, threshold) {
            throw Error.statusUnavailable
        }

        let call = try exact(gasPlan.callGasLimit)
        let verification = try exact(gasPlan.verificationGasLimit)
        let preVerification = try exact(gasPlan.preVerificationGas)
        let fee = try exact(gasPlan.maxFeePerGas)

        let baseGas = try checkedAdd(try checkedAdd(call, verification), preVerification)
        let totalGas = try checkedAdd(baseGas, handleOpsOverheadGas)
        let baseCost = try checkedMultiply(baseGas, fee)
        let maxCost = try checkedMultiply(totalGas, fee)

        // `requiredPrefund` is computed by the shared Rust authorization
        // policy as (call + verification + preVerification) * maxFee. Refuse
        // to preflight a gas plan that has drifted from that boundary.
        let baseCostData = Data.fromBigEndian(baseCost).leftPadded(to: 32)
        guard baseCostData == requiredPrefund.leftPadded(to: 32) else {
            throw Error.inconsistentRequiredPrefund
        }

        let maxCostData = Data.fromBigEndian(maxCost).leftPadded(to: 32)
        let requiredBalance = GasPricing.isWeiLessThan(threshold, maxCostData)
            ? maxCostData
            : threshold
        guard GasPricing.isWeiLessThan(balance, requiredBalance) else {
            return .proceed
        }

        let deficit = subtract(requiredBalance, balance)
        return .externalFundingRequired(
            Report(
                balanceWeiHex: quantityHex(balance),
                requiredBalanceWeiHex: quantityHex(requiredBalance),
                requiredMaxCostWeiHex: quantityHex(maxCostData),
                deficitWeiHex: quantityHex(deficit)
            )
        )
    }

    private static func exact(_ data: Data) throws -> UInt64 {
        do {
            return try GasPricing.exactUInt64(data, field: "bundler relay precheck")
        } catch {
            throw Error.malformedQuantity("bundler relay precheck")
        }
    }

    private static func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw Error.arithmeticOverflow }
        return result.partialValue
    }

    private static func checkedMultiply(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else { throw Error.arithmeticOverflow }
        return result.partialValue
    }

    /// Big-endian subtraction. The caller has already established `lhs > rhs`.
    private static func subtract(_ lhs: Data, _ rhs: Data) -> Data {
        let left = [UInt8](lhs.leftPadded(to: 32))
        let right = [UInt8](rhs.leftPadded(to: 32))
        precondition(!GasPricing.isWeiLessThan(lhs, rhs))
        var result = [UInt8](repeating: 0, count: 32)
        var borrow = 0
        for index in stride(from: 31, through: 0, by: -1) {
            var value = Int(left[index]) - Int(right[index]) - borrow
            if value < 0 {
                value += 256
                borrow = 1
            } else {
                borrow = 0
            }
            result[index] = UInt8(value)
        }
        return Data(result)
    }

    private static func quantityHex(_ data: Data) -> String {
        let body = data.hexEncodedString.drop(while: { $0 == "0" })
        return "0x" + (body.isEmpty ? "0" : String(body))
    }
}
