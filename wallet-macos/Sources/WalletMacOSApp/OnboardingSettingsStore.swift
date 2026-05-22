import Foundation

final class OnboardingSettingsStore {
    private enum Keys {
        static let completed = "com.localwallet.demo.onboarding.completed"
        static let rpcURL = "com.localwallet.demo.onboarding.rpc-url"
        static let archiveNodeURL = "com.localwallet.demo.onboarding.archive-node-url"
        static let selectedModelID = "com.localwallet.demo.onboarding.selected-model-id"
        static let installedModelID = "com.localwallet.demo.onboarding.installed-model-id"
        static let installedModelPath = "com.localwallet.demo.onboarding.installed-model-path"
        static let voiceInputEnabled = "com.localwallet.demo.onboarding.voice-input-enabled"
        static let bundlerKeyRef = "com.localwallet.demo.onboarding.bundler-key-ref"
        static let bundlerAddress = "com.localwallet.demo.onboarding.bundler-address"
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

    var voiceInputEnabled: Bool {
        get {
            defaults.bool(forKey: Keys.voiceInputEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.voiceInputEnabled)
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
        sha256: "90ce98129eb3e8cc57e62433d500c97c624b1e3af1fcc85dd3b55ad7e0313e9f"
    )

    static let available: [LocalAIModel] = [
        recommended,
    ]
}

struct LocalMmproj: Identifiable, Equatable {
    let id: String
    let artifactURL: URL
    let artifactFileName: String
    let sha256: String
    let approximateBytes: Int64

    static let gemma4Audio = LocalMmproj(
        id: "ggml-org/gemma-4-E4B-mmproj-bf16",
        artifactURL: URL(string: "https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF/resolve/main/mmproj-gemma-4-E4B-it-bf16.gguf?download=true")!,
        artifactFileName: "mmproj-gemma-4-E4B-it-bf16.gguf",
        sha256: "4c199e460410ba219a8c63930a7121154e1c70cdf66044858f767966332e5a54",
        approximateBytes: 991_551_968
    )
}
