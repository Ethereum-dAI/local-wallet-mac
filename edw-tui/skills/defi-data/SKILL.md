---
name: defi-data
description: Look up past yields, TVL and volume of DeFi pools and lending markets (DefiLlama, GeckoTerminal).
---
Use these tools to compare where money could earn, before any action:

- top_yields: the best pools or markets by recent yield. Give `chain` (e.g. Ethereum). Narrow it
  with `project` (uniswap-v3, aave-v3, lido…), `symbol` (a token, e.g. USDC) or `kind`
  (lend, lp or stake). Show the user at most 3 rows: project, symbol, APY, 30-day mean APY, TVL.
- yield_history: how one pool's APY moved, by the `pool_id` top_yields returned.
- dex_pool: live price, liquidity and 24h volume of one DEX pool by its address.

Rules:
- APY is past performance, not a promise. Say so, and name the source and its time.
- LP pools (kind lp) carry impermanent-loss risk; say so when il_risk is "yes".
- Never use these numbers as transaction amounts. Actions read amounts from the chain.
- These are mainnet numbers. On a testnet they only describe mainnet.
