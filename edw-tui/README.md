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
| `EDW_TUI_PROFILE` | `0/0` | The profile balances and transfers use (a name or `mnemonic/profile`). Change it with `/profile <name>`, or say "send … from bob": the model then calls `use_profile`. Either way the switch stays until changed and shows in the status bar and the review modal. |
| `EDW_TUI_RPC_URL` | the unlocked network's endpoint | Overrides the endpoint for the interim tools only, e.g. a local anvil fork. |
| `EDW_TUI_INTERIM_SEPOLIA` | off | `1` allows interim sends on Sepolia. |
| `EDW_TUI_MAINNET_FORK` | off | `1` lets `mainnet` through, but only when `EDW_TUI_RPC_URL` is a loopback anvil fork (`anvil_nodeInfo` reports a fork URL). Real mainnet is always refused. |
| `EDW_TUI_SKILLS` | on | `off` disables skills entirely. |
| `EDW_TUI_SKILLS_DIR` | `skills` | Where skills are found, `:`-separated. |
| `EDW_TUI_SKILLS_LOCK` | `~/.config/edw-tui/skills.lock` | The skill folders you agreed to (by absolute path), with each folder's hash. Per user, so no repo can ship approvals. |
| `EDW_TUI_SKILL_IMAGE` | `python:3.12-slim@sha256:f77ac9e…` | The Docker image skill scripts run in, pinned by digest. |
| `EDW_TUI_ADDRESS_ALIASES` | on | The model sees `ADDR_1`, `ADDR_2`… instead of 0x addresses and never retypes one (8B models lose count in long hex; Ollama then aborts the reply). `0` shows it raw addresses, e.g. for evals. |

In the TUI: **↑↓** scroll the chat and **Shift+↑↓** the command log, each on its own
(PgUp/PgDn and Shift+PgUp/PgDn too, where the terminal passes them on; macOS terminals often
keep them for their own scrollback). A scrolled panel stays put as new lines arrive; scrolling
to the bottom, or sending a message, follows the newest again. **←→**, **Home/End** (or
Ctrl+A/Ctrl+E), Backspace and Delete edit the message at the cursor.
**Tab** shows one panel at a time, full width and without side borders, so a
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
names (not resolved yet) and unknown token symbols. Known tokens are the app's Sepolia list (WETH,
USDC, USDT, DAI, AAVE, UNI); transfers take any other ERC-20 by its 0x address.

Swaps follow the SwiftUI app and its daemon (`src/interim/swap.rs`): Uniswap v3 on Sepolia,
the direct pair or one hop through WETH/USDC/USDT/DAI across all fee tiers, the best QuoterV2
quote, and a minimum output after `EDW_TUI_SWAP_SLIPPAGE_BPS` (default 100 = 1%, at most 5000).
ETH is routed as WETH (sent as `msg.value`, or unwrapped to you with `multicall`). An ERC-20
input first gets an approval for exactly the amount, so a swap may be two or three
transactions; the review lists them all, and they are sent in order, stopping at the first
failure. Only known tokens are traded.

## Skills

A skill is a folder under `skills/` that teaches the agent something new, like Claude's
skills. The system prompt lists each skill's name and one-line description; the model calls
`load_skill` to read its instructions, and only then are its tools offered. Three ship here:

- `defi-data`: past yields, TVL and volume of DeFi pools and lending markets, from
  DefiLlama, GeckoTerminal and DexScreener (no API keys). Read-only. A chain may be written
  any way ("Ethereum Mainnet", "mainnet", "Arbitrum One", "1"): CoinGecko's platform list and
  DefiLlama's chain list resolve it, and with none given it is the wallet's chain (Ethereum
  when the wallet is on a testnet).
- `aave-v3-lend`: supply USDC, USDT or DAI to Aave v3 and withdraw it, on Sepolia (Aave's faucet
  tokens) or an anvil mainnet fork. Requires `defi-data`.
- `safe-multisig`: read a [Safe](https://safe.global) by address on Ethereum, Gnosis Chain,
  Sepolia, Base and others: `safe_info` (owners, threshold, modules; the signer set is
  cross-checked against the Safe on chain when the wallet is on that chain), `safe_queue` (what
  is waiting for signatures, in plain English, with who has not signed) and `safe_activity`
  (what it recently executed). Read-only, from the Safe Transaction Service. Labels are rules,
  not a model's guess: payouts, CoW Protocol pre-signed swap orders, approvals (unlimited ones
  are flagged), owner/module changes, rejections, and any delegatecall that is not Safe's own
  MultiSend. It has no actions: a plan may only call manifest-pinned contracts, and a user's
  Safe is not one.

A folder holds `SKILL.md` (frontmatter `name` and `description`, then at most 4 KiB the model
reads) and, optionally, `skill.toml`, which is what edw-tui enforces:

- `[[contract]]`: the only contracts its plans may call, pinned by address per chain, with the
  functions allowed as signatures (`"function supply(address asset,uint256 amount,…)"`).
  Functions that approve or move tokens themselves (`approve`, `permit`, `transfer`…) or take
  raw `bytes` are refused. `amounts = { supply = { amount = "asset" } }` makes the review show
  that amount in the asset's units.
- `[[token]]`: tokens it names; `movable = false` ones are never approved.
- `[[read_tool]]` and `[[action]]`: scripts, their JSON schemas, and for actions the contracts
  they may `approves`.
- `hosts`: the HTTP hosts its scripts may reach.

**Consent.** On start, the TUI shows an approval card for each skill that is new, changed
(its folder hash differs from `skills.lock`) or asks for more hosts. The card lists what it
needs, its web hosts and tools, and, per chain, every contract with its functions and the
tokens it may approve. Only `y` lets it in (`n` or Esc declines, ↑↓ scroll); chat waits until
every card is answered.

**The Skills tab** (Tab, or `/skills`) lists every installed skill with its state, and below it
what the selected one can touch. Changes apply at once: the agent is rebuilt with the new set,
and the conversation, model and loaded skills carry over.

| Key | |
|---|---|
| ↑↓ | select |
| `d` | disable: off and never asked about until enabled (recorded in `skills.lock`) |
| `e` | enable a disabled or declined skill; its approval card comes up first |
| `a` | add: type a folder path (`~/` works); it is checked, shown on its approval card, and copied to `~/.config/edw-tui/skills/<name>` (`EDW_TUI_SKILLS_USER_DIR`). Declined means not kept. |
| `x` | delete a skill you added, after a y/n. Shipped skills (`./skills`) can only be disabled. |

A card you decline is not shown again this session, until you enable that skill.

**Scripts run in Docker** (`skills/_sdk/edw_skill.py` is the protocol helper), one throwaway
container per call: no network, read-only root and mounts, no capabilities, the `nobody` user,
none of the host's environment, 20 s and 1 MiB of output at most. A script gets data only by
asking edw-tui: HTTP to its declared hosts (HTTPS, no redirects, cached, logged), and read-only
RPC (`eth_call`, `eth_getLogs` over at most 10,000 blocks, balances). Without Docker, skills that
have scripts are off; they never run unsandboxed.

**Actions return a plan, never a transaction.** edw-tui checks every step against the
manifest:
- every call goes to a pinned contract and an allowed function on this chain;
- every address argument is `$self` or a manifest id, never a raw address;
- approvals are exact, to the action's own spenders, and never unlimited;
- a plan has at most 6 steps.

It then simulates the whole plan in one block with `eth_simulateV1`, and writes the review
from the ABI and the simulated asset changes, never from the skill. An RPC without
`eth_simulateV1` refuses skill actions. After `y`, the steps are sent in order like a swap's.

```text
Skill    aave-v3-lend 0.1.0 (sha256 cdeb94c7f8e2)
From     default (0/0) 0x08ba…F543 on mainnet (chain 1)
Step 1   approve 100 USDC for Aave Pool
Step 2   Aave Pool.supply(asset=USDC, amount=100 USDC (100000000), onBehalfOf=you, referralCode=0)
Changes  +99.999999 aUSDC, −100 USDC (simulated)
Max fee  0.00007854597108402 ETH
```

To try Aave on a mainnet fork:

```bash
anvil --fork-url "$ETH_RPC_URL" --port 8546 &
EDW_TUI_MAINNET_FORK=1 EDW_TUI_RPC_URL=http://127.0.0.1:8546 cargo run
# then: unlock mainnet · "put 100 USDC where it earns the most"
```

## The model-facing contract

```bash
cargo run -- tools-dump
```

prints everything the model is given (preamble, tool schemas in the exact Ollama wire format,
request settings) with a `contract_version`. The shipped skills are in `skills`: their hash,
the `SKILL.md` text `load_skill` returns, and the tools offered once one is loaded. Evals should read this output, never a copy.
`contract.json` is the committed snapshot; a test fails when the two differ, so any change to
what the model sees shows up in review. Regenerate with `cargo run -- tools-dump > contract.json`.

## Tests

```bash
cargo test                          # unit + integration; edw-backed tests skip without edw
cargo test --test edw_contract      # every tool against the pinned edw
cargo test --test interim           # real ETH sends on a throwaway anvil (needs anvil)
cargo test --test e2e_transfer      # the real binary in a pseudo-terminal: alice sends bob 0.1 ETH;
                                    # screenshots in target/e2e-screenshots/, snapshots in tests/snapshots/
                                    # (review changes with `cargo insta review`)
EDW_TUI_E2E_RECORD=1 cargo test --test e2e_transfer   # also records the session to
                                    # target/e2e-screenshots/transfer.mp4 (needs rsvg-convert, ffmpeg)
cargo test --test interim -- --ignored   # USDC on an anvil fork of Sepolia (network; EDW_TUI_SEPOLIA_RPC)
cargo test --test agent_loop -- --ignored --nocapture   # real Ollama (EDW_TUI_MODEL, EDW_TUI_SWITCH_TO)
cargo test --test skills_sandbox    # what a skill container can and cannot do (needs Docker)
cargo test --test skills_agent      # load_skill gating in the Rig loop (edw, anvil; Docker part optional)
cargo test --test skills_defi_data  # defi-data on recorded API responses (Docker); -- --ignored adds a live run
cargo test --test skills_aave -- --ignored --nocapture   # pinned Aave addresses vs Aave's registry, then
                                    # supply + withdraw on a mainnet fork (network; ETH_RPC_URL, Docker, edw)
EDW_TUI_E2E_RECORD=1 cargo test --test e2e_aave -- --ignored --nocapture   # the same through the real
                                    # terminal: approve the skills, look up rates, supply, withdraw;
                                    # asserts the mined receipts and balances, records
                                    # target/e2e-screenshots/aave.mp4
```

`edw_contract` is what should break when edw changes. To bump the pin: change
`EDW_PINNED_REV` and the install command above, reinstall edw, then fix `build_argv` in
`src/edw.rs` until `edw_contract` passes. Bump `CONTRACT_VERSION` only if what a correct
answer is has changed.
