# Local Wallet macOS Demo App

`wallet-macos` is a signed macOS demo/reference app for the lower-level Rust and Swift layers in this repo. The current v0.1 line is alpha software: under active development, not independently audited, and not production-ready custody software. It is not meant to represent the final product wallet UX yet.

What this demo currently exercises:

- Secure Enclave + Keychain persistence for the device-bound P-256 signing key
- public-key derivation and local wallet metadata persistence
- precomputed Kernel smart-account address derivation
- balance/deployment inspection on Ethereum Sepolia or mainnet
- local ERC-4337 UserOperation building for native ETH transfers, ERC-20 transfers, and exact-input Uniswap v3 swaps
- Secure Enclave signing + local `wallet-node` submission through the app-owned bundler EOA
- debug logging for bootstrap, inspection, gas estimation, signing, submission, and receipt polling
- on-device Gemma 4 E4B chat with streaming, tool intent recognition (transfer / swap), slash commands, and an in-chat review card — the chat layer is documented in [Chat layer](#chat-layer) and [Tool layer](#tool-layer) below

The package also contains `SpawnHelper`, the process-launch shim for the local `wallet-node` daemon. Confirmed chat intents use the daemon for Helios-backed reads, gas estimation, UserOperation submission, receipt polling, swap quotes, and relayer-key admin flows (rotate/export/delete the bundler EOA via admin challenges).

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
- `ChainReadCallData.swift`
  - ABI calldata helpers for read-only calls that are transported through local `wallet-node`.
- `BundlerClient.swift`
  - Legacy hosted ERC-4337 bundler RPC client retained for older composer paths. Chat-confirmed transfer and swap intents use local `wallet-node` instead.
- `UserOperationBuilder.swift`
  - Local draft construction for the current transaction intents.
- `UserOperationModels.swift`
  - Demo-side models for draft representation and bundler payload shaping.
- `DemoModels.swift`
  - View-model structs used by the current demo dashboard and transaction composer.
- `DemoSettingsStore.swift`
  - Persistent demo-time settings (e.g., testnet-mode toggle).
- `WalletNodeClient.swift`
  - JSON-RPC client for the local `wallet-node` daemon over Unix socket or HTTP, including Helios-backed chain reads, admin-authorized rotate/export/delete bundler-EOA flows, ENS resolution, and Uniswap v3 swap quotes.
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
  - SwiftUI chat dashboard: sidebar with date-bucketed conversations (delete / rename / context menu), streaming message bubbles with copy / regenerate / edit-and-resend, slash autocomplete, "Tools" footer popover, context-usage banner, keyboard shortcuts (⌘N / ⌘K / ⌘⌫), smart auto-scroll with jump-to-latest pill; chat-header gear menu carries a "Show thinking" toggle and a "Download rankings" export action.
- `ChatSQLiteStore.swift`
  - SQLite persistence for conversations + messages + tool intents + tool-intent feedback under `Application Support/LocalWallet/chat.sqlite`. Schema version is gated by `ChatSQLiteMigration` (`WalletToolLayer`); current schema is v2 (adds the `tool_intent_feedback` table).
- `EmbeddedLlamaInferenceService.swift`
  - Bridges to `LlamaRuntime.chat(...)` from the `local-llm` package, exposes both a one-shot `generate` and a streaming `stream(...) -> AsyncThrowingStream<EmbeddedLlamaStreamEvent, Error>`, applies `GemmaChannelFallback` to recover reasoning when the upstream chat-template parser leaks `<|channel>thought ... <channel|>` markers into the content stream.
- `ToolIntentCardView.swift`
  - In-chat recognition card with **Looks good** / **Edit** / **Reject** actions, the structured-arguments edit sheet, and thumbs-up / thumbs-down feedback controls (thumbs-down opens a note sheet).
- `ToolIntentFeedback.swift`
  - Value types for per-intent thumbs-up/down feedback and the rankings JSON export schema (`ToolIntentFeedbackExportRecord`).
- `SlashCatalog.swift`
  - Single source of truth for slash commands (`/transfer`, `/swap`) shared by the inline composer autocomplete and the footer "Tools" popover. Each entry carries a display name, summary, signature, and ready-to-edit scaffold with angle-bracket placeholders.
- `OnboardingView.swift`, `OnboardingSettingsStore.swift`, `OnboardingProvisioningService.swift`
  - First-run flow for local model selection, hardware inspection, and provisioning.
- `LocalAIModelDownloadManager.swift`, `LocalHardwareInspector.swift`
  - Local GGUF model download and Apple Silicon / Metal capability inspection used by onboarding.

## Current Limits

- Mainnet and Sepolia are the supported app chains.
- The chat tool path supports native ETH transfers, ERC-20 transfers from the local token registry, and exact-input Uniswap v3 swaps.
- ERC-20 input swaps require an existing allowance from the Kernel smart account to SwapRouter02. Approval UserOperations are intentionally not built yet, so the UI blocks those swaps with an "Approval required" state.
- The UI is intentionally a workbench/demo shell, not the final wallet interface.
- Swap routing is intentionally local/on-chain only: the app asks `wallet-node` to query Uniswap v3 factory/pools/quoter through Helios-backed reads. No aggregator API or third-party quote service is used.

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

## Legacy Hosted Bundler Configuration

The chat tool path submits through local `wallet-node`. The older composer path still has a hosted Sepolia bundler client, and that URL is intentionally not committed in source. For local development you can provide it as an environment variable:

```bash
export LOCAL_WALLET_SEPOLIA_BUNDLER_URL="https://..."
```

For packaged demo builds, use the same variable when running the package script:

```bash
LOCAL_WALLET_SEPOLIA_BUNDLER_URL="https://..." ./scripts/package-macos-demo.sh
```

The package script builds the sibling `wallet-node` daemon, embeds it at `Contents/Resources/bin/wallet-node`, copies llama.cpp/ggml dynamic libraries into `Contents/Frameworks`, verifies embedded Mach-O deployment targets, injects the URL into the built app's `Info.plist` when set, re-signs that copied app bundle, and checks that the final signature has the application identifier entitlement required by Secure Enclave. For testers outside your own Macs, use the Developer ID notarization path in `scripts/README.md` (`LOCAL_WALLET_NOTARIZE=1` plus a Developer ID Application identity and notarytool credentials) so Gatekeeper accepts the app without per-user Terminal re-signing. Removing quarantine from a trusted copy is less destructive than ad-hoc re-signing; ad-hoc re-signing breaks the entitlement identity needed for wallet creation.

The v0.1 alpha zip targets macOS 14+ on Apple Silicon and does not embed the recommended GGUF model by default; onboarding installs the model during setup. Set `LOCAL_WALLET_EMBED_MODEL=1` only for a large self-contained demo build. If the bundler URL variable is not set, the app still builds and the chat tool path can use local `wallet-node`; hosted composer submission is disabled. If Homebrew llama.cpp/ggml was built for a newer macOS, point `LOCAL_LLAMA_PREFIX` at a macOS 14-compatible local build before packaging.

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
- **Intent feedback & export** — every recognition card carries thumbs-up / thumbs-down controls (thumbs-down opens a note sheet); ratings persist to `chat.sqlite` and the gear menu in the chat header has a **Download rankings** action that writes a JSON export (`local-wallet-tool-rankings-<date>.json`) via `NSSavePanel`.

## Tool layer

The chat wires a local **intent recognition** layer to on-chain execution. When the user expresses a clear on-chain action (transfer / swap), the chat thread renders an inline review card — `ToolIntentCardView` — showing the tool name, structured arguments, preflight status, and actions. Supported intents can be confirmed with **Looks good**, edited, or rejected. Confirmation asks for local signing and submits the UserOperation through the local `wallet-node` daemon.

Two ways to surface a card:

1. **Natural language** — type `Send 0.1 ETH to vitalik.eth` in the chat composer. The local model decides whether to emit a `<|tool_call>` block; if it does, `BridgePEGExtractor` (with the Gemma 4 DSL fallback parser, see OPEN-56) decodes it into a `ParsedToolCall` and `ChatDashboardModel` appends a `.toolIntent` `ChatMessage`.
2. **Slash commands** — type `/transfer 0.1 ETH to <recipient>` or `/swap 100 USDC to ETH` in the composer. `SlashCommandParser` produces the same `ToolIntent` without invoking the model. The inline autocomplete and the footer "Tools" popover both insert scaffolds from `SlashCatalog`. The parser also accepts an explicit `key=value` form — `/transfer amount=0.1 token=ETH to=vitalik.eth` and `/swap amount=100 from_token=USDC to_token=ETH amount_side=input` — useful when arguments contain spaces or when the positional form is ambiguous. `swap` is exact-input only; output-side swaps are rejected before execution.

Transfers support native ETH, ERC-20 tokens in `WalletTokenRegistry`, `0x` recipients, and ENS names. ENS resolution runs through `wallet-node`, including CCIP Read when required by the resolver. The review card shows the resolved address before signing.

Swaps support exact-input Uniswap v3 routes on mainnet and Sepolia. The app asks `wallet-node` for an on-chain quote using local token metadata, direct pools, one-hop intermediate routes, the configured Uniswap v3 factory, QuoterV2, and SwapRouter02 addresses. ETH input swaps can execute directly; ERC-20 input swaps execute only when the smart account already has enough allowance for SwapRouter02. Approval/batch-approval UserOperations are intentionally not implemented yet.

When the user acts on the card, a synthetic `.toolResponse` `ChatMessage` (role `.tool`) is appended to the conversation so the *next* model turn sees the disposition (`acknowledged` / `acknowledged + edited` / `rejected`) and continues coherently. Successful submissions also append an on-chain summary card with copy actions and an Etherscan link. The user can rate the recognition with thumbs-up / thumbs-down (with an optional note on thumbs-down); ratings are stored in the `tool_intent_feedback` table (`ChatSQLiteMigration` v1→v2) keyed by conversation + message + intent, reload with the conversation, and can be exported as a single JSON file via the chat-header gear menu's **Download rankings** action.

### Where the code lives

- `Sources/WalletToolLayer/` — model-agnostic library (`ToolIntent`, `ToolDefinitions`, `SlashCommandParser`, `BridgePEGExtractor`, `Gemma4FallbackParser`, `ChatSQLiteMigration`).
- `Sources/WalletMacOSApp/ToolIntentCardView.swift` — the SwiftUI recognition card + edit sheet + thumbs feedback controls.
- `Sources/WalletMacOSApp/ToolIntentFeedback.swift` — feedback value types and the rankings JSON export schema.
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
