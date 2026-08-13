import Foundation

/// Decides, before the Secure Enclave is asked to sign, whether the account can
/// cover the locally authorized EntryPoint v0.7 maximum liability.
///
/// This is a signing authorization gate, not a best-effort UX hint. It runs for
/// every operation and its caller must fail closed when the balance/deposit read
/// is unavailable. The liability comes from the shared Rust policy; daemon
/// `requiredPrefund` is never consumed here.
///
/// Arithmetic is byte-wise on big-endian `Data` rather than on `UInt64`: a real
/// account balance can exceed `UInt64.max` wei (≈18.4 ETH).
enum PrefundPrecheck {
    enum ArithmeticError: LocalizedError {
        case valueExceedsUInt256
        case minimumAccountBalanceOverflow

        var errorDescription: String? {
            switch self {
            case .valueExceedsUInt256:
                return "The prefund affordability check received a value wider than uint256."
            case .minimumAccountBalanceOverflow:
                return "The call value plus uncovered gas liability exceeds uint256."
            }
        }
    }

    struct Shortfall: Equatable {
        /// EntryPoint's balance floor for the op that would be signed.
        let requiredPrefund: Data
        /// `accountBalance + entryPointDeposit`.
        let available: Data
        /// `requiredPrefund - available`, always positive.
        let deficit: Data
    }

    /// Everything the chat card and the thrown `AppError` need, so the numbers
    /// have one origin rather than being re-derived per surface.
    struct Report: Equatable {
        let requiredPrefundWeiHex: String
        let availableWeiHex: String
        let deficitWeiHex: String
        /// The fee the floor was computed at. The deficit is fee-dominated, so
        /// naming it is what makes an outsized floor legible.
        let maxFeePerGasWeiHex: String
        /// Compatibility field for persisted chat cards created before the
        /// independent fee oracle. Newly authorized operations always use a
        /// fresh live quote and set this to false.
        let feeQuoteAtPolicyCeiling: Bool
        let effectiveCallGasLimit: UInt64
    }

    /// The daemon's exact account-balance requirement for an operation that
    /// sends native value:
    ///
    /// `callValue + max(requiredPrefund - entryPointDeposit, 0)`
    ///
    /// EntryPoint deposit can pay gas, but it cannot be transferred to the
    /// operation's recipient. Keeping this distinct from `Report` prevents the
    /// existing gas-only recovery card from presenting the deposit as spendable
    /// ETH.
    struct AccountBalanceReport: Equatable {
        let callValueWeiHex: String
        let gasBalanceRequiredWeiHex: String
        let minimumAccountBalanceWeiHex: String
        let accountBalanceWeiHex: String
        let deficitWeiHex: String
    }

    struct AccountBalanceShortfall: Equatable {
        let callValue: Data
        let gasBalanceRequired: Data
        let minimumAccountBalance: Data
        let accountBalance: Data
        let deficit: Data
    }

    enum Outcome {
        /// Proceed to the Secure Enclave.
        case proceed
        /// Decline before signing, with the numbers to explain why.
        case decline(Report)
        /// A native-value operation would leave the smart account unable to
        /// cover both the transfer and the gas not covered by its deposit.
        case accountBalanceDecline(AccountBalanceReport)
        /// The balance read failed. Callers must fail closed before key access.
        case statusUnavailable(Error)
    }

    /// The whole gate: read balance + EntryPoint deposit for every operation and
    /// decide. Takes the read as a closure so transport failure is testable
    /// without a wallet-node.
    /// `isolation` lets the read closure stay non-`Sendable` and run on the
    /// caller's actor — `AppModel` is `@MainActor` and its client accessor is
    /// too, so sending the closure across an isolation boundary would not
    /// compile under Swift 6.
    static func decision(
        requiredPrefund: Data,
        callValue: Data,
        callGasLimit: Data,
        maxFeePerGas: Data,
        feeQuoteAtPolicyCeiling: Bool,
        isolation: isolated (any Actor)? = #isolation,
        readWalletStatus: () async throws -> WalletNodeClient.WalletStatus
    ) async -> Outcome {
        let status: WalletNodeClient.WalletStatus
        do {
            status = try await readWalletStatus()
        } catch {
            return .statusUnavailable(error)
        }
        let accountShortfall: AccountBalanceShortfall?
        do {
            accountShortfall = try evaluateAccountBalance(
                requiredPrefund: requiredPrefund,
                callValue: callValue,
                accountBalance: status.accountBalance,
                entryPointDeposit: status.entryPointDeposit
            )
        } catch {
            return .statusUnavailable(error)
        }

        guard let accountShortfall else {
            return .proceed
        }

        if accountShortfall.callValue.contains(where: { $0 != 0 }) {
            return .accountBalanceDecline(
                AccountBalanceReport(
                    callValueWeiHex: "0x" + accountShortfall.callValue.hexEncodedString,
                    gasBalanceRequiredWeiHex: "0x" + accountShortfall.gasBalanceRequired.hexEncodedString,
                    minimumAccountBalanceWeiHex: "0x" + accountShortfall.minimumAccountBalance.hexEncodedString,
                    accountBalanceWeiHex: "0x" + accountShortfall.accountBalance.hexEncodedString,
                    deficitWeiHex: "0x" + accountShortfall.deficit.hexEncodedString
                )
            )
        }

        // With zero call value, the daemon formula is algebraically equivalent
        // to the original balance + deposit gas check. Preserve that report and
        // its dedicated recovery UI for existing operations and persisted rows.
        guard let shortfall = evaluate(
            requiredPrefund: requiredPrefund,
            accountBalance: status.accountBalance,
            entryPointDeposit: status.entryPointDeposit
        ) else {
            // `evaluateAccountBalance` already found a deficit, so reaching this
            // branch would mean the two implementations drifted. Fail closed.
            return .statusUnavailable(ArithmeticError.valueExceedsUInt256)
        }
        return .decline(
            Report(
                requiredPrefundWeiHex: "0x" + shortfall.requiredPrefund.hexEncodedString,
                availableWeiHex: "0x" + shortfall.available.hexEncodedString,
                deficitWeiHex: "0x" + shortfall.deficit.hexEncodedString,
                maxFeePerGasWeiHex: "0x" + maxFeePerGas.leftPadded(to: 32).hexEncodedString,
                feeQuoteAtPolicyCeiling: feeQuoteAtPolicyCeiling,
                // The local Rust authorization cap is 10,000,000, so a value
                // wider than UInt64 cannot reach this report. Preserve a loud,
                // non-truncated sentinel if that invariant is ever violated.
                effectiveCallGasLimit: narrowed(callGasLimit) ?? UInt64.max
            )
        )
    }

    /// Low 64 bits of a big-endian value, or `nil` if anything above them is set.
    /// The shared local policy clamps every limit that reaches here far below
    /// 2^64. Returning nil rather than truncating keeps that invariant explicit.
    private static func narrowed(_ value: Data) -> UInt64? {
        let padded = value.leftPadded(to: 32)
        guard padded.prefix(24).allSatisfy({ $0 == 0 }) else {
            return nil
        }
        return Data(padded.suffix(8)).reduce(0) { ($0 << 8) | UInt64($1) }
    }

    /// The arithmetic alone: `nil` when the floor is covered.
    static func evaluate(
        requiredPrefund: Data,
        accountBalance: Data,
        entryPointDeposit: Data
    ) -> Shortfall? {
        let required = requiredPrefund.leftPadded(to: 32)
        let available = add(
            accountBalance.leftPadded(to: 32),
            entryPointDeposit.leftPadded(to: 32)
        )
        guard isGreater(required, than: available) else {
            return nil
        }
        return Shortfall(
            requiredPrefund: required,
            // Both are safe to narrow to 32 bytes here: we only reach this line
            // when `available` is below a 32-byte `required`, so neither it nor
            // the difference can need the 33rd byte `add` reserves.
            available: Data(available.suffix(32)),
            deficit: Data(subtract(required, available).suffix(32))
        )
    }

    /// Mirrors wallet-node's pre-sign account-balance formula exactly. The
    /// returned deficit is against the smart account itself, not the sum of the
    /// account and EntryPoint deposit.
    static func evaluateAccountBalance(
        requiredPrefund: Data,
        callValue: Data,
        accountBalance: Data,
        entryPointDeposit: Data
    ) throws -> AccountBalanceShortfall? {
        let required = try normalizedUInt256(requiredPrefund)
        let value = try normalizedUInt256(callValue)
        let balance = try normalizedUInt256(accountBalance)
        let deposit = try normalizedUInt256(entryPointDeposit)
        let zero = Data(repeating: 0, count: 32)
        let gasBalanceRequired: Data
        if isGreater(required, than: deposit) {
            gasBalanceRequired = Data(subtract(required, deposit).suffix(32))
        } else {
            gasBalanceRequired = zero
        }

        let wideMinimum = add(value, gasBalanceRequired)
        guard wideMinimum.count <= 32
                || wideMinimum.prefix(wideMinimum.count - 32).allSatisfy({ $0 == 0 }) else {
            throw ArithmeticError.minimumAccountBalanceOverflow
        }
        let minimum = Data(wideMinimum.suffix(32))
        guard isGreater(minimum, than: balance) else {
            return nil
        }
        return AccountBalanceShortfall(
            callValue: value,
            gasBalanceRequired: gasBalanceRequired,
            minimumAccountBalance: minimum,
            accountBalance: balance,
            deficit: Data(subtract(minimum, balance).suffix(32))
        )
    }

    private static func normalizedUInt256(_ value: Data) throws -> Data {
        if value.count > 32 {
            guard value.prefix(value.count - 32).allSatisfy({ $0 == 0 }) else {
                throw ArithmeticError.valueExceedsUInt256
            }
            return Data(value.suffix(32))
        }
        return value.leftPadded(to: 32)
    }

    /// Sum of two big-endian values, one byte wider than the widest input so a
    /// carry out of the top byte is never dropped.
    private static func add(_ a: Data, _ b: Data) -> Data {
        let width = max(a.count, b.count) + 1
        let left = Array(a.leftPadded(to: width))
        let right = Array(b.leftPadded(to: width))
        var result = [UInt8](repeating: 0, count: width)
        var carry = 0
        for index in stride(from: width - 1, through: 0, by: -1) {
            let sum = Int(left[index]) + Int(right[index]) + carry
            result[index] = UInt8(sum & 0xFF)
            carry = sum >> 8
        }
        return Data(result)
    }

    /// `a - b`, defined only where `a >= b` (guarded by the `isGreater` check at
    /// the single call site).
    private static func subtract(_ a: Data, _ b: Data) -> Data {
        let width = max(a.count, b.count)
        let left = Array(a.leftPadded(to: width))
        let right = Array(b.leftPadded(to: width))
        var result = [UInt8](repeating: 0, count: width)
        var borrow = 0
        for index in stride(from: width - 1, through: 0, by: -1) {
            var difference = Int(left[index]) - Int(right[index]) - borrow
            if difference < 0 {
                difference += 256
                borrow = 1
            } else {
                borrow = 0
            }
            result[index] = UInt8(difference)
        }
        return Data(result)
    }

    /// Strict numeric comparison at a common width, in the idiom of
    /// `GasPricing.minWei` (`GasPricing.swift:83`).
    private static func isGreater(_ a: Data, than b: Data) -> Bool {
        let width = max(a.count, b.count)
        for (x, y) in zip(a.leftPadded(to: width), b.leftPadded(to: width)) where x != y {
            return x > y
        }
        return false
    }
}

/// Extracts the native value already reviewed by the user from the trusted
/// intent that produced the UserOperation. ERC-20 calls carry zero native
/// value. Keeping this mapping next to the affordability gate makes it directly
/// testable and prevents calldata parsing from becoming a second source of
/// truth.
enum UserOperationCallValue {
    static let zero = Data(repeating: 0, count: 32)

    static func wei(for intent: TransactionIntent) throws -> Data {
        switch intent {
        case let .nativeTransfer(_, amountETH):
            return try EtherAmountParser.wei(fromETHString: amountETH)
        case let .exactInputSwap(request) where request.tokenInIsNative:
            guard request.quote.amountIn.count <= 32 else {
                throw AppError.invalidAmount
            }
            return request.quote.amountIn.leftPadded(to: 32)
        case .erc20Transfer, .exactInputSwap:
            return zero
        }
    }

    /// Kernel's batch executor can send native value from more than one call.
    /// wallet-node checks their total, so the app must authorize that same total
    /// before signing. Overflow is rejected rather than wrapped.
    static func wei(for executions: [KernelExecutionRequest]) throws -> Data {
        var total = [UInt8](repeating: 0, count: 32)
        for execution in executions {
            guard execution.value.count <= 32 else {
                throw AppError.invalidAmount
            }
            let value = [UInt8](execution.value.leftPadded(to: 32))
            var carry = 0
            for index in stride(from: 31, through: 0, by: -1) {
                let sum = Int(total[index]) + Int(value[index]) + carry
                total[index] = UInt8(sum & 0xff)
                carry = sum >> 8
            }
            guard carry == 0 else {
                throw AppError.invalidAmount
            }
        }
        return Data(total)
    }
}
