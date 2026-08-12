import Foundation

/// Secret availability is deliberately separate from daemon connectivity. A connected daemon
/// can serve reads while its relayer key remains locked, and every daemon restart forgets keys.
enum RelayerAccessState: Equatable, Sendable {
    case locked
    case installing(generation: UInt64)
    case available(generation: UInt64)
    case failed(generation: UInt64, message: String)

    func isAvailable(for generation: UInt64) -> Bool {
        self == .available(generation: generation)
    }

    func afterDaemonRestart() -> RelayerAccessState {
        .locked
    }
}

/// The privacy helper stays usable in memory after one explicit unlock. Hiding a view or moving
/// focus does not throw away the helper and therefore must not trigger another prompt.
enum PrivacyUnlockState: Equatable, Sendable {
    case locked
    case unlocking
    case loaded
    case failed(String)

    func afterCancellation() -> PrivacyUnlockState {
        .locked
    }
}

enum RelayerKeyInstallPolicy {
    struct HistoryEntry: Equatable, Sendable {
        let keyRef: String
        let lifecycle: String
    }

    static func relevantKeyRefs(
        activeKeyRef: String?,
        fallbackKeyRef: String?,
        history: [HistoryEntry]
    ) -> [String] {
        var result: [String] = []
        if let active = activeKeyRef ?? fallbackKeyRef {
            result.append(active)
        }
        for entry in history where entry.lifecycle == "retiring" {
            if !result.contains(entry.keyRef) {
                result.append(entry.keyRef)
            }
        }
        return result
    }
}

enum RelayerGenerationGate {
    static func accepts(resultGeneration: UInt64, currentGeneration: UInt64) -> Bool {
        resultGeneration == currentGeneration
    }
}
