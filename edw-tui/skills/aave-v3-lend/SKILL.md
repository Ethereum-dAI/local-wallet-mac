---
name: aave-v3-lend
description: Earn interest on idle USDC, USDT or DAI by supplying it to Aave v3, and withdraw it again.
---
To put idle stablecoins to work:

1. Call aave_markets for Aave's current supply APY on this chain and what the user has supplied.
   On Ethereum you may also compare with defi-data's top_yields(chain="Ethereum", kind="lend",
   symbol=<token>) and say if another lender pays more.
2. If the user did not say which token or how much, ask once. Then call aave_supply with the
   token and the amount in whole tokens (e.g. "100").
3. To get money back, call aave_withdraw with the token and an amount, or "all".

Rules:
- The user reviews every supply and withdrawal; call the tool instead of asking for confirmation.
- APY moves with demand and is not guaranteed. Supplied funds carry smart-contract risk.
- Only say funds moved when the tool result says the transactions succeeded.
- On Sepolia these are Aave's test tokens from its faucet, not real USDC.
