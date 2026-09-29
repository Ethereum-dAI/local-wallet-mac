# edw-tui

A terminal chat UI over [desktop-wallet](https://github.com/ethereum/desktop-wallet)'s `edw` CLI.
A local Ollama model turns plain language into `edw` commands through
[Rig](https://github.com/0xPlaygrounds/rig), which owns the whole tool-call loop. Commands
that change wallet state wait for a y/n in the UI, and recovery phrases never reach the model.

It is an experiment in intent-driven wallet UX, separate from the macOS app: it shares no
crates with it and drives edw only.

## Setup

```bash
# edw, at the revision the tool mapping is tested against (edw::EDW_PINNED_REV):
cargo install --git https://github.com/ethereum/desktop-wallet \
  --rev 038c9944c0efff46082a9d85fdc216fe5e6c738e --locked edw

ollama pull qwen3:8b
cargo run
```

The TUI warns at startup when the installed edw is not the pinned revision.

| Variable | Default | |
|---|---|---|
| `EDW_TUI_MODEL` | `qwen3:8b` | Any installed Ollama model, or `scripted` (a fixed fake, for tests). Switch in the TUI with `/models` and `/model <n>`. |
| `OLLAMA_HOST` | `http://127.0.0.1:11434` | |
| `EDW_TUI_NUDGE` | on | Retries once when a model goes silent after a tool result (gemma4 does). `0` turns it off. |
| `EDW_BIN` | `edw` | |
| `EDW_DATA_DIR`, `EDW_RUNTIME_DIR` | `.edw/data`, `.edw/runtime` | A throwaway wallet, never your real edw data. |
| `EDW_DECRYPTION_PASSWORD` | `edw-tui-demo` | |
| `EDW_TUI_PROFILE` | `0/0` | The profile balances and transfers use (a name or `mnemonic/profile`). Change it in the TUI with `/profile <name>`. The model never picks one. |
| `EDW_TUI_RPC_URL` | the unlocked network's endpoint | Overrides the endpoint for the interim tools only, e.g. a local anvil fork. |
| `EDW_TUI_INTERIM_SEPOLIA` | off | `1` allows interim sends on Sepolia. Mainnet is always refused. |
| `EDW_TUI_ADDRESS_ALIASES` | on | The model sees `ADDR_1`, `ADDR_2`… instead of 0x addresses and never retypes one (8B models lose count in long hex; Ollama then aborts the reply). `0` shows it raw addresses, e.g. for evals. |

In the TUI: **Tab** shows one panel at a time, full width and without side borders, so a
mouse selection copies only that panel. `/copy` copies the last reply, `/copy log` the last
command and its output, `/copy address` the sending profile's address. Pasting is safe:
line breaks in a paste never send the message.

## Transfers (interim)

edw has no `balance`, `transfer` or `swap` command yet, so `src/interim/` does the work until it
does, signing with the pinned `edw-core` from edw's own encrypted store. The tools the model
sees are the SwiftUI app's `transfer` and `swap`, byte for byte (a test compares them with
`wallet-macos/.../ToolDefinitions.swift`), plus the app's safety clause, so switching to edw's
commands later changes no evals.

Every transfer is simulated first. The modal shows that dry run (sender, amount, recipient, max
fee), written by the executor rather than the model, and only `y` sends that exact transaction.
Before any of that, guards refuse burn and zero addresses, malformed addresses and amounts, ENS
names (not resolved yet) and unknown token symbols. Known tokens: USDC and WETH on Sepolia; any
other ERC-20 works by its 0x address. Swap is in the contract but not executed yet.

## The model-facing contract

```bash
cargo run -- tools-dump
```

prints everything the model is given (preamble, tool schemas in the exact Ollama wire format,
request settings) with a `contract_version`. Evals should read this output, never a copy.
`contract.json` is the committed snapshot; a test fails when the two differ, so any change to
what the model sees shows up in review. Regenerate with `cargo run -- tools-dump > contract.json`.

## Tests

```bash
cargo test                          # unit + integration; edw-backed tests skip without edw
cargo test --test edw_contract      # every tool against the pinned edw
cargo test --test interim           # real ETH sends on a throwaway anvil (needs anvil)
cargo test --test interim -- --ignored   # USDC on an anvil fork of Sepolia (network; EDW_TUI_SEPOLIA_RPC)
cargo test --test agent_loop -- --ignored --nocapture   # real Ollama (EDW_TUI_MODEL, EDW_TUI_SWITCH_TO)
```

`edw_contract` is what should break when edw changes. To bump the pin: change
`EDW_PINNED_REV` and the install command above, reinstall edw, then fix `build_argv` in
`src/edw.rs` until `edw_contract` passes. Bump `CONTRACT_VERSION` only if what a correct
answer is has changed.
