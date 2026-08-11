import Foundation
import Metal

/// How much memory a local model may realistically occupy on this Mac.
///
/// `metalBudgetBytes` is what Metal will hand out before performance degrades
/// (`MTLDevice.recommendedMaxWorkingSetSize`, ~75-78% of unified memory on Apple
/// Silicon). We take the tighter of that and "RAM minus a fixed reserve for macOS,
/// the app, and wallet-node", because the GPU ceiling alone would starve everything
/// else on the machine.
struct HardwareBudget: Equatable {
    /// Held back for macOS, the app itself, and the wallet-node child process.
    /// Scales with the machine: a flat 8 GB would leave an 8 GB Mac with nothing.
    static func systemReserveBytes(totalMemoryBytes: UInt64) -> UInt64 {
        min(8 * 1_073_741_824, totalMemoryBytes / 100 * 40)
    }

    let totalMemoryBytes: UInt64
    let metalBudgetBytes: UInt64
    let freeDiskBytes: UInt64

    /// The hard ceiling. A model above this will swap or fail to load.
    var usableBytes: UInt64 {
        let reserve = Self.systemReserveBytes(totalMemoryBytes: totalMemoryBytes)
        let afterReserve = totalMemoryBytes > reserve ? totalMemoryBytes - reserve : 0
        return min(metalBudgetBytes, afterReserve)
    }

    /// The soft ceiling: below this, the model runs without crowding the machine.
    var comfortableBytes: UInt64 {
        usableBytes / 100 * 80
    }
}

extension LocalHardwareInspector {
    func budget() async -> HardwareBudget {
        HardwareBudget(
            totalMemoryBytes: Self.physicalMemoryBytesForBudget(),
            metalBudgetBytes: Self.metalBudgetBytes(),
            freeDiskBytes: Self.freeDiskBytes()
        )
    }

    static func metalBudgetBytes() -> UInt64 {
        guard let device = MTLCreateSystemDefaultDevice() else {
            // No Metal device: fall back to the 75% Apple Silicon convention.
            return physicalMemoryBytesForBudget() / 100 * 75
        }
        return device.recommendedMaxWorkingSetSize
    }

    static func freeDiskBytes() -> UInt64 {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        let values = try? appSupport.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return UInt64(max(values?.volumeAvailableCapacityForImportantUsage ?? 0, 0))
    }

    static func physicalMemoryBytesForBudget() -> UInt64 {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.memsize", &value, &size, nil, 0) == 0, value > 0 {
            return value
        }
        return ProcessInfo.processInfo.physicalMemory
    }
}
