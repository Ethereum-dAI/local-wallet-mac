import Foundation

/// Conversion + bounds for swap slippage tolerance.
///
/// Slippage is stored and sent to the daemon in basis points (bps); the UI
/// presents it as a percentage. The daemon (`quote_swap.rs`) rejects values
/// above `MAX_SLIPPAGE_BPS = 5000` (50%) and defaults to
/// `DEFAULT_SLIPPAGE_BPS = 100` (1%).
enum SwapSlippage {
    static let maxBps: UInt64 = 5000
    static let defaultBps: UInt64 = 100
    static let presetPercents: [Double] = [0.1, 0.5, 1.0, 3.0]

    static func clampBps(_ bps: UInt64) -> UInt64 {
        min(bps, maxBps)
    }

    /// Convert a percentage (e.g. 1.5) to basis points, clamped to [0, maxBps].
    static func bps(fromPercent percent: Double) -> UInt64 {
        guard percent.isFinite, percent > 0 else { return 0 }
        let raw = (percent * 100).rounded()
        guard raw > 0 else { return 0 }
        if raw >= Double(maxBps) { return maxBps }
        return UInt64(raw)
    }

    /// Convert basis points to a percentage for display (e.g. 100 -> 1.0).
    /// Values above `maxBps` are clamped before conversion.
    static func percent(fromBps bps: UInt64) -> Double {
        Double(clampBps(bps)) / 100.0
    }
}
