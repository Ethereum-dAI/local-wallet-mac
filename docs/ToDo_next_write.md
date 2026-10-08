# ToDo: write operations for `safe-multisig`

Status: write 1 (approveHash) is built: `safe_approve_hash`, with the new `address_arg` contract kind
(a contract at the address the user names; only that address, only the listed functions, never approvable).
This file lists the other write operations, in order, and what blocks each.

## What blocks the rest

Done: a plan may now call a contract at an address from the action's own arguments (`address_arg`).
Still blocked by the plan checker: any function taking raw `bytes` (`execTransaction`, `multiSend`,
`createProxyWithNonce`), and anything needing an off-chain signature (rejection, proposing).
Owner and threshold changes are not callable directly by an owner at all: only the Safe itself can
call them, so they need `execTransaction` too.

## Evidence for the scope

`edw-tui/evals/safe/` measures whether a local model can turn an intent into the right Safe calls
(`bare` = intent and read-tool context only; `recipe` = plus the facts the skill would carry).
The families with a big `bare` to `recipe` gap are the ones the skill must own. Results are in the PR description.
Earlier completion test (40 real MultiSend batches, hide the last call): gemma4 got the function right 12% of the time.

## Writes, in order

1. **DONE: approve a queued transaction on-chain**: `approveHash(safeTxHash)` on the Safe.
   The Safe's own `getTransactionHash` must match the service's hash; competing nonces need `safe_tx_hash`;
   warnings must be acknowledged. Tested offline, on a mainnet fork, and recorded.
2. **Execute a fully signed transaction**: `execTransaction(to, value, data, operation, ...)` on the Safe,
   using the stored signatures. `safe_queue` already reports `ready_to_execute`.
   Blocked: the function takes raw `bytes`. Needs a checker rule that allows `bytes` only when the harness
   itself rebuilds them from the verified queue entry.
3. **Reject a queued transaction**: propose an empty self-call at the same nonce.
   Needs an off-chain EIP-712 signature, so it depends on the harness being able to sign a message.
4. **Propose a transfer or batch**: build the `safeTxHash`, sign, post to the service.
   Payout batches go through MultiSendCallOnly (`0x40A2aCCbd92BCA938b02010E17A5b8929b49130D` or the chain's equivalent; confirm the address per chain). This one is a fixed address and can be pinned.
5. **Create a Safe**: `createProxyWithNonce` on the Safe proxy factory. Fixed address, needs no per-user pinning, but the function takes raw `bytes` (the initializer), so it is blocked like 2.
6. **Owner and threshold management** (`addOwnerWithThreshold`, `removeOwner`, `swapOwner`, `changeThreshold`, `enableModule`):
   always flagged "changes who controls the Safe"; `removeOwner` and `swapOwner` need `prevOwner` from the on-chain `getOwners()` order.
7. **CoW pre-sign**: `setPreSignature(orderUid, true)` on `0x9008D19f58AAbD9eD0D60971565AA8510560ab41`. Raw `bytes` again, and it must be sent by the Safe, so it rides inside a proposed Safe transaction (4).

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
