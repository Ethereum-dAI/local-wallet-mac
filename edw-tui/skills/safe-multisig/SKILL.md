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
- safe_approve_hash (sends a transaction): approves the Safe's NEXT waiting transaction on chain,
  as the user's profile, which must be an owner. An approval is permanent: it cannot be taken back
  and stays valid until that nonce is used, which is why only the next nonce is offered.
- safe_execute (sends a transaction): runs the Safe's next transaction once enough owners have
  signed (`ready_to_execute` in safe_queue). Anyone may send it.

For both: call safe_queue first, tell the user what the transaction does (the `summary`) and every
warning, then call the tool with the Safe's address and `nonce`. Pass `safe_tx_hash` only when
proposals compete for a nonce. A tool that refuses lists warnings: repeat them, and call again with
`acknowledge_warnings` true only if the user still wants it. "UNKNOWN CALL" means this skill cannot
read what the call does; say so plainly. The review the user confirms shows the decoded calldata,
which is the thing to check. If `mismatch` is true the Safe service's text disagrees with the
calldata: warn, and do not proceed.

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
