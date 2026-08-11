import Foundation

/// Context-window preset options for the local model.
///
/// The ladder is filtered twice: by the model's trained maximum, and — in the UI —
/// by what this Mac's memory budget can hold (`ModelFitEvaluator`). A preset being
/// listed here does not mean it fits; that is the evaluator's job.
enum ContextWindowPresets {
    static let ladder: [Int] = [2048, 4096, 8192, 16384, 32768, 65536, 131072]
    static let fallback = 4096

    /// Allowed presets for a model whose trained max is `maxTokens`.
    static func options(maxTokens: Int) -> [Int] {
        let cap = max(maxTokens, ladder[0])
        var values = ladder.filter { $0 <= cap }
        if let last = values.last, last < cap { values.append(cap) }
        if values.isEmpty { values = [cap] }
        return values
    }

    /// Snap a stored value to the largest allowed preset <= it (else the smallest).
    static func clamp(_ tokens: Int, maxTokens: Int) -> Int {
        let opts = options(maxTokens: maxTokens)
        if opts.contains(tokens) { return tokens }
        return opts.filter { $0 <= tokens }.max() ?? opts.first ?? fallback
    }
}
