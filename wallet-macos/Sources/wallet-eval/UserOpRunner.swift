import Foundation
import LocalLLM
import WalletToolLayer

// MARK: - Task C: executor round-trip — what fraction of requests become a
// signable UserOp?
//
// Drives the FULL pipeline a real request takes inside the app — model ->
// BridgePEGExtractor -> the same guards ChatDashboardView applies
// (WalletTokenRegistry, EtherAmountParser, recipient shape, ENS) ->
// UserOperationBuilder's execute() encoding — and records the stage at which
// each case succeeds or fails.
//
// PortedAppEncoding.swift in this same target explains why this file uses
// PORTED copies of WalletTokenRegistry/EtherAmountParser/UserOperationBuilder
// rather than `import WalletMacOSApp` directly (a real, verified SwiftPM
// limitation — read that file's header for the full story). The short
// version: this is not product code the app also runs; it is a copy kept in
// sync by hand, and that is a real limitation of this eval, not a detail.
//
// TWO STUBS, both load-bearing and named loudly per the task brief:
//
//   1. ENS resolution (`ENSFixture`) — normally `localwallet_resolveName` on
//      the daemon. Stubbed with exactly the one fixture named in the brief:
//      vitalik.eth -> 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045. Any other
//      ENS-shaped recipient the model invents fails stage 4
//      ("ens-unresolvable"), which is honest: the harness has no daemon to
//      resolve it either.
//
//   2. The wallet/swap-quote fixture (`SwapFixtures`) — a swap's
//      `SwapExecutionRequest` needs a `SwapQuote`, which in the real app
//      comes from a live `localwallet_quoteSwap` RPC (Uniswap V3 on-chain
//      quoting). There is no network path here, so `SwapFixtures.quote`
//      fabricates one deterministically (real mainnet/Sepolia Uniswap V3
//      router addresses — copied from local-wallet-daemon's
//      quote_swap.rs — a fixed 0.3% single-hop path, zero
//      amountOutMinimum, requiresApproval always false). This means a swap
//      case's stage-6 "correct" check only proves the model's parsed
//      (from_token, to_token, amount, amount_side) match gold — NOT that
//      the quote numbers or slippage are realistic.
//
// Both stubs are named again in task-C-report.md.

// MARK: - Fixtures

/// The one ENS mapping the brief specifies. Deliberately not extended — any
/// other name is meant to fail, honestly, at stage 4.
enum ENSFixture {
    static let known: [String: String] = [
        "vitalik.eth": "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
    ]
}

/// Fixed mainnet chain id (the dataset's `chainId` is always "1" — see
/// scripts/convert-userop-eval-dataset.py's audit output) and a fixture
/// self-address for swap's "send back to the account" recipient.
enum FixtureWallet {
    static let chainID: UInt64 = 1
    static let address = "0x1111111111111111111111111111111111111111"
}

/// Deterministic swap-quote fabrication (see file header, stub #2). Router
/// addresses are the real mainnet and Sepolia Uniswap V3 deployments the
/// daemon itself uses (local-wallet-daemon/crates/wallet-node/src/handlers/
/// wallet/quote_swap.rs), copied here as literals since that crate isn't
/// reachable from a Swift target.
enum SwapFixtures {
    private static let mainnetRouter = "0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45"
    private static let sepoliaRouter = "0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E"
    private static let fixedFeeTier = 3000

    static func quote(
        chainID: UInt64,
        fromToken: WalletToken,
        toToken: WalletToken,
        amountIn: Data
    ) throws -> SwapQuote {
        let router = chainID == 1 ? mainnetRouter : sepoliaRouter
        guard let wrapped = WalletTokenRegistry.wrappedNativeToken(on: chainID)?.contractAddress else {
            throw IntentBuildError.swapQuoteFixtureFailed
        }
        let tokenInAddress = fromToken.contractAddress ?? wrapped
        let tokenOutAddress = toToken.contractAddress ?? wrapped
        let path = try encodeSingleHopPath(tokenIn: tokenInAddress, fee: fixedFeeTier, tokenOut: tokenOutAddress)

        return SwapQuote(
            router: router,
            path: path,
            amountIn: amountIn,
            amountOutMinimum: Data(repeating: 0, count: 32),
            requiresApproval: false
        )
    }

    private static func encodeSingleHopPath(tokenIn: String, fee: Int, tokenOut: String) throws -> Data {
        let inData = try Data(hexString: tokenIn)
        let outData = try Data(hexString: tokenOut)
        guard inData.count == 20, outData.count == 20 else {
            throw IntentBuildError.swapQuoteFixtureFailed
        }
        let f = UInt32(fee)
        let feeBytes = Data([UInt8((f >> 16) & 0xff), UInt8((f >> 8) & 0xff), UInt8(f & 0xff)])
        return inData + feeBytes + outData
    }
}

// MARK: - Stage-4 guard replication
//
// Deliberately mirrors ChatDashboardView.transferRequest / transferTransaction
// Intent / swapRequest / swapTransactionIntent (same file, ~lines 2228-2320
// and 3789-3923 at the time of writing) field-for-field so a pass here means
// the app's real guards would also pass. Kept here (not ported into
// PortedAppEncoding.swift) because it composes the ENS stub in place of a
// live `resolveName` RPC, which is eval-specific, not app logic.

enum IntentBuildError: Error, CustomStringConvertible {
    case unsupportedToken
    case missingOrAllAmount
    case amountParseFailed
    case missingRecipient
    case invalidRecipientShape
    case ensUnresolvable(String)
    case unsupportedSwapToken
    case sameSwapToken
    case unsupportedSwapAmountSide
    case toolNotTransactionIntent(String)
    case swapQuoteFixtureFailed

    var description: String {
        switch self {
        case .unsupportedToken: return "unsupported-token"
        case .missingOrAllAmount: return "missing-or-all-amount"
        case .amountParseFailed: return "amount-parse-failed"
        case .missingRecipient: return "missing-recipient"
        case .invalidRecipientShape: return "invalid-recipient-shape"
        case .ensUnresolvable(let name): return "ens-unresolvable(\(name))"
        case .unsupportedSwapToken: return "unsupported-swap-token"
        case .sameSwapToken: return "same-swap-token"
        case .unsupportedSwapAmountSide: return "unsupported-swap-amount-side"
        case .toolNotTransactionIntent(let name): return "tool-not-transaction-intent(\(name))"
        case .swapQuoteFixtureFailed: return "swap-quote-fixture-failed"
        }
    }
}

func buildTransactionIntent(
    toolName: String,
    args: [String: String],
    chainID: UInt64
) throws -> TransactionIntent {
    switch toolName {
    case "transfer":
        guard let token = WalletTokenRegistry.token(matching: args["token"], on: chainID) else {
            throw IntentBuildError.unsupportedToken
        }
        guard let rawAmount = args["amount"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawAmount.isEmpty, rawAmount.lowercased() != "all"
        else {
            throw IntentBuildError.missingOrAllAmount
        }
        _ = try parseAmountOrThrow(rawAmount, decimals: token.decimals)

        guard let rawRecipient = args["to"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawRecipient.isEmpty
        else {
            throw IntentBuildError.missingRecipient
        }

        let recipient: String
        if let bytes = try? Data(hexString: rawRecipient), bytes.count == 20 {
            recipient = "0x" + bytes.hexEncodedString
        } else if rawRecipient.contains(".") {
            guard let resolved = ENSFixture.known[rawRecipient.lowercased()] else {
                throw IntentBuildError.ensUnresolvable(rawRecipient)
            }
            recipient = resolved
        } else {
            throw IntentBuildError.invalidRecipientShape
        }

        return token.isNative
            ? .nativeTransfer(recipient: recipient, amountETH: rawAmount)
            : .erc20Transfer(token: token, recipient: recipient, amount: rawAmount)

    case "swap":
        guard (args["amount_side"] ?? "input").caseInsensitiveCompare("input") == .orderedSame else {
            throw IntentBuildError.unsupportedSwapAmountSide
        }
        guard let fromToken = WalletTokenRegistry.token(matching: args["from_token"], on: chainID),
              let toToken = WalletTokenRegistry.token(matching: args["to_token"], on: chainID)
        else {
            throw IntentBuildError.unsupportedSwapToken
        }
        guard fromToken.id != toToken.id else {
            throw IntentBuildError.sameSwapToken
        }
        guard let rawAmount = args["amount"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawAmount.isEmpty, rawAmount.lowercased() != "all"
        else {
            throw IntentBuildError.missingOrAllAmount
        }
        let amountIn = try parseAmountOrThrow(rawAmount, decimals: fromToken.decimals)
        let quote = try SwapFixtures.quote(chainID: chainID, fromToken: fromToken, toToken: toToken, amountIn: amountIn)
        let request = SwapExecutionRequest(
            quote: quote,
            recipient: FixtureWallet.address,
            tokenInIsNative: fromToken.isNative,
            tokenOutIsNative: toToken.isNative
        )
        return .exactInputSwap(request)

    default:
        // Some registered tools are handled outside the ordinary transaction
        // draft path. Fail closed instead of fabricating a transaction intent.
        throw IntentBuildError.toolNotTransactionIntent(toolName)
    }
}

private func parseAmountOrThrow(_ raw: String, decimals: Int) throws -> Data {
    do {
        return try EtherAmountParser.units(fromDecimalString: raw, decimals: decimals)
    } catch {
        throw IntentBuildError.amountParseFailed
    }
}

// MARK: - Per-case pipeline

enum UserOpFunnelStage: Int {
    case none = 0
    case generate = 1
    case parse = 2
    case tool = 3
    case intent = 4
    case build = 5
    case correct = 6
}

struct UserOpCaseResult {
    let id: String
    let category: String
    let stageReached: UserOpFunnelStage
    /// True when this case's contract was "emit no tool call". Abstain cases do
    /// not traverse the build funnel, so they are tallied and reported apart
    /// from it rather than being mixed into stage counts they cannot reach.
    var wasAbstain: Bool = false
    let failureDetail: String?
    /// Non-nil when the harness's OWN gold-side reconstruction failed to
    /// build — a bug in the fixture/stub, not a model failure. Kept separate
    /// from the funnel per the "unclassified, don't force it" requirement:
    /// when this is set, the case is excluded from the stage funnel entirely
    /// (not forced into a pass or a fail) and reported in its own bucket.
    let goldFixtureIssue: String?
    /// Always populated (not gated by --verbose) for generate/parse failures
    /// so a "died at parse" case can be root-caused (truncation vs. a
    /// malformed DSL block vs. a <think>-block interaction) without a
    /// separate re-run. Tail of the raw accumulated model output, capped.
    let rawOutputTail: String?

    var isUnclassified: Bool { goldFixtureIssue != nil }
}

private func buildMessages(for c: UserOpDatasetCase) -> [LocalLLM.ChatMessage] {
    let system = ToolDefinitions.appSystemPrompt
    var messages: [LocalLLM.ChatMessage] = [.init(role: .system, content: system)]
    for turn in c.turns {
        let role: LocalLLM.ChatMessage.Role = turn.role == "assistant" ? .assistant : .user
        messages.append(.init(role: role, content: turn.content))
    }
    return messages
}

func evaluateUserOpCase(
    _ c: UserOpDatasetCase,
    runtime: LlamaRuntime,
    extractor: BridgePEGExtractor,
    options: EvalOptions
) async -> UserOpCaseResult {
    let chainID = FixtureWallet.chainID
    let builder = UserOperationBuilder()

    // Gold reconstruction (harness self-check, not part of the model funnel).
    // Skipped for abstain cases: their gold is the ABSENCE of a call, so there is
    // no intent to rebuild. Running it anyway threw on the empty tool name and
    // marked every such case `unclassified`, which silently dropped all 88 of
    // them out of the denominator — the funnel reported 0 cases, not 0%.
    let goldArgs = c.expectedCalls.first ?? [:]
    let goldTool = goldArgs["tool"] ?? ""
    var goldCallData: Data?
    var goldFixtureIssue: String?
    if !c.expectsAbstention {
        do {
            let goldIntent = try buildTransactionIntent(toolName: goldTool, args: goldArgs, chainID: chainID)
            goldCallData = try builder.callData(for: goldIntent)
        } catch {
            goldFixtureIssue = "gold-build-failed(\(goldTool)): \(error)"
        }
    }

    // Stage 1: generate
    var sampler = SamplerOptions()
    // 512, not the 192 inherited from RecognitionRunner/RoundTripRunner. Those
    // runners predate the app-contract fine-tunes, which narrate their
    // arithmetic in a <think> trace before emitting the call ("those are
    // thousands separators, so read the digits: 987654.32"). At 192 the trace
    // consumed the budget and the DSL block was cut off mid-object — no closing
    // brace, no <tool_call|> terminator — which neither the upstream PEG parse
    // nor Gemma4FallbackParser can extract from, so the case was recorded as
    // "no tool call". That accounted for 9 of the new model's 10 stage-2
    // failures, with the reasoning correct in every one: a harness budget
    // artifact scored as a model defect, understating the funnel by ~2.6pt.
    sampler.maxTokens = 512
    sampler.temperature = 0.2
    sampler.seed = options.seed
    let messages = buildMessages(for: c)

    var acc = ""
    do {
        for try await event in runtime.chat(messages: messages, tools: ToolDefinitions.phase1, options: sampler) {
            if case .textToken(let p) = event { acc += p }
        }
    } catch {
        return UserOpCaseResult(id: c.id, category: c.category, stageReached: .none,
                                 failureDetail: "generate-threw: \(error)", goldFixtureIssue: goldFixtureIssue,
                                 rawOutputTail: tailOf(acc))
    }
    guard !acc.isEmpty else {
        return UserOpCaseResult(id: c.id, category: c.category, stageReached: .none,
                                 failureDetail: "empty-output", goldFixtureIssue: goldFixtureIssue,
                                 rawOutputTail: nil)
    }

    // Stage 2: parse
    let parsed: ParsedAssistantTurnFlat
    do {
        parsed = try extractor.extract(from: acc)
    } catch {
        return UserOpCaseResult(id: c.id, category: c.category, stageReached: .generate,
                                 failureDetail: "parse-threw: \(error)", goldFixtureIssue: goldFixtureIssue,
                                 rawOutputTail: tailOf(acc))
    }
    // Abstain cases invert the contract: a safety refusal, a missing-field
    // clarification, or an out-of-scope protocol request is *correct* only when
    // no tool call is emitted. Scored here, right after parsing, because every
    // later stage presumes a call exists.
    if c.expectsAbstention {
        if let stray = parsed.toolCalls.first {
            return UserOpCaseResult(id: c.id, category: c.category, stageReached: .parse,
                                     wasAbstain: true,
                                     failureDetail: "should-have-abstained:\(stray.name)",
                                     goldFixtureIssue: goldFixtureIssue,
                                     rawOutputTail: tailOf(acc))
        }
        return UserOpCaseResult(id: c.id, category: c.category, stageReached: .correct,
                                 wasAbstain: true,
                                 failureDetail: nil, goldFixtureIssue: goldFixtureIssue,
                                 rawOutputTail: nil)
    }

    guard let call = parsed.toolCalls.first else {
        return UserOpCaseResult(id: c.id, category: c.category, stageReached: .generate,
                                 failureDetail: "no-tool-call", goldFixtureIssue: goldFixtureIssue,
                                 rawOutputTail: tailOf(acc))
    }

    // Stage 3: tool
    let registeredNames = Set(ToolDefinitions.phase1.map(\.name))
    guard registeredNames.contains(call.name) else {
        return UserOpCaseResult(id: c.id, category: c.category, stageReached: .parse,
                                 failureDetail: "unregistered-tool:\(call.name)", goldFixtureIssue: goldFixtureIssue,
                                 rawOutputTail: nil)
    }

    // Stage 4: intent
    let intent: TransactionIntent
    do {
        intent = try buildTransactionIntent(toolName: call.name, args: call.arguments, chainID: chainID)
    } catch {
        return UserOpCaseResult(id: c.id, category: c.category, stageReached: .tool,
                                 failureDetail: "intent:\(error)", goldFixtureIssue: goldFixtureIssue,
                                 rawOutputTail: nil)
    }

    // Stage 5: build
    let modelCallData: Data
    do {
        modelCallData = try builder.callData(for: intent)
    } catch {
        return UserOpCaseResult(id: c.id, category: c.category, stageReached: .intent,
                                 failureDetail: "builddraft-threw: \(error)", goldFixtureIssue: goldFixtureIssue,
                                 rawOutputTail: nil)
    }

    // Stage 6: correct
    guard let goldCallData else {
        // We built a UserOp fine, but the harness's own gold path failed, so
        // there is nothing sound to compare against. Reported separately.
        return UserOpCaseResult(id: c.id, category: c.category, stageReached: .build,
                                 failureDetail: "gold-comparison-unavailable", goldFixtureIssue: goldFixtureIssue,
                                 rawOutputTail: nil)
    }
    if modelCallData == goldCallData {
        return UserOpCaseResult(id: c.id, category: c.category, stageReached: .correct,
                                 failureDetail: nil, goldFixtureIssue: nil, rawOutputTail: nil)
    } else {
        return UserOpCaseResult(id: c.id, category: c.category, stageReached: .build,
                                 failureDetail: "calldata-mismatch", goldFixtureIssue: nil, rawOutputTail: nil)
    }
}

/// Last ~280 characters of the raw model output, for root-causing a "died at
/// parse" case (truncation vs. a malformed DSL block vs. an unterminated
/// <think> block) without a separate re-run.
private func tailOf(_ s: String, maxLength: Int = 280) -> String {
    if s.count <= maxLength { return s }
    return "…" + String(s.suffix(maxLength))
}

// MARK: - Top-level runner

func runUserOp(options: EvalOptions) async throws {
    print("== wallet-eval userop ==")
    let dataset = try loadUserOpDataset()
    let cases: [UserOpDatasetCase] = {
        guard let f = options.filter else { return dataset.cases }
        return dataset.cases.filter { $0.category == f }
    }()
    print("config: \(cases.count) cases, repeats=\(options.repeats), seed=0x\(String(options.seed, radix: 16)), model=\(options.modelPath)")

    let runtime = LlamaRuntime()
    try runtime.loadModel(at: URL(fileURLWithPath: options.modelPath))
    defer { runtime.unload() }
    let extractor = BridgePEGExtractor(runtime: runtime)

    var stageCounts: [UserOpFunnelStage: Int] = [:]
    var failureReasons: [String: Int] = [:]
    var goldIssues: [String] = []
    var parseFailureSamples: [(id: String, category: String, detail: String, tail: String)] = []
    var totalTrials = 0
    var classifiedTrials = 0
    // Abstain cases are counted apart from the build funnel: their contract is
    // "emit no tool call", so they can never reach stage 6 and would otherwise
    // drag the signable-UserOp headline down for doing the right thing.
    var abstainTrials = 0
    var abstainCorrect = 0

    for c in cases {
        for trial in 0..<options.repeats {
            totalTrials += 1
            let result = await evaluateUserOpCase(c, runtime: runtime, extractor: extractor, options: options)
            if result.isUnclassified {
                goldIssues.append("\(result.id): \(result.goldFixtureIssue ?? "")")
            } else {
                if result.wasAbstain {
                    abstainTrials += 1
                    if result.stageReached == .correct { abstainCorrect += 1 }
                    if let detail = result.failureDetail {
                        failureReasons[detail, default: 0] += 1
                    }
                    continue
                }
                classifiedTrials += 1
                stageCounts[result.stageReached, default: 0] += 1
                if let detail = result.failureDetail {
                    failureReasons[detail, default: 0] += 1
                }
                if result.stageReached == .none || result.stageReached == .generate,
                   let tail = result.rawOutputTail {
                    parseFailureSamples.append((result.id, result.category, result.failureDetail ?? "?", tail))
                }
            }
            if options.verbose {
                print("  [\(result.id) trial \(trial + 1)] stage=\(result.stageReached.rawValue) unclassified=\(result.isUnclassified) \(result.failureDetail ?? "OK")")
            }
        }
    }

    func count(_ s: UserOpFunnelStage) -> Int { stageCounts[s] ?? 0 }
    let diedAtGenerate = count(.none)
    let diedAtParse = count(.generate)
    let diedAtTool = count(.parse)
    let diedAtIntent = count(.tool)
    let diedAtBuild = count(.intent)
    let diedAtCorrect = count(.build) // reached build (stage 5) but calldata mismatched vs. gold
    let succeeded = count(.correct)
    let denom = max(classifiedTrials, 1)

    print("")
    print("Per-stage funnel (of \(classifiedTrials) classified trials; \(totalTrials) total, \(goldIssues.count) unclassified — see below):")
    print(String(format: "  died at generate (no/empty output):        %4d (%.0f%%)", diedAtGenerate, 100.0 * Double(diedAtGenerate) / Double(denom)))
    print(String(format: "  died at parse (no tool call / parse err):  %4d (%.0f%%)", diedAtParse, 100.0 * Double(diedAtParse) / Double(denom)))
    print(String(format: "  died at tool (unregistered tool name):     %4d (%.0f%%)", diedAtTool, 100.0 * Double(diedAtTool) / Double(denom)))
    print(String(format: "  died at intent (guards: token/amount/ENS): %4d (%.0f%%)", diedAtIntent, 100.0 * Double(diedAtIntent) / Double(denom)))
    print(String(format: "  died at build (encode threw):              %4d (%.0f%%)", diedAtBuild, 100.0 * Double(diedAtBuild) / Double(denom)))
    print(String(format: "  reached build, failed correct (mismatch):  %4d (%.0f%%)", diedAtCorrect, 100.0 * Double(diedAtCorrect) / Double(denom)))
    print(String(format: "  HEADLINE reached stage 6 (signable UserOp, correct): %4d (%.1f%%)", succeeded, 100.0 * Double(succeeded) / Double(denom)))

    EvalReport.shared.recordRaw(subcommand: "userop", label: "died-at-generate", value: Double(diedAtGenerate) / Double(denom), samples: classifiedTrials, metric: "rate")
    EvalReport.shared.recordRaw(subcommand: "userop", label: "died-at-parse", value: Double(diedAtParse) / Double(denom), samples: classifiedTrials, metric: "rate")
    EvalReport.shared.recordRaw(subcommand: "userop", label: "died-at-tool", value: Double(diedAtTool) / Double(denom), samples: classifiedTrials, metric: "rate")
    EvalReport.shared.recordRaw(subcommand: "userop", label: "died-at-intent", value: Double(diedAtIntent) / Double(denom), samples: classifiedTrials, metric: "rate")
    EvalReport.shared.recordRaw(subcommand: "userop", label: "died-at-build", value: Double(diedAtBuild) / Double(denom), samples: classifiedTrials, metric: "rate")
    EvalReport.shared.recordRaw(subcommand: "userop", label: "died-at-correct", value: Double(diedAtCorrect) / Double(denom), samples: classifiedTrials, metric: "rate")
    EvalReport.shared.recordRaw(subcommand: "userop", label: "headline-signable-userop", value: Double(succeeded) / Double(denom), samples: classifiedTrials, metric: "rate")

    if abstainTrials > 0 {
        let rate = 100.0 * Double(abstainCorrect) / Double(abstainTrials)
        print("")
        print("Abstention (safety refusals + missing-field clarifications) — correct = NO tool call:")
        print(String(format: "  HEADLINE abstained correctly:              %4d/%d (%.1f%%)",
                     abstainCorrect, abstainTrials, rate))
        EvalReport.shared.recordRaw(subcommand: "userop", label: "headline-abstention",
                                    value: Double(abstainCorrect) / Double(abstainTrials),
                                    samples: abstainTrials, metric: "rate")
        let overall = Double(succeeded + abstainCorrect) / Double(max(classifiedTrials + abstainTrials, 1))
        print(String(format: "  combined (UserOp + abstention):            %4d/%d (%.1f%%)",
                     succeeded + abstainCorrect, classifiedTrials + abstainTrials, 100.0 * overall))
        EvalReport.shared.recordRaw(subcommand: "userop", label: "headline-combined",
                                    value: overall, samples: classifiedTrials + abstainTrials,
                                    metric: "rate")
    }

    print("")
    print("Top failure reasons:")
    for (reason, n) in failureReasons.sorted(by: { $0.value > $1.value }).prefix(15) {
        print(String(format: "  %4d  %@", n, reason))
    }

    if !goldIssues.isEmpty {
        print("")
        print("UNCLASSIFIED: gold-side reconstruction failed for \(goldIssues.count) trial(s) — a harness/stub bug, not a model failure. Excluded entirely from the funnel above, not forced into any stage:")
        for issue in goldIssues.prefix(10) {
            print("  \(issue)")
        }
    }

    if !parseFailureSamples.isEmpty {
        print("")
        print("Died-at-generate/parse raw output tails (\(parseFailureSamples.count) total, showing up to 20) — for root-causing truncation vs. a malformed DSL block vs. a <think>-block interaction:")
        for sample in parseFailureSamples.prefix(20) {
            let looksTruncated = !sample.tail.contains("<tool_call|>") && !sample.tail.hasSuffix(".") && !sample.tail.hasSuffix("?")
            print("  [\(sample.id) / \(sample.category)] \(sample.detail) truncated-looking=\(looksTruncated)")
            print("    tail: \(sample.tail.replacingOccurrences(of: "\n", with: "\\n"))")
        }
    }
}
