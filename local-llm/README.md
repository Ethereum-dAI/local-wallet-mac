# LocalLLM

Swift package providing a local LLM inference bridge for the Local Wallet macOS app, backed by llama.cpp.

## llama.cpp linkage

llama.cpp is **pinned**, not installed. [`LLAMA_CPP_PIN`](LLAMA_CPP_PIN) is the single source of truth; `../scripts/provision-llama.sh` assembles the prefix and `../scripts/build-ffi.sh` calls it, so a fresh clone needs no llama.cpp setup. Homebrew cannot install a specific llama.cpp version, which is why it is no longer on this path — see the pin file for the full reasoning.

Current pin:

- llama.cpp release: **b10330**
- Upstream commit: `687e7789271ec1276e3470f158428e11a4f80b6f`
- Tree: `https://github.com/ggml-org/llama.cpp/tree/687e7789271ec1276e3470f158428e11a4f80b6f`

`Package.swift` resolves `libllama`, `libllama-common`, `libggml`, and `libggml-base` from `LOCAL_LLAMA_PREFIX` / `LOCAL_LLAMA_INCLUDE_DIR` / `LOCAL_LLAMA_COMMON_INCLUDE_DIR` / `LOCAL_LLAMA_LIB_DIR` when set, and otherwise from the pinned prefix at `<repo>/.llama/current`. It also passes `-rpath` for the resolved lib dir, which the pinned dylibs need because they use `@rpath` install names.

An explicit `LOCAL_LLAMA_PREFIX` must supply `include-common/` alongside `include/` and `lib/`, or point `LOCAL_LLAMA_COMMON_INCLUDE_DIR` at the `common/` directory of a llama.cpp source tree at the matching commit. That is new: the `common/` headers used to be committed under `Sources/CLlamaBridge/third_party/`, so any prefix worked.

There is deliberately **no implicit Homebrew fallback**. Silently linking a Homebrew `libllama-common` would pair the pinned `common/` headers with a different build of their own implementations — and since the mangled C++ symbol names do not change between versions, that is silent runtime corruption rather than a link error. An unprovisioned tree fails fast with `'llama.h' file not found`. To build against Homebrew anyway, say so explicitly:

```bash
LOCAL_LLAMA_PREFIX=/opt/homebrew swift build   # off-pin, unsupported
```

The release asset ships dylibs and CLI executables only — **no headers at all**. `provision-llama.sh` fetches those from the pinned commit and stages them into two include roots, mirroring how the bridge consumes them:

| Prefix directory | Upstream source | Contents |
|---|---|---|
| `.llama/current/include` | `include/`, `ggml/include/` | the public API: `llama.h`, `ggml*.h`, `gguf.h` |
| `.llama/current/include-common` | `common/`, `common/jinja/`, `vendor/nlohmann/` | `common_chat_parse`, `common_chat_templates_init`, `common_chat_templates_apply`, the modular jinja renderer, bundled nlohmann — headers only; the implementations live in `libllama-common.dylib` |

`nlohmann` lands *inside* `include-common/` because `common/chat.h` includes it as `"nlohmann/json_fwd.hpp"`, relative to its own directory, whereas upstream keeps it at `vendor/nlohmann/` and resolves it with a separate `-I`.

**The headers are not committed to this repo.** They are fetched with a sparse, blob-filtered `git fetch` of just those directories — ~1 MB and a few seconds, against 36 MB for a full source archive. Two reasons that beats vendoring:

- **Integrity is free.** Git verifies fetched objects against the commit SHA, so `LLAMA_CPP_COMMIT` *is* the guarantee. There is no header checksum to maintain, and the headers cannot drift from the pin because they are read out of it. (A checksum over GitHub's auto-generated source archive would be fragile for the opposite reason: GitHub does not guarantee the byte-stability of the gzip stream, only of the contents.)
- **Bumping the pin stops involving headers.** It is three values in `LLAMA_CPP_PIN` plus whatever upstream API churn hits `CLlamaBridge.cpp`. Vendoring meant ~37k lines of upstream code in-tree and a re-vendoring step every time.

A header/dylib mismatch would still be serious — the mangled C++ symbol names do not change across these bumps, so it is silent runtime corruption rather than a link error. So `provision-llama.sh` verifies with `git ls-remote` that `LLAMA_CPP_COMMIT` is the commit `LLAMA_CPP_RELEASE`'s tag points at, and refuses to provision otherwise. A commit that merely exists upstream is not enough. After any bump, run the suite (21 tests, real Gemma inference) to catch API drift too.

## Running the tests

```bash
swift test
```

21 tests, of which the model-backed ones self-skip when the GGUF is absent (which is how this suite stays green on CI runners with no model).

**All model-backed tests share one `LlamaRuntime`**, defined in `Tests/LocalLLMTests/SharedTestRuntime.swift` and reached via `sharedLoadedRuntime()`. Do not construct a `LlamaRuntime` in a test, and never call `unload()` on the shared one.

That matters because each test file used to build its own runtime, so a single `swift test` loaded the 4.59 GB model up to nine times. Those loads do not share their weights, so peak memory hit ~54 GB on a 36 GB host and the suite failed non-deterministically under swift-testing's default parallelism — `llama_decode` running out of memory mid-generation, taking a different test down each run:

```text
Caught error: .generationFailed("Failed while generating response.")
Expectation failed: (result.produced → -4) > 0
```

Measured on a 36 GB M-series host:

| | Result | Peak resident |
|---|---|---|
| one runtime per test file (before) | 1/3 runs passed | 53.74 GB |
| shared runtime (now) | 5/5 runs passed | 4.56 GB |

Sharing is safe under concurrent tests: every bridge entry point that mutates llama state takes the runtime's `std::mutex`, and both generate paths call `llama_memory_clear()` first, so each call starts from a clean KV cache. `lllm_chat_render` and `lllm_parse_assistant_turn` do not lock but only read the model and its chat template.

If you ever see those two errors again, suspect that a new test built its own runtime — and note that they are **not** llama.cpp ABI drift, which is deterministic and fails at model load rather than mid-decode. Remaining work, including decoupling `llama_model` from `llama_context` in the bridge so the app can hold multiple sessions without reloading weights, is tracked in [#80](https://github.com/Ethereum-dAI/local-wallet-mac/issues/80).

## Minja / template-render spike (2026-05-18)

**Result: PASS.** `common_chat_templates_apply` against the cached Gemma 4 E4B template renders both system+user-only and system+user+tools shapes correctly. The Gemma DSL markers (`<|turn>system`, `<|tool>declaration:transfer`, `<|"|>` quoting, `<|turn>model\n` generation prompt suffix) all appear as expected. Tests under `Tests/LocalLLMTests/TemplateRenderSpikeTests.swift` verify the contract; both pass on Apple Silicon with the Gemma 4 E4B GGUF installed at `~/Library/Application Support/LocalWallet/Models/gemma-4-E4B-it-Q4_0.gguf`. This spike unblocked Phase 1 of the bridge upgrade, since merged to `main`.

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

`llm-bench` is an SwiftPM executable target in this package. It loads the model installed at `~/Library/Application Support/LocalWallet/Models/gemma-4-E4B-it-Q4_0.gguf` by default and produces human-readable output (plus optional structured JSON).

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
| `--model PATH`   | `~/Library/Application Support/LocalWallet/Models/gemma-4-E4B-it-Q4_0.gguf` | Path to a Gemma 4 GGUF |
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

Phase 0 + Phase 1 + Phase 2 + Phase 3 of the bridge upgrade are merged to `main`. 21/21 tests pass on the host with `swift test --no-parallel`. The full test suite covers:

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

Known open points, tracked here:

- Gemma 4 channel-marker fallback
- `<|tool_call>` DSL fallback parser
- Task-level vs llama.cpp-level stop semantics
- tool-layer phase 2
