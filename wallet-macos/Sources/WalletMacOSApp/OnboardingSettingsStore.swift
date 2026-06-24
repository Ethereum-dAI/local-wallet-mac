import Foundation

final class OnboardingSettingsStore {
    private enum Keys {
        static let completed = "com.localwallet.demo.onboarding.completed"
        static let rpcURL = "com.localwallet.demo.onboarding.rpc-url"
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

    var consensusRPCURL: String {
        get {
            defaults.string(forKey: Keys.consensusRPCURL)
                ?? ChainConfiguration.ethereumSepolia.consensusRPCURL.absoluteString
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

    var bundlerKeyRef: String? {
        get {
            defaults.string(forKey: Keys.bundlerKeyRef)
        }
        set {
            defaults.set(newValue, forKey: Keys.bundlerKeyRef)
        }
    }

    var bundlerAddress: String? {
        get {
            defaults.string(forKey: Keys.bundlerAddress)
        }
        set {
            defaults.set(newValue, forKey: Keys.bundlerAddress)
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
    let maxContextTokens: Int

    static let recommended = LocalAIModel(
        id: "google/gemma-4-E4B-it",
        name: "Gemma 4 E4B",
        size: "5.34 GB",
        detail: "Instruction-tuned Gemma 4 E4B, downloaded as a Q4_K_M GGUF for local llama.cpp inference.",
        tag: "GGUF",
        systemImage: "sparkles",
        artifactRepo: "ggml-org/gemma-4-E4B-it-GGUF",
        artifactFileName: "gemma-4-E4B-it-Q4_K_M.gguf",
        artifactURL: URL(string: "https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_K_M.gguf?download=true")!,
        sha256: "90ce98129eb3e8cc57e62433d500c97c624b1e3af1fcc85dd3b55ad7e0313e9f",
        // Trained context for Gemma 4 E4B. Confirm against the model card; presets are
        // filtered to this value. Conservative cap keeps the KV cache bounded.
        maxContextTokens: 32768
    )

    static let available: [LocalAIModel] = [
        recommended,
    ]
}
