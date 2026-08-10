import Foundation
@testable import LocalLLM

/// The GGUF fixture the model-backed tests need. Absent on CI, where those
/// tests self-skip rather than fail.
enum TestModel {
    static let url: URL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/LocalWallet/Models/gemma-4-E4B-it-Q4_0.gguf")

    static var isPresent: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

/// `contextSize` is 2048 rather than `LocalLLMConfiguration`'s 4096 default
/// because the bridge sets `n_batch = n_ctx` (`CLlamaBridge.cpp`), so the
/// default doubles both the KV cache and the Metal compute buffer to no
/// purpose — no prompt in this suite comes near 2048 tokens.
///
/// `maxTokens` and `temperature` reproduce what `gemmaSmokeTestWhenModelExists`
/// passed when it built its own runtime. It is the only test that samples via
/// the configuration; every other generating test supplies explicit
/// `SamplerOptions` or `lllm_sampler_params`, so those two values affect just
/// that one test.
private let sharedConfiguration = LocalLLMConfiguration(
    contextSize: 2048,
    gpuLayers: 99,
    threads: 0,
    maxTokens: 24,
    temperature: 0.2
)

private enum SharedRuntimeState {
    case modelAbsent
    case loaded(LlamaRuntime)
    case loadFailed(String)
}

/// One `LlamaRuntime` for the whole test target, loaded on first use.
///
/// Each test file used to build its own, so a single `swift test` loaded the
/// 4.59 GB model up to nine times. Those loads do not share their weights,
/// which put peak memory at ~54 GB against ~4.7 GB for one runtime and made the
/// suite fail non-deterministically under swift-testing's default parallelism —
/// `llama_decode` running out of memory mid-generation, hitting a different
/// test each run. See issue #80.
///
/// Sharing one runtime across concurrent tests is safe: every bridge entry
/// point that mutates llama state takes the runtime's `std::mutex`, and both
/// generate paths call `llama_memory_clear()` before starting, so each call
/// begins from a clean KV cache regardless of what ran before it.
/// `lllm_chat_render` and `lllm_parse_assistant_turn` do not lock, but they
/// only read the model and its chat template — they never touch the context.
///
/// Swift initialises globals lazily and exactly once, so the model loads on
/// whichever test asks for it first and not at all when none do.
private let sharedRuntimeState: SharedRuntimeState = {
    guard TestModel.isPresent else { return .modelAbsent }
    let runtime = LlamaRuntime(configuration: sharedConfiguration)
    do {
        try runtime.loadModel(at: TestModel.url)
        // The runtime outlives every test, so nothing else will free it. It has to
        // be freed before the process tears down its C++ statics: ggml-metal's
        // device destructor asserts that all Metal residency sets have been
        // released, and a still-loaded context means they have not —
        //   ggml-metal-device.m: GGML_ASSERT([rsets->data count] == 0) failed
        // which aborts with signal 6 during exit(). Every test still passes when
        // that happens, but `swift test` exits non-zero, so it is easy to miss if
        // you only read the test summary and not the exit status.
        //
        // atexit handlers run in reverse registration order, and this registers
        // after the Metal device statics were constructed during loadModel, so it
        // runs before their destructors. Related upstream: ggml-org/llama.cpp#17869.
        atexit(releaseSharedRuntimeAtExit)
        return .loaded(runtime)
    } catch {
        return .loadFailed(String(describing: error))
    }
}()

/// Top-level function, not a closure: `atexit` takes a C-convention function that
/// cannot capture context. Reading the global is fine — by the time this runs,
/// `sharedRuntimeState` is fully initialised.
private func releaseSharedRuntimeAtExit() {
    if case .loaded(let runtime) = sharedRuntimeState {
        runtime.unload()
    }
}

struct SharedRuntimeLoadFailure: Error, CustomStringConvertible {
    let underlying: String

    var description: String {
        "Shared test runtime failed to load \(TestModel.url.lastPathComponent): \(underlying)"
    }
}

/// The shared, already-loaded runtime, or `nil` when the GGUF is not installed —
/// in which case the caller should return and let the test pass vacuously, which
/// is what keeps this suite green on CI runners that have no model.
///
/// Never call `unload()` on the result: it is shared with every other test, and
/// unloading it would pull the model out from under whatever is running
/// concurrently.
func sharedLoadedRuntime() throws -> LlamaRuntime? {
    switch sharedRuntimeState {
    case .modelAbsent:
        return nil
    case .loaded(let runtime):
        return runtime
    case .loadFailed(let message):
        throw SharedRuntimeLoadFailure(underlying: message)
    }
}
