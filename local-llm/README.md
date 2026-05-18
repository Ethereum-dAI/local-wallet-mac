# LocalLLM

Swift package providing a local LLM inference bridge for the Local Wallet macOS app, backed by llama.cpp via Homebrew.

## llama.cpp linkage

`libllama`, `libggml`, `libggml-base`, `libllama-common` come from Homebrew (`/opt/homebrew/lib`). The `common/` C++ headers we need (`common_chat_parse`, `common_chat_templates_init`, `common_chat_templates_apply`, the modular jinja renderer) are vendored under `Sources/CLlamaBridge/third_party/llama_cpp_common/` (**headers only** — the implementations live in `libllama-common.dylib` from Homebrew, so we don't recompile them). Both the Homebrew artifacts and the vendored headers must originate from the **same upstream commit**, recorded here:

- llama.cpp pinned commit: `3e12fbdea5c1ac4225c7dcf79506d30950283fc3` (Homebrew bottle b9200)
- Vendored from: `https://github.com/ggml-org/llama.cpp/tree/3e12fbdea5c1ac4225c7dcf79506d30950283fc3/common`

When Homebrew bumps `llama.cpp`, re-vendor the `common/` headers from the matching commit and run `swift test` to catch ABI drift early (see `Sources/CLlamaBridge/third_party/llama_cpp_common/COMMIT` for the step-by-step procedure).

## Minja / template-render spike (2026-05-18)

**Result: PASS.** `common_chat_templates_apply` against the cached Gemma 4 E4B template renders both system+user-only and system+user+tools shapes correctly. The Gemma DSL markers (`<|turn>system`, `<|tool>declaration:transfer`, `<|"|>` quoting, `<|turn>model\n` generation prompt suffix) all appear as expected. Tests under `Tests/LocalLLMTests/TemplateRenderSpikeTests.swift` verify the contract; both pass on Apple Silicon with the Q4_K_M GGUF installed at `~/Library/Application Support/LocalWallet/Models/gemma-4-E4B-it-Q4_K_M.gguf`. Proceeding with Phase 1 of the bridge upgrade.
