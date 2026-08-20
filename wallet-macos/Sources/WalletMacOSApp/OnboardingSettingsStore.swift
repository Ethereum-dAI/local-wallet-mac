import Foundation

final class OnboardingSettingsStore {
    private enum Keys {
        static let completed = "com.localwallet.demo.onboarding.completed"
        static let rpcURL = "com.localwallet.demo.onboarding.rpc-url"
        static let archiveNodeURL = "com.localwallet.demo.onboarding.archive-node-url"
        static let consensusRPCURL = "com.localwallet.demo.onboarding.consensus-rpc-url"
        static let selectedModelID = "com.localwallet.demo.onboarding.selected-model-id"
        static let installedModelID = "com.localwallet.demo.onboarding.installed-model-id"
        static let installedModelPath = "com.localwallet.demo.onboarding.installed-model-path"
        static let bundlerKeyRef = "com.localwallet.demo.onboarding.bundler-key-ref"
        static let bundlerAddress = "com.localwallet.demo.onboarding.bundler-address"
        static let contextWindowTokens = "com.localwallet.demo.onboarding.context-window-tokens"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isCompleted: Bool {
        defaults.bool(forKey: Keys.completed)
    }

    var rpcURL: String {
        get {
            defaults.string(forKey: Keys.rpcURL) ?? ChainConfiguration.ethereumSepolia.rpcURL.absoluteString
        }
        set {
            defaults.set(newValue, forKey: Keys.rpcURL)
        }
    }

    var archiveNodeURL: String {
        get {
            defaults.string(forKey: Keys.archiveNodeURL) ?? ""
        }
        set {
            defaults.set(newValue, forKey: Keys.archiveNodeURL)
        }
    }

    var consensusRPCURL: String {
        get {
            defaults.string(forKey: Keys.consensusRPCURL) ?? ""
        }
        set {
            defaults.set(newValue, forKey: Keys.consensusRPCURL)
        }
    }

    var selectedModelID: String {
        get {
            defaults.string(forKey: Keys.selectedModelID) ?? LocalAIModel.recommended.id
        }
        set {
            defaults.set(newValue, forKey: Keys.selectedModelID)
        }
    }

    var installedModelID: String? {
        get {
            defaults.string(forKey: Keys.installedModelID)
        }
        set {
            defaults.set(newValue, forKey: Keys.installedModelID)
        }
    }

    var installedModelPath: String? {
        get {
            defaults.string(forKey: Keys.installedModelPath)
        }
        set {
            defaults.set(newValue, forKey: Keys.installedModelPath)
        }
    }

    // The relayer identity cache is chain-scoped: a single shared slot let a
    // stale configuration cannot display an unrelated relayer address.
    func bundlerKeyRef(chainId: UInt64) -> String? {
        migrateLegacyBundlerCacheIfNeeded(chainId: chainId)
        return defaults.string(forKey: Self.bundlerKeyRefKey(chainId: chainId))
    }

    func setBundlerKeyRef(_ value: String?, chainId: UInt64) {
        setOrRemove(value, forKey: Self.bundlerKeyRefKey(chainId: chainId))
    }

    func bundlerAddress(chainId: UInt64) -> String? {
        migrateLegacyBundlerCacheIfNeeded(chainId: chainId)
        return defaults.string(forKey: Self.bundlerAddressKey(chainId: chainId))
    }

    func setBundlerAddress(_ value: String?, chainId: UInt64) {
        setOrRemove(value, forKey: Self.bundlerAddressKey(chainId: chainId))
    }

    func clearBundlerCache(chainIds: [UInt64]) {
        for chainId in chainIds {
            defaults.removeObject(forKey: Self.bundlerKeyRefKey(chainId: chainId))
            defaults.removeObject(forKey: Self.bundlerAddressKey(chainId: chainId))
        }
        defaults.removeObject(forKey: Keys.bundlerKeyRef)
        defaults.removeObject(forKey: Keys.bundlerAddress)
    }

    // The pre-chain-scoping cache was a single global slot; adopt it only for
    // the chain the stored keyRef actually belongs to, then drop the shared
    // slot so it can never leak across chains again.
    private func migrateLegacyBundlerCacheIfNeeded(chainId: UInt64) {
        guard let legacyKeyRef = defaults.string(forKey: Keys.bundlerKeyRef),
              BundlerLaunchKeyPolicy.chainId(ofKeyRef: legacyKeyRef) == chainId else {
            return
        }
        if defaults.string(forKey: Self.bundlerKeyRefKey(chainId: chainId)) == nil {
            defaults.set(legacyKeyRef, forKey: Self.bundlerKeyRefKey(chainId: chainId))
        }
        if let legacyAddress = defaults.string(forKey: Keys.bundlerAddress),
           defaults.string(forKey: Self.bundlerAddressKey(chainId: chainId)) == nil {
            defaults.set(legacyAddress, forKey: Self.bundlerAddressKey(chainId: chainId))
        }
        defaults.removeObject(forKey: Keys.bundlerKeyRef)
        defaults.removeObject(forKey: Keys.bundlerAddress)
    }

    private static func bundlerKeyRefKey(chainId: UInt64) -> String {
        "\(Keys.bundlerKeyRef).\(chainId)"
    }

    private static func bundlerAddressKey(chainId: UInt64) -> String {
        "\(Keys.bundlerAddress).\(chainId)"
    }

    private func setOrRemove(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    var contextWindowTokens: Int {
        get {
            let stored = defaults.integer(forKey: Keys.contextWindowTokens)
            return stored > 0 ? stored : 4096
        }
        set {
            defaults.set(newValue, forKey: Keys.contextWindowTokens)
        }
    }

    func markCompleted() {
        defaults.set(true, forKey: Keys.completed)
    }

    func markIncomplete() {
        defaults.removeObject(forKey: Keys.completed)
    }
}

struct LocalAIModel: Identifiable, Equatable {
    let id: String
    let name: String
    let size: String
    let detail: String
    let tag: String
    let systemImage: String
    let artifactRepo: String
    let artifactFileName: String
    let artifactURL: URL
    let sha256: String
    let memoryProfile: ModelMemoryProfile

    /// The context ceiling the model was trained for. Comes from the GGUF header,
    /// not from a guess: `gemma4.context_length` is 131072.
    var maxContextTokens: Int { memoryProfile.trainedContextTokens }

    /// The shipped default: the **untuned** Gemma 4 E4B, instruction-tuned by Google,
    /// as a Q4_K_M GGUF. This is what the app shipped before the fine-tune, restored.
    ///
    /// The fine-tune was made the default on the strength of 80.1% against the base's
    /// 9.8% — both measured on a 307-case benchmark whose amounts were expressed in
    /// **base units** (wei). The app's tool contract is human decimals and has been for
    /// a while, and nobody re-measured the shipped model against it. Re-measured on a
    /// frozen 1000-case benchmark under the prompt and tools this app actually sends:
    ///
    ///   * `gemma-4-E4B-wallet-ft` (what shipped): **68.6%**
    ///   * this untuned base:                     **90.3%**, and 91.0% with the
    ///     safety clause in `ToolDefinitions`
    ///
    /// The fine-tune's dominant failure is over-refusal — 147 of 1000 cases where a
    /// call was expected and none came, most of them prose — because refusing an
    /// under-specified amount was correct under the base-unit contract it was trained
    /// for. A minority emit the old contract outright: `88.5` as `88.5e18`.
    ///
    /// So this is a revert, not a downgrade: it is 21.7 points of accuracy for a
    /// smaller download and no fine-tune to maintain.
    ///
    /// **The URL is pinned to a revision, deliberately.** ggml-org re-quantized this
    /// repo and dropped Q4_K_M from `main`, which is why an earlier revision of this
    /// file fell back to Q4_0. `resolve/1762c8e8713f/` still serves the original
    /// Q4_K_M, and its `x-linked-etag` is the sha256 below — the same bytes the 90.3%
    /// was measured on. Do not "fix" this to `resolve/main/`: that 404s.
    ///
    /// This is now the ONLY Gemma entry. The superseded wallet fine-tune used to sit
    /// beside it in `curated` so that installs which onboarded onto it kept resolving
    /// their stored `selectedModelID`. Its Hugging Face repo has since been deleted, so
    /// that entry pointed at a 404: an install whose GGUF was missing could not
    /// re-download it, and one whose GGUF was present was pinned to a model measured at
    /// 68.6% against this one's 90.3%. Those installs now fall back here, which is a
    /// download they were going to need eventually and a better model when they get it.
    static let recommended = LocalAIModel(
        id: "google/gemma-4-E4B-it",
        name: "Gemma 4 E4B",
        size: "5.34 GB",
        detail: "Instruction-tuned Gemma 4 E4B as a Q4_K_M GGUF, published by ggml-org. Scores 90.3% on the frozen 1000-case wallet tool-call benchmark under the app's own prompt and tools, 21.7 points above the fine-tune that previously shipped.",
        tag: "GGUF",
        systemImage: "sparkles",
        artifactRepo: "ggml-org/gemma-4-E4B-it-GGUF",
        artifactFileName: "gemma-4-E4B-it-Q4_K_M.gguf",
        artifactURL: URL(string: "https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF/resolve/1762c8e8713f/gemma-4-E4B-it-Q4_K_M.gguf?download=true")!,
        sha256: "90ce98129eb3e8cc57e62433d500c97c624b1e3af1fcc85dd3b55ad7e0313e9f",
        // Read from the GGUF header of the pinned artifact:
        // gemma4.block_count=42, head_count_kv=2, key/value_length=512,
        // context_length=131072 → 168 KiB of KV cache per token.
        memoryProfile: ModelMemoryProfile(
            weightBytes: 5_335_289_824,
            blockCount: 42,
            kvHeadCount: 2,
            keyLength: 512,
            valueLength: 512,
            trainedContextTokens: 131_072
        )
    )

    /// Qwen's own GGUF build, deliberately sized to sit next to Gemma 4 rather than
    /// below it: 5.03 GB of weights and 144 KiB of KV per token means ~6.5 GB at
    /// 4k against Gemma's ~6.1 GB, so a Mac that runs one runs the other.
    static let qwen3 = LocalAIModel(
        id: "Qwen/Qwen3-8B",
        name: "Qwen3 8B",
        size: "5.03 GB",
        detail: "Qwen3 8B as a Q4_K_M GGUF, published by Qwen. Trained to 40,960 tokens, so it offers a shorter maximum context than Gemma 4.",
        tag: "GGUF",
        systemImage: "cube",
        artifactRepo: "Qwen/Qwen3-8B-GGUF",
        artifactFileName: "Qwen3-8B-Q4_K_M.gguf",
        artifactURL: URL(string: "https://huggingface.co/Qwen/Qwen3-8B-GGUF/resolve/main/Qwen3-8B-Q4_K_M.gguf?download=true")!,
        sha256: "d98cdcbd03e17ce47681435b5150e34c1417f50b5c0019dd560e4882c5745785",
        // Read from the GGUF header of the pinned artifact:
        // qwen3.block_count=36, head_count_kv=8, key/value_length=128,
        // context_length=40960 → 144 KiB of KV cache per token.
        memoryProfile: ModelMemoryProfile(
            weightBytes: 5_027_783_488,
            blockCount: 36,
            kvHeadCount: 8,
            keyLength: 128,
            valueLength: 128,
            trainedContextTokens: 40_960
        )
    )

    /// Every model the app ships knowledge of: the Settings catalog, and the lookup
    /// table for resolving a persisted `selectedModelID` back to its pinned profile.
    ///
    /// Every entry must name an artifact that is actually fetchable. A row whose repo
    /// has been deleted is worse than no row: it resolves, so the fallback to
    /// `recommended` never fires, and the download 404s instead.
    /// `curatedModelsPointAtLiveUpstreamRepos` guards that.
    static let curated: [LocalAIModel] = [
        recommended,
        qwen3,
    ]

    /// What first-run setup offers: the default, and Qwen3 8B as the one alternative.
    ///
    /// It used to be the default alone, on the reasoning that onboarding is not where
    /// this choice belongs. Two models is still not a menu — both are pinned, both are
    /// measured, and both sit in the same memory class, so either one gives a working
    /// wallet. What onboarding must not become is a browser: anything beyond these two,
    /// including any other GGUF on Hugging Face, is a Settings › Models decision made
    /// later by someone who has seen their own hardware verdicts.
    static let onboardingOptions: [LocalAIModel] = [
        recommended,
        qwen3,
    ]
}
