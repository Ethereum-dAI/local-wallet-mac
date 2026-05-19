import Foundation
import Testing
@testable import LocalLLM
import CLlamaBridge

private final class GenerateV2Accumulator {
    var text = ""
    var tokenCount = 0
    var cancelAfter: Int?
}

private let generateV2Callback: lllm_token_callback_v2 = { tokenPointer, userData in
    guard let tokenPointer, let userData else {
        return 0
    }

    let accumulator = Unmanaged<GenerateV2Accumulator>
        .fromOpaque(userData)
        .takeUnretainedValue()
    accumulator.tokenCount += 1
    accumulator.text += String(cString: tokenPointer)

    if let cancelAfter = accumulator.cancelAfter, accumulator.tokenCount >= cancelAfter {
        return 1
    }
    return 0
}

private func loadedRuntime() throws -> LlamaRuntime? {
    let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/LocalWallet/Models/gemma-4-E4B-it-Q4_K_M.gguf")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }

    let runtime = LlamaRuntime()
    try runtime.loadModel(at: url)
    return runtime
}

private func promptTemplate(_ text: String) -> String {
    "<|turn>user\n\(text)<turn|>\n<|turn>model\n"
}

private func samplerParams(
    maxTokens: Int32,
    temperature: Float = 0.2,
    seed: UInt32 = 42
) -> lllm_sampler_params {
    lllm_sampler_params(
        max_tokens: maxTokens,
        temperature: temperature,
        top_p: 0.95,
        top_k: 64,
        min_p: 0.05,
        repeat_penalty: 1.0,
        seed: seed
    )
}

private func generateV2(
    runtime: LlamaRuntime,
    prompt: String,
    params: lllm_sampler_params,
    grammar: String? = nil,
    stopSequence: String? = nil,
    cancelAfter: Int? = nil
) -> (produced: Int32, text: String, error: String) {
    let accumulator = GenerateV2Accumulator()
    accumulator.cancelAfter = cancelAfter

    var errorBuffer = [CChar](repeating: 0, count: 1024)
    let userData = Unmanaged.passUnretained(accumulator).toOpaque()

    let produced = errorBuffer.withUnsafeMutableBufferPointer { errorPointer in
        prompt.withCString { promptPointer in
            func callGenerate(
                grammarPointer: UnsafePointer<CChar>?,
                stopPointers: UnsafePointer<UnsafePointer<CChar>?>?
            ) -> Int32 {
                lllm_runtime_generate_v2(
                    runtime.bridgeHandle,
                    promptPointer,
                    params,
                    grammarPointer,
                    stopPointers,
                    generateV2Callback,
                    userData,
                    errorPointer.baseAddress,
                    Int32(errorPointer.count)
                )
            }

            func callWithStopPointers(grammarPointer: UnsafePointer<CChar>?) -> Int32 {
                guard let stopSequence else {
                    return callGenerate(grammarPointer: grammarPointer, stopPointers: nil)
                }

                return stopSequence.withCString { stopPointer in
                    var stopPointers: [UnsafePointer<CChar>?] = [stopPointer, nil]
                    return stopPointers.withUnsafeBufferPointer { buffer in
                        callGenerate(grammarPointer: grammarPointer, stopPointers: buffer.baseAddress)
                    }
                }
            }

            guard let grammar else {
                return callWithStopPointers(grammarPointer: nil)
            }

            return grammar.withCString { grammarPointer in
                callWithStopPointers(grammarPointer: grammarPointer)
            }
        }
    }

    return (produced, accumulator.text, String(cString: errorBuffer))
}

// All four GenerateV2 tests load the model and exercise llama.cpp's GPU
// decoder. swift-testing runs tests in parallel by default; on Apple Silicon
// running two LlamaRuntimes concurrently against Metal causes llama_decode
// to fail intermittently (return -4). Serialise this suite so only one runs
// at a time.
@Suite(.serialized) struct GenerateV2Suite {

@Test func generateV2ProducesNonEmptyOutput() async throws {
    guard let runtime = try loadedRuntime() else { return }
    defer { runtime.unload() }

    let result = generateV2(
        runtime: runtime,
        prompt: promptTemplate("Say hello in one short sentence."),
        params: samplerParams(maxTokens: 24, temperature: 0.2, seed: 42)
    )

    #expect(result.produced > 0)
    #expect(!result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
}

@Test func generateV2RespectsCancellationFromCallback() async throws {
    guard let runtime = try loadedRuntime() else { return }
    defer { runtime.unload() }

    let result = generateV2(
        runtime: runtime,
        prompt: promptTemplate("Write a short paragraph about local wallets."),
        params: samplerParams(maxTokens: 256, temperature: 0.2, seed: 42),
        cancelAfter: 5
    )

    #expect((5...7).contains(Int(result.produced)))
}

@Test func generateV2ConstrainsToGBNFGrammar() async throws {
    guard let runtime = try loadedRuntime() else { return }
    defer { runtime.unload() }

    let result = generateV2(
        runtime: runtime,
        prompt: promptTemplate("Answer with a short number sequence."),
        params: samplerParams(maxTokens: 16, temperature: 0.2, seed: 42),
        grammar: "root ::= [0-9 ]+"
    )

    #expect(result.produced > 0)
    #expect(result.text.range(of: #"^[0-9 ]+$"#, options: .regularExpression) != nil)
}

@Test func generateV2HonorsStopSequence() async throws {
    guard let runtime = try loadedRuntime() else { return }
    defer { runtime.unload() }

    let result = generateV2(
        runtime: runtime,
        prompt: promptTemplate("Continue this sequence in words: one two"),
        params: samplerParams(maxTokens: 64, temperature: 0.2, seed: 42),
        stopSequence: "three"
    )

    #expect(result.produced < 64)
    #expect(result.text.contains("three"))
}

} // end @Suite GenerateV2Suite
