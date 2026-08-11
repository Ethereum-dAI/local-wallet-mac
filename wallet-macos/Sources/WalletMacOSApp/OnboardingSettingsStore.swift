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
    // mainnet<->sepolia switch display the other chain's relayer address.
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

    /// The shipped default: Gemma 4 E4B with a LoRA fine-tune on wallet tool calls
    /// merged in, quantised to Q4_K_M.
    ///
    /// It is the default because the base model could not do the job. On the
    /// 307-case tool-calling evaluation set, scored by exact match on every field
    /// of every call, the base scores 9.8% and this scores 80.1% — a wallet that
    /// mis-encodes an amount or picks the wrong tool nine times in ten is not a
    /// wallet. Same architecture as the base (the GGUF header is identical apart
    /// from weight size), so the Gemma 4 DSL parsing, chat template and context
    /// presets all apply unchanged.
    ///
    /// `gemma4Base` stays in `curated`, so anyone who onboarded before this
    /// keeps resolving their stored `selectedModelID` and is never force-migrated
    /// into a second multi-gigabyte download.
    static let recommended = LocalAIModel(
        id: "ef-dai-team/gemma-4-E4B-wallet-ft",
        name: "Gemma 4 E4B (wallet-tuned)",
        size: "5.34 GB",
        detail: "Gemma 4 E4B fine-tuned on 1,739 wallet tool-calling examples, as a Q4_K_M GGUF. Scores 80.1% on the 307-case tool-call evaluation, against 9.8% for the untuned base.",
        tag: "GGUF",
        systemImage: "sparkles",
        artifactRepo: "ef-dai-team/gemma-4-E4B-wallet-ft",
        artifactFileName: "gemma-4-E4B-wallet-ft.Q4_K_M.gguf",
        artifactURL: URL(string: "https://huggingface.co/ef-dai-team/gemma-4-E4B-wallet-ft/resolve/main/gemma-4-E4B-wallet-ft.Q4_K_M.gguf?download=true")!,
        sha256: "fdf5c30e86d83c0391bed5e005af85bd2af2eb1ef7455a64b9a463d4d8ced16b",
        // Read from the GGUF header of the pinned artifact: the merge changes the
        // weights, not the shape — gemma4.block_count=42, head_count_kv=2,
        // key/value_length=512, context_length=131072 → the same 168 KiB of KV
        // cache per token as the base, over 745 MB more weights.
        memoryProfile: ModelMemoryProfile(
            weightBytes: 5_335_292_160,
            blockCount: 42,
            kvHeadCount: 2,
            keyLength: 512,
            valueLength: 512,
            trainedContextTokens: 131_072
        )
    )

    /// The untuned base the default is built from. No longer the default, but kept
    /// in `curated` — it is what every existing install is pointed at, and it is
    /// the honest comparison for anyone who wants to see what the fine-tune bought.
    static let gemma4Base = LocalAIModel(
        id: "google/gemma-4-E4B-it",
        name: "Gemma 4 E4B",
        size: "4.59 GB",
        detail: "Instruction-tuned Gemma 4 E4B, downloaded as a Q4_0 GGUF for local llama.cpp inference. The base the wallet's default model is fine-tuned from; much weaker at tool calls.",
        tag: "GGUF",
        systemImage: "sparkles",
        artifactRepo: "ggml-org/gemma-4-E4B-it-GGUF",
        artifactFileName: "gemma-4-E4B-it-Q4_0.gguf",
        // ggml-org re-quantized this repo and dropped Q4_K_M, so the old URL 404s. Q4_0 is
        // the closest surviving quant.
        artifactURL: URL(string: "https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_0.gguf?download=true")!,
        sha256: "a555b900214b477d8880e7832e0b8925e139b0159640036b09fe472b6f2097f2",
        // Read from the GGUF header of the pinned artifact:
        // gemma4.block_count=42, head_count_kv=2, key/value_length=512,
        // context_length=131072 → 168 KiB of KV cache per token.
        memoryProfile: ModelMemoryProfile(
            weightBytes: 4_590_807_392,
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
    static let curated: [LocalAIModel] = [
        recommended,
        gemma4Base,
        qwen3,
    ]

    /// What first-run setup offers — deliberately just the default. Onboarding is
    /// not the place to make this choice: it is where you get a working wallet with
    /// the model the app was tested against. Everything else is a Settings decision,
    /// made later, by someone who has seen their own hardware verdicts.
    static let onboardingOptions: [LocalAIModel] = [
        recommended,
    ]
}
