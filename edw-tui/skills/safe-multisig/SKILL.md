---
name: safe-multisig
description: Read a Safe multisig - who controls it, what is waiting for signatures, what it recently did.
---
Use these tools when the user names a Safe (a 0x address) and asks about it:

- safe_info: owners, the threshold ("2 of 4 must sign"), version, modules. If `you_are_an_owner`
  is present, say whether the user's profile is one.
- safe_queue: what is waiting for signatures. Per transaction: the plain-English `summary`,
  `signatures`, `still_needs` (who has not signed) and `warnings`. "What needs my signature?"
  means the rows where `you_have_signed` is false.
- safe_activity: what it recently executed.

`chain` may be a name (Ethereum, Gnosis, Sepolia, Base) or a chain id; leave it out for the
wallet's chain. A locked wallet reads Ethereum.

Rules:
- These tools only read. Never claim to have signed, approved or executed anything; signing
  happens in the Safe app or with the owners' own keys.
- Repeat every `warnings` entry to the user in full. A DELEGATECALL runs another contract's code
  as the Safe; an owner or module change changes who controls the money.
- Use the `summary` text as given. Do not guess what an unknown call does.
- If `onchain_check` says MISMATCH, tell the user the service disagrees with the chain and that the
  chain's owners were used.
