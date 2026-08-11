import Foundation
import LocalAuthentication

/// Long-lived `LAContext`s, one per prompt domain.
///
/// `touchIDAuthenticationAllowableReuseDuration` suppresses a prompt only for
/// *later uses of the same context object*. Both key stores used to create a
/// context, set the reuse duration on it, use it once and drop it — so the window
/// never suppressed anything and every unlock was a cold prompt. Holding the
/// context is what makes the setting mean something.
///
/// Deliberately not used for signing: a transaction, a session-key enablement and
/// a private-key reveal must each be authorised on their own. See the domains
/// below — there is no `.signing` case, and adding one would be a security change,
/// not a convenience one.
final class BiometricAuthenticationContexts: @unchecked Sendable {
    static let shared = BiometricAuthenticationContexts()

    /// The only thing allowed to reuse an authorisation.
    ///
    /// The bar is: the unlock recurs often enough within a session that
    /// re-prompting is noise, and the secret is one this process holds for the
    /// rest of the session anyway, so a reuse window grants nothing a live
    /// process does not already have.
    ///
    /// RAILGUN's spending entropy was briefly in here and has been taken back
    /// out. It failed the first half of the bar — it is read once per sidecar
    /// launch, so the window almost never applied — while widening the second:
    /// the entropy is the root every ephemeral exit sender is derived from, and
    /// a fresh read of it is the one moment a person has to be present for.
    /// Trading a prompt nobody was seeing for a five-minute unprompted window on
    /// spending material is a bad trade in both directions.
    enum Domain: String, CaseIterable {
        /// Handing the relayer secret to a freshly spawned `wallet-node`.
        case relayerLaunch
    }

    /// The OS caps reuse at `LATouchIDAuthenticationMaximumAllowableReuseDuration`
    /// (5 minutes); ask for exactly that rather than a number that gets clamped
    /// silently.
    static let maximumReuseDuration = LATouchIDAuthenticationMaximumAllowableReuseDuration

    private let lock = NSLock()
    private var contexts: [Domain: LAContext] = [:]

    func context(for domain: Domain, reason: String) -> LAContext {
        lock.lock()
        defer { lock.unlock() }
        let context = contexts[domain] ?? LAContext()
        contexts[domain] = context
        context.localizedReason = reason
        context.touchIDAuthenticationAllowableReuseDuration = Self.maximumReuseDuration
        return context
    }

    /// Forces the next unlock in this domain to authenticate again. Called when the
    /// key material behind it changes or goes away — a reset must not leave a
    /// context that would wave through a read of whatever replaces it.
    func invalidate(_ domain: Domain) {
        lock.lock()
        defer { lock.unlock() }
        contexts[domain]?.invalidate()
        contexts.removeValue(forKey: domain)
    }

    func invalidateAll() {
        Domain.allCases.forEach(invalidate)
    }
}

/// Every biometric authorisation the app asks for, so "why did it ask me six
/// times?" is answerable from the debug report instead of by reading the source.
///
/// Records *requests*, not prompts: a request covered by a live reuse window
/// completes without showing anything. `reusable` distinguishes the two, so a run
/// with many requests and few visible prompts reads correctly.
final class BiometricPromptLog: @unchecked Sendable {
    static let shared = BiometricPromptLog()

    struct Entry {
        let at: Date
        let reason: String
        let reusable: Bool
    }

    private let limit = 64
    private let lock = NSLock()
    private var entries: [Entry] = []

    func record(reason: String, reusable: Bool, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(Entry(at: date, reason: reason, reusable: reusable))
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }

    func snapshot() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        entries = []
    }

    /// Lines for the debug report, newest last, with a count per reason so a
    /// repeated unlock stands out without reading every row.
    func reportLines(formatter: ISO8601DateFormatter) -> [String] {
        let all = snapshot()
        guard !all.isEmpty else { return ["no biometric authorisations requested this session"] }
        var counts: [String: Int] = [:]
        for entry in all { counts[entry.reason, default: 0] += 1 }
        var lines = counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "requests=\($0.value) reason=\($0.key)" }
        lines.append("")
        lines.append(contentsOf: all.map { entry in
            "\(formatter.string(from: entry.at)) reusable=\(entry.reusable) \(entry.reason)"
        })
        return lines
    }
}
