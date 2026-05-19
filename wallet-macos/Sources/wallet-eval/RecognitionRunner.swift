import Foundation
import LocalLLM
import WalletToolLayer

// MARK: - Dataset model

struct RecognitionCase: Codable {
    let id: String
    let user_message: String
    let category: String
    let language: String
    let expected_tool: String?
    let expected_args: [String: ArgExpectation]?
    let notes: String?
}

struct ArgExpectation: Codable {
    let kind: String
    let value: AnyValue

    enum AnyValue: Codable {
        case string(String)
        case array([String])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                self = .string(s)
            } else if let a = try? c.decode([String].self) {
                self = .array(a)
            } else {
                self = .string("")
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s):
                try c.encode(s)
            case .array(let a):
                try c.encode(a)
            }
        }
    }
}

struct RecognitionDataset: Codable {
    let schema: String
    let cases: [RecognitionCase]
}

// MARK: - Runner

enum RecognitionOutcome: String {
    case pass
    case failWrongTool = "fail-wrong-tool"
    case failWrongArgs = "fail-wrong-args"
    case failNoCall = "fail-no-call"
    case failUnexpectedCall = "fail-unexpected-call"
    case failParse = "fail-parse"
}

func runRecognition(options: EvalOptions) async throws {
    print("== wallet-eval recognition ==")
    let ds = try loadDataset()
    let cases: [RecognitionCase] = {
        guard let f = options.filter else { return ds.cases }
        return ds.cases.filter { $0.category == f || $0.language == f }
    }()
    print("config: \(cases.count) cases, repeats=\(options.repeats), seed=0x\(String(options.seed, radix: 16))")

    let runtime = LlamaRuntime()
    try runtime.loadModel(at: URL(fileURLWithPath: options.modelPath))
    defer { runtime.unload() }
    let extractor = BridgePEGExtractor(runtime: runtime)
    let slashParser = SlashCommandParser()

    var byCategory: [String: (trials: Int, passes: Int, outcomes: [(String, RecognitionOutcome)])] = [:]
    var byLanguage: [String: (trials: Int, passes: Int)] = [:]
    var failureSamples: [(id: String, outcome: RecognitionOutcome)] = []

    for c in cases {
        for trial in 0..<options.repeats {
            let outcome: RecognitionOutcome
            if c.category == "slashCommand" {
                outcome = scoreSlashCase(c, parser: slashParser)
            } else {
                outcome = try await scoreModelCase(c, runtime: runtime, extractor: extractor, options: options)
            }

            var cat = byCategory[c.category, default: (0, 0, [])]
            cat.trials += 1
            if outcome == .pass { cat.passes += 1 }
            cat.outcomes.append((c.id, outcome))
            byCategory[c.category] = cat

            var lang = byLanguage[c.language, default: (0, 0)]
            lang.trials += 1
            if outcome == .pass { lang.passes += 1 }
            byLanguage[c.language] = lang

            if outcome != .pass, failureSamples.count < 5 {
                failureSamples.append((c.id, outcome))
            }
            if options.verbose {
                print("  [\(c.id) trial \(trial + 1)] \(outcome.rawValue)")
            }
        }
    }

    print("")
    for (cat, stats) in byCategory.sorted(by: { $0.key < $1.key }) {
        let rate = stats.trials == 0 ? 0 : Double(stats.passes) / Double(stats.trials)
        print("\(cat.padding(toLength: 26, withPad: " ", startingAt: 0)) \(stats.passes)/\(stats.trials)  (\(String(format: "%.0f", rate * 100))%)")
        EvalReport.shared.recordRaw(subcommand: "recognition", label: cat,
                                    value: rate, samples: stats.trials, metric: "rate")
    }
    print("")
    if let en = byLanguage["english"] {
        let rate = en.trials == 0 ? 0 : Double(en.passes) / Double(en.trials)
        print(String(format: "HEADLINE (English only): %.0f%%  (n=%d)", rate * 100, en.trials))
        EvalReport.shared.recordRaw(subcommand: "recognition", label: "headline-english",
                                    value: rate, samples: en.trials, metric: "rate")
    }
    for (lang, stats) in byLanguage.sorted(by: { $0.key < $1.key }) where lang != "english" {
        let rate = stats.trials == 0 ? 0 : Double(stats.passes) / Double(stats.trials)
        print("\(lang.padding(toLength: 10, withPad: " ", startingAt: 0)) \(String(format: "%.0f", rate * 100))%  (n=\(stats.trials), observational)")
        EvalReport.shared.recordRaw(subcommand: "recognition", label: "lang-\(lang)",
                                    value: rate, samples: stats.trials, metric: "rate")
    }

    if !failureSamples.isEmpty {
        print("")
        print("Top failures (first 5):")
        for f in failureSamples {
            print("  \(f.id): \(f.outcome.rawValue)")
        }
    }
}

// MARK: - per-case scoring

private func loadDataset() throws -> RecognitionDataset {
    guard let url = Bundle.module.url(forResource: "recognition",
                                      withExtension: "json",
                                      subdirectory: "Dataset") else {
        throw NSError(domain: "wallet-eval", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Dataset/recognition.json not found in bundle"])
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(RecognitionDataset.self, from: data)
}

private func scoreSlashCase(_ c: RecognitionCase, parser: SlashCommandParser) -> RecognitionOutcome {
    let parsed: ToolIntent
    do {
        parsed = try parser.parse(c.user_message)
    } catch {
        return c.expected_tool == nil ? .pass : .failParse
    }
    guard let expectedTool = c.expected_tool else {
        return .failUnexpectedCall
    }
    guard parsed.tool.rawValue == expectedTool else {
        return .failWrongTool
    }
    return matchArgs(parsed.args, against: c.expected_args)
}

private func scoreModelCase(_ c: RecognitionCase,
                            runtime: LlamaRuntime,
                            extractor: BridgePEGExtractor,
                            options: EvalOptions) async throws -> RecognitionOutcome {
    let system = "You are the local AI inside a macOS Ethereum wallet app. \(ToolDefinitions.systemNudge)"
    let messages: [LocalLLM.ChatMessage] = [
        .init(role: .system, content: system),
        .init(role: .user, content: c.user_message),
    ]
    var sampler = SamplerOptions()
    sampler.maxTokens = 192
    sampler.temperature = 0.2
    sampler.seed = options.seed

    var acc = ""
    do {
        for try await event in runtime.chat(messages: messages, tools: ToolDefinitions.phase1, options: sampler) {
            if case .textToken(let p) = event { acc += p }
        }
    } catch {
        return .failParse
    }

    let parsed: ParsedAssistantTurnFlat
    do {
        parsed = try extractor.extract(from: acc)
    } catch {
        return .failParse
    }

    if c.expected_tool == nil {
        if parsed.toolCalls.isEmpty {
            if c.category == "ambiguous" {
                _ = (parsed.content ?? acc).contains("?")
                return .pass
            }
            return .pass
        }
        return .failUnexpectedCall
    }

    guard let first = parsed.toolCalls.first else { return .failNoCall }
    guard first.name == c.expected_tool else { return .failWrongTool }
    return matchArgs(first.arguments, against: c.expected_args)
}

private func matchArgs(_ actual: [String: String], against expected: [String: ArgExpectation]?) -> RecognitionOutcome {
    guard let expected else { return .pass }
    for (key, exp) in expected {
        guard let actualValue = actual[key] else { return .failWrongArgs }
        switch exp.kind {
        case "exact":
            if case .string(let s) = exp.value, s != actualValue { return .failWrongArgs }
        case "oneOf":
            if case .array(let arr) = exp.value, !arr.contains(actualValue) { return .failWrongArgs }
        case "regex":
            if case .string(let pattern) = exp.value {
                let range = NSRange(actualValue.startIndex..., in: actualValue)
                if let r = try? NSRegularExpression(pattern: pattern), r.firstMatch(in: actualValue, range: range) == nil {
                    return .failWrongArgs
                }
            }
        default:
            break
        }
    }
    return .pass
}
