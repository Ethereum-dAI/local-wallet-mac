# Local Wallet macOS Demo App

`wallet-macos` is a signed macOS demo/reference app for the lower-level Rust and Swift layers in this repo. It is not meant to represent the final product wallet UX yet.

What this demo currently exercises:

- Secure Enclave + Keychain persistence for the device-bound P-256 signing key
- public-key derivation and local wallet metadata persistence
- precomputed Kernel smart-account address derivation
- balance/deployment inspection over public Ethereum Sepolia RPC
- local ERC-4337 UserOperation building for a simple ETH transfer intent
- Secure Enclave signing + hosted bundler submission on Ethereum Sepolia
- debug logging for bootstrap, inspection, gas estimation, signing, submission, and receipt polling
- on-device Gemma 4 E4B chat with streaming, tool intent recognition (transfer / swap), slash commands, and an in-chat recognition card — the chat layer is documented in [Chat layer](#chat-layer) and [Tool layer (phase 1)](#tool-layer-phase-1) below

The package also contains `SpawnHelper`, the process-launch shim for the local `wallet-node` daemon. The current demo UI uses the hosted Sepolia composer for primary transaction submission, but it also starts/connects to the local daemon for relayer-key admin flows (rotate/export/delete the bundler EOA via admin challenges) and surfaces local relayer status independently of the hosted Sepolia path.

This app must be run as a signed macOS app bundle.

The direct Secure Enclave persistence model now uses permanent Keychain key items. That works in the real app target, but it will fail with `OSStatus -34018` if you try to run the app with `swift run`.

## Open And Run

1. Open `LocalWallet.xcodeproj` in Xcode.
2. Select the `LocalWalletApp` scheme.
3. In `Signing & Capabilities`, choose your Apple development team for the `LocalWalletApp` target.
4. Build and run the app from Xcode.

## Regenerate The Project

The Xcode project is generated from `project.yml` with `xcodegen`.

```bash
xcodegen generate
```

## Current Layout

- `wallet-macos/Sources/WalletMacOSApp` contains the demo app code.
- `wallet-macos/Sources/Spawn` contains the C `posix_spawn` shim for launching `wallet-node`.
- `wallet-macos/Sources/SpawnHelper` contains the Swift wrapper around that shim.
- `wallet-macos/Tests/SpawnHelperTests` verifies daemon launch, ready-event delivery, and alive-pipe shutdown.
- `swift-bridge` is the Swift package that calls the Rust FFI layer.
- `rust-core/crates/ffi/` is the local wallet-ffi crate (C ABI bridge); protocol and daemon crates resolve from sibling repos.

## App Module Map

- `WalletMacOSApp.swift`
  - AppKit entrypoint and the demo dashboard UI shell.
- `AppModel.swift`
  - Main coordinator for bootstrap, account inspection, draft building, signing, submission, and debug logging.
- `KeyStore.swift`
  - Secure Enclave + Keychain key lifecycle and signing.
- `WalletMetadataStore.swift`
  - Local JSON persistence for non-secret wallet metadata.
- `SmartAccountConfiguration.swift`
  - Chain config, Kernel contract addresses, EntryPoint config, and bundled ABI references.
- `KernelAccountAddressPredictor.swift`
  - Thin app-side wrapper around shared Rust/Swift bridge logic for predicted Kernel account addresses.
- `DemoRPCClient.swift`
  - Read-only JSON-RPC client for public chain inspection and fee fallback data.
- `BundlerClient.swift`
  - Hosted ERC-4337 bundler RPC client for gas estimation, fee quoting, submission, and receipt polling.
- `UserOperationBuilder.swift`
  - Local draft construction for the current transaction intents.
- `UserOperationModels.swift`
  - Demo-side models for draft representation and bundler payload shaping.
- `DemoModels.swift`
  - View-model structs used by the current demo dashboard and transaction composer.
- `DemoSettingsStore.swift`
  - Persistent demo-time settings (e.g., testnet-mode toggle).
- `WalletNodeClient.swift`
  - JSON-RPC client for the local `wallet-node` daemon over Unix socket or HTTP, including admin-authorized rotate/export/delete bundler-EOA flows.
- `WalletNodeDaemon.swift`
  - Lifecycle wrapper around the spawned daemon process.
- `WalletRecord.swift`
  - Aggregated per-wallet record (Secure Enclave key, metadata, predicted address).
- `AppError.swift`
  - App-level error types surfaced in UI.
- `EtherAmountParser.swift`, `WeiFormatter.swift`, `HexEncoding.swift`, `QRCodeImageFactory.swift`
  - Small formatting/encoding utilities.

### Chat and local LLM

- `ChatDashboardView.swift`
  - SwiftUI chat dashboard: sidebar with date-bucketed conversations (delete / rename / context menu), streaming message bubbles with copy / regenerate / edit-and-resend, slash autocomplete, "Tools" footer popover, context-usage banner, keyboard shortcuts (⌘N / ⌘K / ⌘⌫), smart auto-scroll with jump-to-latest pill.
- `ChatSQLiteStore.swift`
  - SQLite persistence for conversations + messages + tool intents under `Application Support/LocalWallet/chat.sqlite`. Schema version is gated by `ChatSQLiteMigration` (`WalletToolLayer`).
- `EmbeddedLlamaInferenceService.swift`
  - Bridges to `LlamaRuntime.chat(...)` from the `local-llm` package, exposes both a one-shot `generate` and a streaming `stream(...) -> AsyncThrowingStream<EmbeddedLlamaStreamEvent, Error>`, applies `GemmaChannelFallback` to recover reasoning when the upstream chat-template parser leaks `<|channel>thought ... <channel|>` markers into the content stream.
- `ToolIntentCardView.swift`
  - In-chat recognition card with **Looks good** / **Edit** / **Reject** actions and the structured-arguments edit sheet.
- `SlashCatalog.swift`
  - Single source of truth for slash commands (`/transfer`, `/swap`) shared by the inline composer autocomplete and the footer "Tools" popover. Each entry carries a display name, summary, signature, and ready-to-edit scaffold with angle-bracket placeholders.
- `OnboardingView.swift`, `OnboardingSettingsStore.swift`, `OnboardingProvisioningService.swift`
  - First-run flow for local model selection, hardware inspection, and provisioning.
- `LocalAIModelDownloadManager.swift`, `LocalHardwareInspector.swift`
  - Local GGUF model download and Apple Silicon / Metal capability inspection used by onboarding.

## Current Limits

- Sepolia-only demo mode is currently enforced in the app shell.
- The app currently focuses on ETH transfer as the first transaction type.
- The UI is intentionally a workbench/demo shell, not the final wallet interface.
- The local mainnet `wallet-node` daemon is integrated for relayer-key admin flows but is not yet the default transaction submission backend for this demo UI; the composer still routes through the hosted Sepolia bundler.

## Daemon Spawn Test

The daemon binary comes from the sibling `local-wallet-daemon` repo. Build it first:

```bash
cd ../local-wallet-daemon
cargo build -p wallet-node
```

Then run the Swift spawn helper test from this repo:

```bash
cd wallet-macos
swift test --filter SpawnHelperTests
```

Set `WALLET_NODE_BIN=/absolute/path/to/wallet-node` to point at a non-default daemon binary location. The fd-3 ready / fd-4 alive contract used by the spawn helper is documented in [`Sources/Spawn/README.md`](Sources/Spawn/README.md).

## Hosted Bundler Configuration

The Sepolia hosted bundler URL is intentionally not committed in source. For local development you can provide it as an environment variable:

```bash
export LOCAL_WALLET_SEPOLIA_BUNDLER_URL="https://..."
```

For packaged demo builds, use the same variable when running the package script:

```bash
LOCAL_WALLET_SEPOLIA_BUNDLER_URL="https://..." ./scripts/package-macos-demo.sh
```

The package script injects the URL into the built app's `Info.plist` and re-signs that copied app bundle. If the variable is not set, the app still builds and can inspect the account, but bundler submission is disabled.

---

## Chat layer

The chat dashboard is the primary entry point of the demo app. It runs a streaming conversation against an on-device Gemma 4 E4B GGUF model loaded by the sibling `local-llm` Swift package (`LlamaRuntime`).

Highlights of the current UX:

- **Streaming with stop and resume** — tokens stream into the in-flight bubble; ⎋ or the inline Stop button cancels the consumer Task (the underlying `llama.cpp` loop still runs to its own completion — see `docs/OPEN_ITEMS.md` OPEN-58).
- **Thinking disclosure** — reasoning content emitted by the model is shown live in a collapsible "Thinking" DisclosureGroup; `GemmaChannelFallback` re-extracts it from raw output when the upstream chat-template parser leaks `<|channel>thought ... <channel|>` markers (see OPEN-55).
- **Bubble-level actions** — Copy / Copy with stats / Regenerate (on assistant bubbles) / Edit & resend (on user bubbles). Edit truncates the conversation from the edited prompt onward (in-memory and in SQLite) and reissues the prompt through the standard streaming path.
- **Code blocks** — triple-backtick fences render in their own monospaced block with a per-block Copy button.
- **Sidebar** — conversations bucket into Today / Yesterday / Last 7 days / Last 30 days / Older. Hover reveals an X for deletion (confirmed via alert); double-click or context-menu lets you rename inline.
- **Slash discovery** — typing `/` in the composer opens an inline autocomplete listing matching commands from `SlashCatalog`; the same catalog feeds a "Tools" popover in the footer (next to the runtime status pill).
- **Welcome state** — empty conversations show four clickable starter chips (transfer, swap, slash demo, wallet question) that pre-load the composer.
- **Context-usage banner** — appears above the chat when the latest stats report ≥75% (warning) or ≥92% (critical) context fill; banner CTA opens a fresh chat.
- **Keyboard shortcuts** — ⌘N new chat, ⌘K focus composer, ⌘⌫ delete the active chat (with confirmation).
- **Smart auto-scroll** — auto-follow is only re-engaged when the user is near the bottom; when scrolled up, a small ↓ pill in the bottom-trailing corner jumps back to the latest message or in-flight streaming bubble.

## Tool layer (phase 1)

Phase 1 wires a local **intent recognition** layer over the chat. When the user expresses a clear on-chain action (transfer / swap), the chat thread renders an inline **recognition card** — `ToolIntentCardView` — showing the tool name and structured arguments. The card has three actions: **Looks good**, **Edit**, **Reject**. The card is *informational only*: phase 1 does not sign or broadcast any transaction (tracked centrally in `docs/OPEN_ITEMS.md` OPEN-57).

Two ways to surface a card:

1. **Natural language** — type `Send 0.1 ETH to vitalik.eth` in the chat composer. The local model decides whether to emit a `<|tool_call>` block; if it does, `BridgePEGExtractor` (with the Gemma 4 DSL fallback parser, see OPEN-56) decodes it into a `ParsedToolCall` and `ChatDashboardModel` appends a `.toolIntent` `ChatMessage`.
2. **Slash commands** — type `/transfer 0.1 ETH to <recipient>` or `/swap 100 USDC to ETH` in the composer. `SlashCommandParser` produces the same `ToolIntent` without invoking the model. The inline autocomplete and the footer "Tools" popover both insert scaffolds from `SlashCatalog`.

When the user acts on the card, a synthetic `.toolResponse` `ChatMessage` (role `.tool`) is appended to the conversation so the *next* model turn sees the disposition (`acknowledged` / `acknowledged + edited` / `rejected`) and continues coherently.

### What's explicitly out of scope for phase 1

- ENS resolution, token-symbol → contract-address lookup
- Gas estimation, fee preview, balance / allowance checks
- `UserOperationBuilder`, `BundlerClient`, signing, broadcast
- DEX quoting / routing for `swap`

The grep guard `grep -rE "UserOperationBuilder|BundlerClient|WalletNodeClient|KernelAccountAddressPredictor|KeyStore" Sources/WalletMacOSApp/ChatDashboardView.swift Sources/WalletMacOSApp/EmbeddedLlamaInferenceService.swift Sources/WalletMacOSApp/ToolIntentCardView.swift Sources/WalletToolLayer/` MUST come back empty. Phase 2 wires those in.

### Where the code lives

- `Sources/WalletToolLayer/` — model-agnostic library (`ToolIntent`, `ToolDefinitions`, `SlashCommandParser`, `BridgePEGExtractor`, `Gemma4FallbackParser`, `ChatSQLiteMigration`).
- `Sources/WalletMacOSApp/ToolIntentCardView.swift` — the SwiftUI recognition card + edit sheet.
- `Sources/WalletMacOSApp/SlashCatalog.swift` — static catalog of slash commands consumed by the inline autocomplete and the footer "Tools" popover.
- `Sources/WalletMacOSApp/ChatDashboardView.swift` — integrates the above into the chat dashboard, including streaming, edit-and-resend, regenerate, copy actions, and the smart-scroll plumbing.
- `Sources/WalletMacOSApp/EmbeddedLlamaInferenceService.swift` — calls `LlamaRuntime.chat(...)` with tools + system nudge; surfaces `toolCalls` on `EmbeddedLlamaGenerationResult` and exposes a streaming `stream(...)` variant for token-by-token consumption.

## wallet-eval

A CLI in `Sources/wallet-eval/` that drives the live local model against a curated dataset and reports recognition metrics. The dataset lives at `Sources/wallet-eval/Dataset/recognition.json` and is bundled as a resource.

Subcommands:

| Command       | Measures                                                  |
|---------------|-----------------------------------------------------------|
| `recognition` | Per-category + per-language pass/fail on the dataset      |
| `round-trip`  | Multi-turn coherence after a tool call is acknowledged    |
| `latency`     | Time-to-first-token and time-to-done                      |
| `all`         | Runs all three subcommands in sequence                    |

Shared flags:

| Flag                 | Default                  | Notes                                  |
|----------------------|--------------------------|----------------------------------------|
| `--model PATH`       | onboarding-installed GGUF | Path to a Gemma 4 GGUF                 |
| `--repeats N`        | `3`                      | Per-case repetitions                   |
| `--seed S`           | `0xC0DEFEED`             | Hex or decimal                         |
| `--json PATH`        | (none)                   | Structured `EvalEntry[]` report        |
| `--filter CATEGORY`  | (none)                   | Run only matching category or language |
| `--verbose`          | off                      | Per-case outcome printing              |

Example invocations:

```bash
swift run wallet-eval recognition --repeats 3 --json /tmp/wallet-eval.json
swift run wallet-eval recognition --filter slashCommand
swift run wallet-eval latency --repeats 5
swift run wallet-eval all
```

### Initial baseline (2026-05-19)

The first `swift run wallet-eval recognition --repeats 1` run on the host (Gemma 4 E4B Q4, Apple Silicon Metal, llama.cpp b9200 + Swift fallback parser for P1.A):

- **HEADLINE (English only): 92% (n=26)**
- truePositiveTransfer: 8/8 (100%)
- truePositiveSwap: 4/6 (67%) — two "buy X with Y" phrasings missed
- falsePositiveExpected: 6/6 (100%)
- ambiguous: 3/3 (100%)
- slashCommand: 3/3 (100%)
- multilingual: italian 100%, spanish 100%, french 0% (1 case)

Total wallclock ~210s. French/multilingual coverage is tracked in the central, gitignored `docs/OPEN_ITEMS.md`; the Swift Gemma 4 DSL fallback that backstops the P1.A parser gap is tracked there as OPEN-56.

### Adding cases to the dataset

Edit `Sources/wallet-eval/Dataset/recognition.json`. The schema is:

```json
{
  "id": "unique-id",
  "user_message": "...",
  "category": "truePositiveTransfer|truePositiveSwap|falsePositiveExpected|ambiguous|slashCommand|multilingualTransfer|roundTrip",
  "language": "english|italian|spanish|french|german|...",
  "expected_tool": "transfer|swap|null",
  "expected_args": {
    "<arg-name>": { "kind": "exact|regex|oneOf", "value": "..." | ["a","b"] }
  },
  "notes": "..."
}
```

After editing, rebuild + rerun. Dataset cases ship with the binary via SPM resource copying — no separate install step.
