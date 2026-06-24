import Foundation

/// Context-window preset options for the local model.
///
/// We present a fixed ladder filtered to the selected model's trained maximum
/// (a static `LocalAIModel.maxContextTokens`) rather than reading llama.cpp's
/// `n_ctx_train`, which would require the model to be loaded.
enum ContextWindowPresets {
    static let ladder: [Int] = [2048, 4096, 8192, 16384, 32768]
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
