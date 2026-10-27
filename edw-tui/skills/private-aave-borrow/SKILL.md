---
name: private-aave-borrow
description: Borrow DAI on Aave against shielded (Tornado) ETH without linking it to this wallet's addresses, and shield the DAI again, in one transaction. Sepolia only.
---
private_aave_borrow(eth, amount) does it all in one user operation that edw signs and sends:
1. edw unshields `eth` ETH from the user's Tornado notes to a fresh address of this wallet.
2. From that address, the ETH goes to Aave as collateral (all but 10%, kept back for the fee)
   and `amount` DAI is borrowed.
3. The DAI is shielded again, into new 100 DAI notes.

Before calling:
- `eth` must be an exact sum of mined ETH notes the user holds (0.1, 1 and 10 ETH pools). If
  unsure, call balance with private true first and pick a sum of notes that are not pending.
- `amount` is a multiple of 100 (Sepolia's DAI pool is 100 DAI).
- The ETH must back the loan: Aave lends only part of the ETH's value (its LTV), and a health
  factor under 1.5 is risky. aave_markets shows the rates. Suggest leaving a margin.
- If the user did not give both amounts, ask once.

The user reviews one card: the Aave calls, the new DAI notes, the amount unshielded and the
fresh address. Call the tool instead of asking for confirmation. Nothing is sent before a yes,
and edw simulates the whole operation first and sends nothing if it would fail.

After it succeeds, tell the user plainly: the collateral and the DAI debt belong to the fresh
address the card named, not to their profile. Repaying or withdrawing has to come from that
address later; this skill does not do it.

Errors:
- "held notes cannot make ..." means the user holds no exact set of mined notes for that
  amount: suggest an amount they do hold.
- "after a ... sponsor fee the notes leave ..." means the fee was larger than the reserve:
  suggest unshielding more ETH.
- Only say it was done when the result says the user operation was sent. A declined or failed
  call sent nothing.
