import Foundation

/// Decides, before the Secure Enclave is asked to sign, whether the account can
/// cover EntryPoint v0.7's prefund floor for a `callGasLimit` the user consented
/// to via the gas-headroom affordance.
///
/// Two deliberate narrowings, both so this can never wrongly decline a send the
/// daemon would have accepted:
///
/// - It compares `requiredPrefund` against `accountBalance + entryPointDeposit`,
///   which is strictly weaker than the daemon's `minimum_account_balance`
///   (`wallet-bundler/src/funding.rs:7` adds the call value). A balance that
///   covers the prefund but not prefund + transfer amount still surfaces at send
///   time as `transferable_below_call_value`, a different failure from #71's.
/// - A zero `requiredPrefund` — an older daemon omitting the field — never
///   declines.
///
/// One caveat the "strictly weaker" claim rests on: the estimate returns
/// `estimated.required_prefund().max(simulation.validation.prefund)`
/// (`estimate_user_operation_gas.rs:129-134`), while the send path checks only
/// `op.required_prefund()`. Were `validation.prefund` ever to win that `max`,
/// this would compare a *larger* floor than the daemon enforces and could
/// decline an affordable send. It cannot today — `simulation_attempts` floors
/// verification gas to the same `DAIMO_VERIFICATION_GAS_FLOOR` the estimate uses
/// and the estimate adds call + preVerification gas on top — but the invariant
/// is the daemon's to keep, not this file's.
///
/// Arithmetic is byte-wise on big-endian `Data` rather than on `UInt64`: a real
/// account balance can exceed `UInt64.max` wei (≈18.4 ETH).
enum PrefundPrecheck {
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
        /// The fee above is the daemon's cap placeholder rather than a live price,
        /// so no top-up can satisfy this floor until the daemon's reads recover.
        let gasPricingUnavailable: Bool
        let effectiveCallGasLimit: UInt64
    }

    enum Outcome {
        /// Proceed to the Secure Enclave.
        case proceed
        /// Decline before signing, with the numbers to explain why.
        case decline(Report)
        /// The balance read failed. Callers fail open (and log) — the send path's
        /// own funding check is still the real gate, and failing closed would
        /// turn a transient read failure into a refused send the user could
        /// afford.
        case statusUnavailable(Error)
    }

    /// The whole gate: skip unless a limit was acknowledged, read balance +
    /// EntryPoint deposit, and decide. Takes the read as a closure so the
    /// decision — including the fail-open branch — is testable without a
    /// wallet-node.
    /// `isolation` lets the read closure stay non-`Sendable` and run on the
    /// caller's actor — `AppModel` is `@MainActor` and its client accessor is
    /// too, so sending the closure across an isolation boundary would not
    /// compile under Swift 6.
    static func decision(
        acknowledgedCallGasLimit: UInt64?,
        requiredPrefund: Data,
        callGasLimit: Data,
        maxFeePerGas: Data,
        gasPricingUnavailable: Bool,
        isolation: isolated (any Actor)? = #isolation,
        readWalletStatus: () async throws -> WalletNodeClient.WalletStatus
    ) async -> Outcome {
        // Scoped to the gas-headroom retry: an ordinary send must not pay for an
        // extra round trip. Checked here rather than by the caller so the scope
        // is part of the tested unit.
        guard let acknowledgedCallGasLimit else {
            return .proceed
        }
        let status: WalletNodeClient.WalletStatus
        do {
            status = try await readWalletStatus()
        } catch {
            return .statusUnavailable(error)
        }
        guard let shortfall = evaluate(
            requiredPrefund: requiredPrefund,
            accountBalance: status.accountBalance,
            entryPointDeposit: status.entryPointDeposit
        ) else {
            return .proceed
        }
        return .decline(
            Report(
                requiredPrefundWeiHex: "0x" + shortfall.requiredPrefund.hexEncodedString,
                availableWeiHex: "0x" + shortfall.available.hexEncodedString,
                deficitWeiHex: "0x" + shortfall.deficit.hexEncodedString,
                maxFeePerGasWeiHex: "0x" + maxFeePerGas.leftPadded(to: 32).hexEncodedString,
                gasPricingUnavailable: gasPricingUnavailable,
                effectiveCallGasLimit: narrowed(callGasLimit)
                    ?? acknowledgedCallGasLimit
            )
        )
    }

    /// Low 64 bits of a big-endian value, or `nil` if anything above them is set.
    /// The daemon clamps every limit that reaches here to
    /// `policy.max_call_gas_limit`, far below 2^64, so `nil` is unreachable in
    /// practice — but a wider value must fall back to a caller-supplied number
    /// rather than silently truncate.
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
