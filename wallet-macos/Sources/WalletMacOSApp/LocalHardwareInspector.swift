import Foundation

struct LocalHardwareProfile: Equatable {
    static let minimumModelMemoryBytes: UInt64 = 16 * 1024 * 1024 * 1024

    let modelName: String
    let chipName: String
    let memoryBytes: UInt64

    var hasMinimumModelMemory: Bool {
        memoryBytes >= Self.minimumModelMemoryBytes
    }

    var memoryText: String {
        let gib = Double(memoryBytes) / 1024 / 1024 / 1024
        let rounded = Int(gib.rounded())
        return "\(rounded) GB RAM"
    }

    var displayName: String {
        "\(modelName) \(chipName) · \(memoryText)"
    }
}

struct LocalHardwareInspector {
    func inspect() async -> LocalHardwareProfile {
        let fallbackMemory = Self.physicalMemoryBytes()
        let fallbackModel = Self.sysctlString("hw.model") ?? "This Mac"
        let fallbackChip = Self.sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"

        guard let systemProfile = await Self.systemProfilerHardware() else {
            return LocalHardwareProfile(
                modelName: fallbackModel,
                chipName: fallbackChip,
                memoryBytes: fallbackMemory
            )
        }

        return LocalHardwareProfile(
            modelName: systemProfile.machineName ?? fallbackModel,
            chipName: systemProfile.chipType ?? fallbackChip,
            memoryBytes: fallbackMemory
        )
    }

    private static func physicalMemoryBytes() -> UInt64 {
        if let sysctlMemory = sysctlUInt64("hw.memsize") {
            return sysctlMemory
        }
        return ProcessInfo.processInfo.physicalMemory
    }

    private static func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else {
            return nil
        }

        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sysctlUInt64(_ key: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(key, &value, &size, nil, 0) == 0 else {
            return nil
        }
        return value
    }

    private static func systemProfilerHardware() async -> SystemProfilerHardware? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            process.arguments = ["SPHardwareDataType", "-json"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    return nil
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let decoded = try JSONDecoder().decode(SystemProfilerResponse.self, from: data)
                return decoded.hardware.first
            } catch {
                return nil
            }
        }.value
    }
}

private struct SystemProfilerResponse: Decodable {
    let hardware: [SystemProfilerHardware]

    enum CodingKeys: String, CodingKey {
        case hardware = "SPHardwareDataType"
    }
}

private struct SystemProfilerHardware: Decodable {
    let machineName: String?
    let chipType: String?

    enum CodingKeys: String, CodingKey {
        case machineName = "machine_name"
        case chipType = "chip_type"
    }
}
