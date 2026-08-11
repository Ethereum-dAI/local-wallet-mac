import Combine
import Foundation

/// What adding a model is doing right now, so the form can say so rather than
/// showing a stalled progress bar. The load test runs a real llama.cpp load and
/// one generation, which can take a minute — long enough that it needs its own
/// phase.
enum ModelInstallPhase: Equatable, Sendable {
    case downloading(Double)
    case testing
}

extension ModelInstallPhase {
    /// Whether moving to this phase changes anything the UI actually draws.
    ///
    /// Progress is rendered as whole percents (`Int(value * 100)`), and
    /// `URLSession` reports progress once per received chunk — hundreds of times a
    /// second on a fast link. Publishing every one of them redraws the same pixels
    /// on the main actor for the length of a multi-gigabyte download.
    func isVisibleChange(from current: ModelInstallPhase) -> Bool {
        if case .downloading(let updated) = self, case .downloading(let existing) = current {
            return Int(updated * 100) != Int(existing * 100)
        }
        return self != current
    }
}

/// The install in flight — which model, and how far along.
///
/// Owned by the chat model, never by a view. It used to live as `@State` on
/// `LocalWalletSettingsView`, and the mismatch was the bug: the download runs in
/// an *unstructured* `Task`, which correctly outlives the view, but the progress
/// state did not. Navigating away from Models and back reset it to nil, so the
/// row fell back to "Download · not downloaded" while bytes kept arriving, the
/// Cancel button (rendered only for the downloading row) vanished, and pressing
/// Download again threw `downloadAlreadyInProgress` — an instruction to cancel
/// something the UI no longer offered any way to cancel. Quitting the app was the
/// only exit.
struct ModelInstallProgress: Equatable {
    let modelID: String
    let displayName: String
    var phase: ModelInstallPhase
}

extension ModelInstallProgress {
    /// True when a Settings model row exists for this install, so that row is the
    /// one drawing the progress and the Cancel button.
    ///
    /// The Hugging Face form has to ask this before drawing its own: a curated
    /// download is not the form's to display — and emphatically not the form's to
    /// cancel. Without the check, pressing Download on a curated row put a second
    /// progress bar and a stray Cancel inside the "Add From Hugging Face" panel,
    /// for a file the user never picked there.
    func isClaimedByRow(ids: [String]) -> Bool { ids.contains(modelID) }
}

/// The install in flight and the last one's outcome, observable on its own.
///
/// Deliberately *not* `@Published` state on `ChatDashboardModel`. It started
/// there, and every progress tick then invalidated the whole dashboard: with
/// Settings open that re-derived `settingsSnapshot`, which walks the model catalog
/// (a `FileManager` stat per row), recomputes a fit verdict per row, formats the
/// chat database size and runs a SQLite count for the feedback-export row —
/// roughly a hundred times per download, all on the main actor. Observed only by
/// the view that renders it, the same state survives navigation without
/// re-deriving the entire settings surface.
@MainActor
final class ModelInstallStore: ObservableObject {
    @Published private(set) var install: ModelInstallProgress?
    @Published private(set) var outcome: ModelInstallOutcome?

    /// Returns false when an install is already in flight, so a second press is a
    /// no-op rather than a `downloadAlreadyInProgress` thrown at whoever is on
    /// screen. One at a time is the download manager's rule too.
    func begin(modelID: String, displayName: String) -> Bool {
        guard install == nil else { return false }
        install = ModelInstallProgress(modelID: modelID, displayName: displayName, phase: .downloading(0))
        outcome = nil
        return true
    }

    /// Ignores a report for an install that is no longer the current one, and one
    /// that would not change what is drawn.
    func update(modelID: String, phase: ModelInstallPhase) {
        guard var current = install, current.modelID == modelID else { return }
        guard phase.isVisibleChange(from: current.phase) else { return }
        current.phase = phase
        install = current
    }

    func finish(_ outcome: ModelInstallOutcome) {
        install = nil
        self.outcome = outcome
    }

    /// The outcome outlives the view that would have shown it, which is the point
    /// — and the reason it needs an explicit way out. Cleared when the user
    /// dismisses the banner, when another model action reports something newer, and
    /// when the next install starts.
    func clearOutcome() {
        outcome = nil
    }
}

/// How the last install ended. Also on the model rather than the view, for the
/// same reason: the success/failure sentence is produced when the download
/// finishes, which is routinely long after the user has navigated elsewhere.
struct ModelInstallOutcome: Equatable {
    let isFailure: Bool
    let text: String
}

/// The sentence appended to the download message once the freshly installed model
/// has been loaded for real. Pure, so the wording of each outcome is testable
/// without a GPU.
enum ModelSelfTestReport {
    static let skippedWhileGenerating = "Skipped the load test because a reply was in progress."

    static func message(for result: ModelSelfTestResult) -> String {
        switch result {
        case .ready(let tokens):
            return "It loaded and made a tool call at \(RemoteModelFitDescriber.tokenText(tokens))."
        case .steppedDown(let from, let to):
            return "It does not load at \(RemoteModelFitDescriber.tokenText(from)) on this Mac, only "
                + "\(RemoteModelFitDescriber.tokenText(to)) — lower the context window before using it."
        case .noToolSupport:
            return "It loads, but did not answer with a tool call, so transfers and swaps may not work."
        case .failed(let reason):
            return "It could not be loaded on this Mac: \(reason)"
        }
    }
}

/// A verdict on a model that is *not* downloaded yet, computed from its GGUF
/// header read over a ranged request.
struct RemoteModelFit: Equatable {
    let verdict: ModelFitVerdict
    let summary: String
}

/// Turns a remote model's profile into the sentence shown under the file picker.
/// Pure, so the copy — including the "needs a Mac with about N" inversion — is
/// unit-testable without a network or a GPU.
enum RemoteModelFitDescriber {
    static let unknownFallbackReason = "Could not read this file's memory needs before downloading."
    static let unknownSuffix = "You can still add it; the verdict is recomputed from the file itself once it is on disk."

    /// `reason` is the specific failure when there is one — a gated repo, a host
    /// that refuses ranged reads, a header this parser does not understand. Saying
    /// which beats a bare "unknown", and none of them stop the download.
    static func unknown(reason: String? = nil) -> RemoteModelFit {
        RemoteModelFit(verdict: .unknown, summary: "\(reason ?? unknownFallbackReason) \(unknownSuffix)")
    }

    static func describe(
        profile: ModelMemoryProfile?,
        contextTokens: Int,
        budget: HardwareBudget?
    ) -> RemoteModelFit {
        guard let profile, let budget else { return unknown() }
        let verdict = ModelFitEvaluator.verdict(
            profile: profile,
            contextTokens: contextTokens,
            budget: budget
        )
        let need = memoryText(ModelFitEvaluator.requiredBytes(profile: profile, contextTokens: contextTokens))
        let available = memoryText(budget.usableBytes)

        switch verdict {
        case .unknown:
            return unknown()
        case .fits:
            return RemoteModelFit(
                verdict: verdict,
                summary: "Fits at \(tokenText(contextTokens)) — about \(need) of the \(available) this Mac can give a model."
            )
        case .tight:
            return RemoteModelFit(
                verdict: verdict,
                summary: "Tight at \(tokenText(contextTokens)) — about \(need) of the \(available) available. Replies may be slow."
            )
        case .wontFit:
            let minimum = memoryText(ModelFitEvaluator.minimumMemoryBytes(
                profile: profile,
                contextTokens: contextTokens,
                comfortable: true
            ))
            var summary = "Won't fit at \(tokenText(contextTokens)) — needs about \(need), and this Mac has \(available) for a model. "
                + "It wants a Mac with about \(minimum)."
            if let smaller = ModelFitEvaluator.largestFittingContext(profile: profile, budget: budget) {
                summary += " It does fit here at \(tokenText(smaller))."
            }
            return RemoteModelFit(verdict: verdict, summary: summary)
        }
    }

    /// `.memory` (1024-based), not `.file`: these are RAM figures, and `.file`
    /// renders 36 GiB as "38.65 GB" next to a Mac the user knows as a 36 GB one.
    static func memoryText(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    static func tokenText(_ tokens: Int) -> String {
        "\(tokens.formatted()) tokens"
    }
}
