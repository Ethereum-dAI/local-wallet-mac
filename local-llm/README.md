# LocalLLM

Swift package providing a local LLM inference bridge for the Local Wallet macOS app, backed by llama.cpp.

## llama.cpp linkage

`libllama`, `libggml`, `libggml-base`, and `libllama-common` are resolved from `LOCAL_LLAMA_PREFIX`, `LOCAL_LLAMA_INCLUDE_DIR`, or `LOCAL_LLAMA_LIB_DIR` when set, falling back to Homebrew (`/opt/homebrew`). The `common/` C++ headers we need (`common_chat_parse`, `common_chat_templates_init`, `common_chat_templates_apply`, the modular jinja renderer) are vendored under `Sources/CLlamaBridge/third_party/llama_cpp_common/` (**headers only** — the implementations live in `libllama-common.dylib`). Both the linked llama.cpp artifacts and the vendored headers must originate from the **same upstream commit**, recorded here:

- llama.cpp pinned commit: `3e12fbdea5c1ac4225c7dcf79506d30950283fc3` (Homebrew bottle b9200)
- Vendored from: `https://github.com/ggml-org/llama.cpp/tree/3e12fbdea5c1ac4225c7dcf79506d30950283fc3/common`

When Homebrew or the release build prefix bumps `llama.cpp`, re-vendor the `common/` headers from the matching commit and run `swift test` to catch ABI drift early (see `Sources/CLlamaBridge/third_party/llama_cpp_common/COMMIT` for the step-by-step procedure). For release packaging, prefer a local llama.cpp/ggml prefix compiled with `CMAKE_OSX_DEPLOYMENT_TARGET=14.0` and `CMAKE_OSX_ARCHITECTURES=arm64`.

## Minja / template-render spike (2026-05-18)

**Result: PASS.** `common_chat_templates_apply` against the cached Gemma 4 E4B template renders both system+user-only and system+user+tools shapes correctly. The Gemma DSL markers (`<|turn>system`, `<|tool>declaration:transfer`, `<|"|>` quoting, `<|turn>model\n` generation prompt suffix) all appear as expected. Tests under `Tests/LocalLLMTests/TemplateRenderSpikeTests.swift` verify the contract; both pass on Apple Silicon with the Q4_K_M GGUF installed at `~/Library/Application Support/LocalWallet/Models/gemma-4-E4B-it-Q4_K_M.gguf`. Proceeding with Phase 1 of the bridge upgrade.

## Public API

`LocalLLM` exposes a small public surface centred on `LlamaRuntime` and its `chat(...)` method. Tool calling, streaming, sampler control, and grammar-constrained generation all flow through the same entry point.

```swift
import LocalLLM

let runtime = LlamaRuntime()
try runtime.loadModel(at: ggufURL)

let messages: [ChatMessage] = [
    .init(role: .system, content: "You are a concise wallet assistant."),
    .init(role: .user,   content: "Send 0.1 ETH to vitalik."),
]

let tools: [ToolDefinition] = [
    .init(name: "transfer",
          description: "Send tokens.",
          parametersJSONSchema: "{...}")
]

var options = SamplerOptions()
options.maxTokens = 256
options.enableThinking = true

for try await event in runtime.chat(messages: messages, tools: tools, options: options) {
    switch event {
    case .textToken(let piece):
        print(piece, terminator: "")
    case .done(let stats, let reason):
        print("\n[\(reason): \(stats.generatedTokens) tok in \(stats.duration)s]")
    }
}

// Optional: parse the assistant turn back into tool_calls.
let parsed = try runtime.parseAssistantTurn(accumulatedAssistantText)
for call in parsed.toolCalls {
    print(call.function.name, call.function.arguments)
}
```

Types:
- `ChatMessage` — `{role, content?, toolCalls?, toolCallId?, name?, reasoning?}` mirrors the OpenAI chat-completion shape.
- `ToolCall` / `ToolDefinition` — OpenAI-compatible function-call schema.
- `SamplerOptions` — `temperature`, `topP`, `topK`, `minP`, `repeatPenalty`, `maxTokens`, `seed`, `stopSequences`, `grammarGBNF`, `enableThinking`.
- `ChatEvent` — `.textToken(String) | .done(GenerationStats, stopReason: StopReason)`.
- `StopReason` — `.endOfStream | .maxTokens | .stopSequence(String) | .cancelled`.
- `ParsedAssistantTurn` — `{content?, reasoning?, toolCalls: [ToolCall]}`.

Cancellation: cancel the surrounding `Task` (or break out of the `for try await` loop) and the underlying `lllm_runtime_generate_v2` stops on the next sampled token. The final `.done` event arrives with `.cancelled` as the stop reason.

Legacy `generate(_:)`, `generateWithStats(_:)`, `generateStream(_:)` remain on `LlamaRuntime` but are `@available(*, deprecated)` — migrate to `chat(...)`.

## Benchmarks

`llm-bench` is an SwiftPM executable target in this package. It loads the model installed at `~/Library/Application Support/LocalWallet/Models/gemma-4-E4B-it-Q4_K_M.gguf` by default and produces human-readable output (plus optional structured JSON).

Subcommands:

| Command | Measures |
|---|---|
| `load`     | Cold model-load time (seconds) |
| `prefill`  | Prefill latency at three prompt lengths (~128, ~512, ~2048 tokens) |
| `decode`   | Sustained decode throughput (tokens/sec) over 256 generated tokens |
| `ttft`     | Time-to-first-token (ms) |
| `render`   | `lllm_chat_render` template-render latency in isolation (ms) |
| `grammar`  | Decode throughput with vs without a tight GBNF grammar |
| `all`      | Runs all of the above in sequence (see caveat below) |

Shared flags:

| Flag | Default | Notes |
|---|---|---|
| `--model PATH`   | `~/Library/Application Support/LocalWallet/Models/gemma-4-E4B-it-Q4_K_M.gguf` | Path to a Gemma 4 GGUF |
| `--repeats N`    | `5`              | Number of measured runs (after warmup) |
| `--warmup N`     | `1`              | Unmeasured warmup runs |
| `--seed S`       | `0xC0DEFEED`     | Hex (`0x...`) or decimal |
| `--json PATH`    | (none)           | Write a structured `BenchEntry[]` report; flushed after every subcommand |

Example:

```bash
swift run llm-bench all --repeats 3 --warmup 1 --json /tmp/bench.json
swift run llm-bench decode --repeats 5
```

Caveat: a known upstream llama.cpp issue ([PR #17869](https://github.com/ggml-org/llama.cpp/pull/17869)) intermittently triggers `GGML_ASSERT(buft) failed` on `runtime.unload()` after generation. The metric is printed *before* the crash, so per-subcommand output is reliable. When chaining via `all`, the crash terminates the process after the first affected subcommand — JSON written incrementally up to that point is preserved. Re-run remaining subcommands individually until upstream lands the fix.

The `BenchEntry` JSON shape (one entry per measurement):

```json
{
  "schema": "llm-bench/v1",
  "entries": [
    { "subcommand": "load",    "label": "cold-load",        "metric": "seconds",    "mean": 7.42, "stddev": 0.12, "samples": 5 },
    { "subcommand": "prefill", "label": "prefill-short",    "metric": "seconds",    "mean": 0.34, "stddev": 0.02, "samples": 5 },
    { "subcommand": "decode",  "label": "tokens-per-second","metric": "tok_per_s",  "mean": 18.7, "stddev": 0.4,  "samples": 5 }
  ]
}
```

## Acceptance status (2026-05-18)

Phase 0 + Phase 1 + Phase 2 + Phase 3 of the bridge upgrade are landed on `local-llm/bridge-upgrade`. 21/21 tests pass on the host with `swift test --no-parallel`. The full test suite covers:

- C ABI smoke (`missingModelThrows`)
- Model + template metadata (`chatTemplateMetadataIsAvailableAfterLoad`)
- Minja / template render (`spikeRendersSystemAndUserOnly`, `spikeRendersToolsBlock`)
- `lllm_chat_render` error contract (4 tests)
- `lllm_parse_assistant_turn` envelope and content-only paths (2 tests)
- `lllm_count_tokens` (1 test)
- `lllm_runtime_generate_v2` sampler + cancel + grammar + stop (4 tests, `@Suite(.serialized)`)
- `LlamaRuntime.chat(...)` AsyncThrowingStream (1 test, `@Suite(.serialized)`)
- `ChatMessage / ToolDefinition / SamplerOptions` round-trips (4 tests)
- Legacy v1 smoke (`gemmaSmokeTestWhenModelExists`) — deprecation warning emitted at call site

Known open points (Gemma 4 channel-marker fallback, `<|tool_call>` DSL fallback parser, Task-level vs llama.cpp-level stop semantics, tool-layer phase 2) are tracked in the central, gitignored `docs/OPEN_ITEMS.md` at the repo root — see OPEN-55 / OPEN-56 / OPEN-58 / OPEN-57 respectively.
