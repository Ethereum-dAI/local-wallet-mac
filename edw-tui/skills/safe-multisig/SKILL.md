---
name: safe-multisig
description: Read a Safe multisig (owners, waiting transactions, history) and approve a waiting transaction on chain as an owner.
---
Use these tools when the user names a Safe (a 0x address) and asks about it:

- safe_info: owners, the threshold ("2 of 4 must sign"), version, modules. If `you_are_an_owner`
  is present, say whether the user's profile is one.
- safe_queue: what is waiting for signatures. Per transaction: the plain-English `summary`,
  `signatures`, `still_needs` (who has not signed) and `warnings`. "What needs my signature?"
  means the rows where `you_have_signed` is false.
- safe_activity: what it recently executed.
- safe_approve_hash (sends a transaction): approves one waiting transaction on chain, as the
  user's profile, which must be an owner. Call safe_queue first, tell the user what the
  transaction does and every warning, then call it with the Safe's address and the `nonce`.
  Pass `safe_tx_hash` only when proposals compete for a nonce. If it refuses and lists warnings,
  repeat them and call again with `acknowledge_warnings` true only if the user still wants it.
  The user reviews and confirms before anything is sent. An approval is not execution.
- safe_execute (sends a transaction): runs the Safe's next waiting transaction once enough
  owners have signed (`ready_to_execute` in safe_queue). Anyone may send it; the Safe runs it only
  if the owners signed exactly those fields. Same flow as approving: safe_queue first, say what it
  does and every warning, then call it. It only works on the Safe's next nonce.

`chain` may be a name (Ethereum, Gnosis, Sepolia, Base) or a chain id; leave it out for the
wallet's chain. A locked wallet reads Ethereum.

Rules:
- Only safe_approve_hash and safe_execute send anything, and only after the user confirms. Never
  claim a transaction was approved or executed unless its result says it was sent. Proposing,
  rejecting and owner changes are not available here; they happen in the Safe app.
- Repeat every `warnings` entry to the user in full. A DELEGATECALL runs another contract's code
  as the Safe; an owner or module change changes who controls the money.
- Use the `summary` text as given. Do not guess what an unknown call does.
- If `onchain_check` says MISMATCH, tell the user the service disagrees with the chain and that the
  chain's owners were used.
