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
  --rev 1d04b61ac665c3e71db3d33f6cc6411f99e169dd --locked edw

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

## Shield and unshield (Tornado)

These tools run edw's own Tornado Cash commands (`src/tornado/`), as the sending profile (`P`):

| Tool | edw command | Asks first |
|---|---|---|
| `shield` | `shield --token T --amount-formatted N --from 0 --profile P` | yes, with a preview |
| `unshield` | `unshield --token T --amount-formatted N [--to A] --expected-fresh-address F --profile P` | yes, with a preview |
| `prepare_shield` | `shield --prepare --token T --amount-formatted N --profile P` | yes, unless already prepared |
| `next_fresh_address` | `next-fresh-address --peek --profile P` | no; it stores nothing |

`balance` with `private: true` runs `edw balance --detailed -- P`, which lists the shielded
holdings and each unspent note.

- Before anything runs, the harness checks the token and amount against the unlocked network's
  pools, with edw-core's own catalog at the pinned rev. Sepolia has ETH (0.1, 1, 10) and DAI
  (100). Mainnet has ETH, DAI, USDC, USDT and WBTC. `local` has none. The amount must be a sum of
  pool sizes: 1.1 ETH is 1 + 0.1, and 1.15 is refused. A refused call never reaches a review.
- With `--non-interactive`, edw broadcasts without asking, so the review is the only gate. It
  shows the exact command, the network and chain id, and the notes a shield makes. When edw
  batches a shield into one user operation, which installs its EIP-7702 delegation on the
  paying address, the review says so. For an unshield it names the fresh address it withdraws
  to. That address goes to edw as `--expected-fresh-address`, so edw aborts if its next fresh
  address is another one. An unshield's `to` passes the same invented-address guard as
  `transfer`.
- Preparing reserves notes (it spends Tornado nonces), and preparing again reserves different
  ones. So edw's `edw/shield-prepared` answer is saved before the model sees it, in
  `$EDW_DATA_DIR/edw-tui/prepared-shields/<id>.json` (folder 0700, file 0600, never deleted). A
  later `prepare_shield` with the same network, profile, token and amount returns the stored
  one without asking. The model gets the id and the notes' public metadata, never the calls.
- A record is marked `consumed` once an unshield that ends with its calls may have put them on
  chain: edw reported the user operation, or the fresh address was stored while the unshield ran
  (edw stores it only once a bundler accepted the operation), or it could not be read afterwards.
  A consumed record is never reused; the next request prepares new notes. A declined or failed
  attempt marks nothing, so the retry reuses the same notes.
- These files are wallet state, like edw's own database. A seed-only restore cannot recover
  reservations that never reached the chain, and the wallet database must not be rolled back to
  an older backup while exported calls may still be submitted (edw's own warning). Back them up
  with the wallet's data folder.
- On mainnet every Tornado tool is refused unless edw sends through an anvil fork: the interim's
  gate, judged on edw's own RPC (`EDW_TUI_MAINNET_FORK=1`, a loopback address, a node that reports
  a fork URL). Sepolia needs no `EDW_TUI_INTERIM_SEPOLIA`: that opt-in is about the interim
  signing, and edw signs these.
- `--tail-calls` is not a tool argument. 8B models mangle long hex, and a tail call runs
  arbitrary code from the fresh account. Only harness code can attach one, from a stored
  preparation (`PreparedShield::tail_calls`), for a skill plan the user reviewed. The log and
  the model see `<n calls>` in its place.
- Tornado commands get 10 minutes instead of 60 s, because pool sync, proving and the bundler
  receipt can take minutes.

### Private borrow (Sepolia)

The `private-aave-borrow` skill borrows DAI on Aave against shielded ETH and shields the DAI
again, in one user operation that edw signs and sends:

```text
edw unshield --token ETH --amount-formatted 1 --expected-fresh-address F --tail-calls "$AAVE,$SHIELD"
```

1. The model calls `private_aave_borrow(eth, amount)`. The harness refuses anything but DAI on
   Sepolia (there Aave lends the very token the Tornado DAI pool takes), amounts that are not
   pool sums, and an unshield the profile's notes cannot pay for (below).
2. It peeks the fresh address `F` (`next-fresh-address --peek`) and runs the skill's script with
   `F` as `me`: `supply` is the unshielded ETH less a 10% fee reserve, `borrow` the DAI amount.
   The script reads Aave (ETH taken as collateral, DAI lent now, the loan within the ETH's LTV)
   and plans `depositETH(pool, $self)` with the ETH, then `borrow(DAI, amount, $self)`.
3. The plan is checked for the fresh account, read back from its calldata, and must be exactly
   those two calls. It is built for this borrow only and never stored.
4. The DAI shield is prepared (`shield --prepare`), or a stored, unconsumed one reused. It has no
   card of its own: preparing sends nothing.
5. The two halves are checked against each other: the borrowed token is the one the shield's
   approvals are for, the borrow covers what the shield deposits, and the ETH supplied fits in
   the unshield after the fee reserve. Any mismatch refuses the borrow with nothing sent.
6. One card shows the decoded Aave calls, the new DAI notes, the amount unshielded and `F`.
   After a yes, edw unshields with the Aave calls and then the shield's, simulates the whole
   operation and sends nothing if that fails.

The fee reserve is `FEE_RESERVE_BPS`, 10% of the amount: edw-core seeds its own fee quote with a
tenth of the sponsoring note, which is never larger than the amount. A larger proven fee makes edw
refuse before signing.

Before the script runs, the harness reads the profile's notes (`edw balance --detailed`) and picks
them as edw will, with edw-core's own `withdrawal_notes` at the pinned rev (`src/tornado/held.rs`).
It refuses, with no preparation and no card, when the mined ETH notes cannot make the amount
exactly (notes are only unshielded whole), when they could only once pending notes are mined, or
when the notes edw picks are all in pools without a paymaster (on Sepolia, the 10 ETH pool). A
balance edw could not read refuses the borrow too. `tests/held_notes.rs` holds the check to the
binary's own answers.

The collateral and the debt belong to `F`, an address of the same wallet, not to the profile.
Repaying or withdrawing has to come from `F` later; this skill does not do it.

A skill action runs from a fresh account like this only with `account = "fresh"` in its
`[[action]]`; `$self` and `self_only` then mean that account. edw-tui uses it for this flow only,
and a plan checked for one kind of account is refused for the other.

#### Rehearsing it on a Sepolia fork

`tests/fork_private_borrow.rs` runs the whole flow for real on an anvil fork of Sepolia, with no
Sepolia funds and nothing sent to Sepolia:

```bash
npm install -g @pimlico/alto@0.0.21   # the bundler kohaku-rs's fork kit pins; or set ALTO_BIN
EDW_BIN=… cargo test --test fork_private_borrow -- --ignored --nocapture   # edw, anvil, Docker
```

A new wallet whose only RPC is the fork and whose only bundler is a local alto shields two 0.1 ETH
notes into Sepolia's Tornado pool with `edw shield`. The agent then borrows 100 DAI against one of
them, as above: the real script in Docker, the real preparation, one card (approved), and edw
proving and sending the combined unshield. The test checks from chain state that one transaction
carried the user operation, and that the fresh address is an EIP-7702 account with Aave collateral
and at least 100 DAI of variable debt. It also checks that the Tornado DAI pool took exactly 100
DAI and that nothing left the profile's public address. edw must list a mined 100 DAI note, and
the preparation must be consumed. Then the fork's gas price goes to 1.5 and 3 times what the fee
reserve covers, and the same request must be refused before signing, with the note and the
preparation kept.

It prints each stage's time, edw's own log of the unshield, and the proven fee against the reserve.
edw prices the fee at the bundler's slow `maxFeePerGas + maxPriorityFeePerGas`, so the reserve
holds while that stays below `reserve / (gas limit x 1.01)`. On 2026-10-28 that was about 4.2 gwei
for a 0.1 ETH borrow (gas limit 2.38M), against 2 gwei quoted on the fork and 2.2 gwei from public
Pimlico's slow tier the same day. Gas above that is refused before signing, with nothing sent. Up
to about twice that, edw says the fee leaves too little for the Aave deposit; beyond it, the error
is the bundler's simulation revert, `ExecuteError` (`0x5a154675`) of the first tail call.

What it does not cover: the public Pimlico bundler (its gas limits, prices and acceptance), the
paymaster's deposit on Sepolia now rather than at the fork block, and the public RPC's limits
during edw's live sync. Pool history still comes from the Saga indexer, as it does live: the public
RPC no longer serves Sepolia logs that old, so the indexer cannot be turned off here.

## Skills

A skill is a folder under `skills/` that teaches the agent something new, like Claude's
skills. The system prompt lists each skill's name and one-line description; the model calls
`load_skill` to read its instructions, and only then are its tools offered. Four ship here:

- `defi-data`: past yields, TVL and volume of DeFi pools and lending markets, from
  DefiLlama, GeckoTerminal and DexScreener (no API keys). Read-only. A chain may be written
  any way ("Ethereum Mainnet", "mainnet", "Arbitrum One", "1"): CoinGecko's platform list and
  DefiLlama's chain list resolve it, and with none given it is the wallet's chain (Ethereum
  when the wallet is on a testnet).
- `aave-v3-lend`: Aave v3 on Sepolia (Aave's faucet tokens) or an anvil mainnet fork. Requires
  `defi-data`.
  - Supply USDC, USDT, DAI, WETH or ETH, and withdraw it.
  - Borrow at the variable rate, and repay an amount or all of it.
  - Turn a supplied asset's use as collateral on or off.
  - Read the account: collateral, debt, what it can still borrow, health factor (`aave_account`).
  - ETH goes through Aave's WETH gateway. It is sent as the value to supply and repay. Withdrawing
    approves exactly that much aWETH to the gateway. Borrowing lets the gateway borrow exactly
    that amount in the user's name (credit delegation).
  - Every review shows the account's collateral, debt and health factor before and after, from
    the simulation.
  - Where Aave has borrowing of an asset turned off (WETH on its Sepolia market, as of October
    2026), the skill says so instead of building the plan.
- `private-aave-borrow`: borrow DAI against shielded ETH and shield it again, on Sepolia, from an
  unshield's fresh address (see [Private borrow](#private-borrow-sepolia)). Requires
  `aave-v3-lend`.
- `safe-multisig`: read a [Safe](https://safe.global) by address on Ethereum, Gnosis Chain,
  Sepolia, Base and others, and act on its next transaction: `safe_info` (owners, threshold,
  modules), `safe_queue` (what is waiting for signatures, who has not signed), `safe_activity`
  (what it recently executed), and two writes: `safe_approve_hash` and `safe_execute`. The signer
  set and threshold are read from the Safe itself when the wallet is on that chain, and the chain
  wins over the Safe Transaction Service. What a transaction does is read from its own calldata
  (the service's text is only compared against it; a disagreement refuses the action, and a call
  the skill cannot read is a warning the user must hear). The writes:
  - They target the Safe the user names, after checking it runs one of Safe's own contracts
    (version 1.3.0 or newer, so an approval cannot be replayed on another chain), and only its
    next nonce (an on-chain approval cannot be taken back).
  - Both need the Safe's own `getTransactionHash` to equal the service's. `safe_execute` builds the
    signatures from the owners' own signatures and from approvals the Safe records on chain (never
    from the service's word), and has the Safe check them first, with a control that must fail,
    since a Safe with no fallback handler answers an unknown selector with an empty success.
  - The review shows the Safe's full address, what the transaction does read from its bytes, and
    how many signatures of which kind (the sender's own approval is named).
  A user's Safe cannot be pinned in a manifest, so its contract uses `address_arg`: the address is
  the call's own `address` argument, never one the script chose, and only the listed functions may
  be called there. `execTransaction` takes raw `bytes`, so it is declared in `signed_calls`
  (allowed only for such a contract): the Safe itself runs it only if the owners signed exactly
  those arguments. Proposing, rejecting and owner changes are not offered (they need an off-chain
  signature, or the Safe itself as the sender).

A folder holds `SKILL.md` (frontmatter `name` and `description`, then at most 4 KiB the model
reads) and, optionally, `skill.toml`, which is what edw-tui enforces:

- `[[contract]]`: the only contracts its plans may call, pinned by address per chain (or, with
  `address_arg`, at the address the user gave the action; never approvable; `signed_calls`
  names functions the contract authenticates by signature, which may then take raw bytes), with the
  functions allowed as signatures (`"function supply(address asset,uint256 amount,…)"`).
  Functions that approve or move tokens themselves (`approve`, `permit`, `transfer`,
  `approveDelegation`…) or take raw `bytes` are refused. `amounts = { supply = { amount = "asset" } }`
  makes the review show that amount in the asset's units (or name a token id, for a function whose
  token is implied, like a WETH gateway's).
- `[[token]]`: tokens it names. `movable = false` ones are never approved. `approve_to` lists the
  only contracts it may be approved to. `kind = "debt"` marks an Aave debt token: approving it is a
  credit delegation (`approveDelegation`, the spender may borrow in the user's name), and it needs
  `approve_to`.
- `[[read_tool]]` and `[[action]]`: scripts, their JSON schemas, and for actions the contracts
  they may `approves`, and `account = "fresh"` for the private borrow's action.
- `[[review_read]]`: a view call on a pinned contract that every review shows, read in a
  simulation before the plan and after it, with the uint outputs it names
  (`show = { healthFactor = "18", debt = "8 USD" }`).
- `self_only = { withdraw = ["to"] }` on a contract: address parameters where a call pays out;
  a plan may only put the sender there.
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

**Creating a skill.** `/skill new <goal>` or `/skill from-chat` (turn what you just did into a
skill) loads the shipped `skill-creator` skill. The model writes a draft into
`~/.config/edw-tui/skills-drafts/<name>` (`EDW_TUI_SKILLS_DRAFTS_DIR`) with `skill_draft_write`
and checks it with `skill_draft_check`: it loads, scripts parse, and contracts are compared
with Sourcify (each lookup tells sourcify.dev the contract address and chain; set
`EDW_TUI_SKILLS_FACTS=off` to skip it). The model first asks about anything unclear, then calls `skill_draft_plan`, which shows you its plan
(what the skill reads or sends, chain, contracts and hosts) with `y`/`n`. Nothing is written until
you press `y`, and each plan covers one skill: after the model offers a draft, a new plan is
needed. When the check is clean the model calls `skill_draft_install`, and the usual approval card
for the skill follows its reply. Allowing the card installs the skill for every session; declining
it keeps nothing (the draft stays in the drafts folder). The model cannot approve its own plan or
card, and `/skill install <name>` offers any draft the same way yourself. A draft whose check
reports errors is never offered. A skill with actions still goes through the plan checker and per-transaction review.

**Scripts run in Docker** (`skills/_sdk/edw_skill.py` is the protocol helper), one throwaway
container per call: no network, read-only root and mounts, no capabilities, the `nobody` user,
none of the host's environment, 20 s and 1 MiB of output at most. A script gets data only by
asking edw-tui: HTTP to its declared hosts (HTTPS, no redirects, cached, logged), and read-only
RPC (`eth_call`, `eth_getLogs` over at most 10,000 blocks, balances). Without Docker, skills that
have scripts are off; they never run unsandboxed.

**Actions return a plan, never a transaction.** edw-tui checks every step against the
manifest:
- every call goes to a pinned contract and an allowed function on this chain;
- every address argument is `$self` or a manifest id, never a raw address, and where a call pays
  out (a contract's `self_only` parameters) it is `$self`;
- approvals are exact, to the action's own spenders (and the token's `approve_to`), and never
  unlimited; a debt token's is a credit delegation, read as such in the review;
- every approval or delegation a plan grants is used up by the plan: the simulation reads what is
  left of it afterwards, and anything left refuses the plan;
- ETH goes only to payable functions, and the review shows it;
- a plan has at most 6 steps.

It then simulates the whole plan in one block with `eth_simulateV1` and writes the review from the
ABI and the simulated asset changes, never from the skill's scripts. The manifest's review reads
run in a second simulation, before the same steps and after them, so they cannot change what the
first one checked. An RPC without `eth_simulateV1` refuses skill actions. After `y`, the steps are
sent in order like a swap's.

```text
Skill    aave-v3-lend 0.2.0 (sha256 a5e11d2805e6)
From     default (0/0) 0xC853…C2Dd on mainnet (chain 1)
Step 1   allow Aave WETH Gateway to take on up to 0.5 WETH debt in your name (credit delegation)
Step 2   Aave WETH Gateway.borrowETH(pool=Aave Pool, amount=0.5 WETH (500000000000000000), referralCode=0)
Changes  +0.5 ETH, +0.500000000000000001 WETH debt (simulated)
Read     Aave account (simulated, before → after)
           collateral     4618.59 → 4618.59 USD
           debt           0.00 → 1154.64 USD
           can borrow     3717.96 → 2563.31 USD
           health factor  ∞ → 3.31
Max fee  0.000145232455715162 ETH
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
cargo test --test tornado           # shield, unshield and prepare_shield through the review, on an
                                    # anvil that answers as Sepolia (needs edw, anvil)
cargo test --test tornado live -- --ignored --nocapture   # a real Sepolia shield and unshield;
                                    # moves real Sepolia ETH (EDW_TUI_LIVE_PHRASE, EDW_TUI_LIVE_RPC)
cargo test --test private_borrow    # the private borrow through the card and the pinned edw, on the
                                    # anvil that answers as Sepolia (edw, anvil; card tests need Docker)
cargo test --test private_borrow live -- --ignored --nocapture   # a real one on Sepolia
                                    # (EDW_TUI_LIVE_PHRASE with mined ETH notes, EDW_TUI_LIVE_ETH,
                                    # EDW_TUI_LIVE_RPC, Docker)
cargo test --test fork_private_borrow -- --ignored --nocapture   # the whole private borrow on a
                                    # Sepolia fork with a local bundler, then refused at high gas
                                    # (network; edw, anvil, alto, Docker; see Private borrow)
cargo test --test held_notes        # the held-notes check refuses what the pinned edw's unshield
                                    # refuses, on notes mined on that anvil (edw, anvil)
cargo test --test skills_private_borrow -- --ignored --nocapture   # the real script on a Sepolia
                                    # fork, then its calls and a 200 DAI shield's from one account
                                    # (network; EDW_TUI_SEPOLIA_RPC, Docker, anvil)
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
cargo test --test skills_aave -- --ignored --nocapture   # pinned Aave addresses (pool, tokens, aTokens,
                                    # debt tokens, WETH gateway) vs Aave's registry on mainnet and Sepolia
                                    # forks; USDC supply + withdraw and ETH supply, borrow, repay, withdraw
                                    # through the gateway on forks (network; ETH_RPC_URL, EDW_TUI_SEPOLIA_RPC,
                                    # Docker, edw)
EDW_TUI_E2E_RECORD=1 cargo test --test e2e_aave -- --ignored --nocapture   # the same through the real
                                    # terminal: approve the skills, look up rates, supply, withdraw
                                    # (aave.mp4); supply ETH, read the account, borrow USDC, repay
                                    # part then all, stop using the ETH as collateral, withdraw it
                                    # (aave_borrow.mp4). Asserts the mined receipts, balances and
                                    # leftover approvals; videos in target/e2e-screenshots/
```

`edw_contract` is what should break when edw changes. To bump the pin: change
`EDW_PINNED_REV` and the install command above, reinstall edw, then fix `build_argv` in
`src/edw.rs` until `edw_contract` passes. Bump `CONTRACT_VERSION` only if what a correct
answer is has changed.
