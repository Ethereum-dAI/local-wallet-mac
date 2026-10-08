# ToDo: write operations for `safe-multisig`

Status: not started. `safe-multisig` (PR #102) is read-only: `safe_info`, `safe_queue`, `safe_activity`.
This file lists the write operations to add next, in order, and what blocks each.

## Why writes are not in v0.1

A plan may only call contracts pinned in the skill manifest, and a user's own Safe cannot be pinned.
Before any write below that targets the user's Safe (1-4), check whether the "accept skill addrs, per-user lock"
decision from the earlier skills work already allows a per-user target. If not, that is the first thing to build.

## Evidence for the scope

`edw-tui/evals/safe/` measures whether a local model can turn an intent into the right Safe calls
(`bare` = intent and read-tool context only; `recipe` = plus the facts the skill would carry).
The families with a big `bare` to `recipe` gap are the ones the skill must own. Results are in the PR description.
Earlier completion test (40 real MultiSend batches, hide the last call): gemma4 got the function right 12% of the time.

## Writes, in order

1. **Approve a queued transaction on-chain**: `approveHash(safeTxHash)` on the Safe.
   Hash comes from `safe_queue`. Needs per-user target. Smallest write, highest use.
2. **Execute a fully signed transaction**: `execTransaction(to, value, data, operation, ...)` on the Safe,
   using the stored signatures. `safe_queue` already reports `ready_to_execute`.
   Verify the service's calldata hashes to the reported `safeTxHash` before sending.
3. **Reject a queued transaction**: propose an empty self-call at the same nonce.
   Needs an off-chain EIP-712 signature, so it depends on the harness being able to sign a message.
4. **Propose a transfer or batch**: build the `safeTxHash`, sign, post to the service.
   Payout batches go through MultiSendCallOnly (`0x40A2aCCbd92BCA938b02010E17A5b8929b49130D` or the chain's equivalent; confirm the address per chain). This one is a fixed address and can be pinned.
5. **Create a Safe**: `createProxyWithNonce` on the Safe proxy factory. Fixed address, needs no per-user pinning.
6. **Owner and threshold management** (`addOwnerWithThreshold`, `removeOwner`, `swapOwner`, `changeThreshold`, `enableModule`):
   always flagged "changes who controls the Safe"; `removeOwner` and `swapOwner` need `prevOwner` from the on-chain `getOwners()` order.
7. **CoW pre-sign**: `setPreSignature(orderUid, true)` on `0x9008D19f58AAbD9eD0D60971565AA8510560ab41`.

## Reads to add alongside

- Pre-sign check: explain a queued transaction before signing (`summarize` plus an `eth_call` simulation).
- Allowance module limits, guard status.
- List the Safes an address owns.

## Rules every write must carry over

- No unlimited approvals; amounts in base units, token decimals looked up, never guessed.
- Repeat every `warnings` entry in full before asking to confirm.
- Never send a delegatecall except to a known MultiSend contract.
- Trust the chain over the service when owners or threshold disagree.
- Each write ships with: offline Docker test on recorded fixtures, scripted-model unit test, and a mainnet-fork e2e that checks the exact calldata.

## Open questions

- Does the harness expose message signing (EIP-712) to skills? Blocks 3 and 4.
- Which MultiSend deployment per chain should be pinned?
- Should `approveHash` be preferred over the off-chain confirmation when the wallet is a smart account?
