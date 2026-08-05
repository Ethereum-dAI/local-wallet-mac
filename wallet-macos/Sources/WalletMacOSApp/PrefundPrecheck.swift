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

    /// Returns `nil` when the send should proceed to signing — either because no
    /// limit was acknowledged (this gate is scoped to the headroom retry) or
    /// because the floor is covered.
    static func evaluate(
        acknowledgedCallGasLimit: UInt64?,
        requiredPrefund: Data,
        accountBalance: Data,
        entryPointDeposit: Data
    ) -> Shortfall? {
        guard acknowledgedCallGasLimit != nil else {
            return nil
        }
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
