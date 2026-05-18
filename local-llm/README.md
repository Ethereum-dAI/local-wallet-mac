# LocalLLM

Swift package providing a local LLM inference bridge for the Local Wallet macOS app, backed by llama.cpp via Homebrew.

## llama.cpp linkage

`libllama`, `libggml`, `libggml-base`, `libllama-common` come from Homebrew (`/opt/homebrew/lib`). The `common/` C++ helpers we need (`common_chat_parse`, `common_chat_templates_init`, the minja renderer) are vendored as source under `Sources/CLlamaBridge/third_party/llama_cpp_common/` and compiled alongside `CLlamaBridge.cpp`. Both the Homebrew artifacts and the vendored source must originate from the **same upstream commit**, recorded here:

- llama.cpp pinned commit: `3e12fbdea5c1ac4225c7dcf79506d30950283fc3` (Homebrew bottle b9200)
- Vendored from: `https://github.com/ggml-org/llama.cpp/tree/3e12fbdea5c1ac4225c7dcf79506d30950283fc3/common`

When Homebrew bumps `llama.cpp`, re-vendor the `common/` subset from the matching commit and run `swift test` to catch ABI drift early.
