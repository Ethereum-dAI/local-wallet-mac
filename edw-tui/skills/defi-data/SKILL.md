---
name: defi-data
description: Look up past yields, TVL and volume of DeFi pools and lending markets (DefiLlama, GeckoTerminal).
---
Use these tools to compare where money could earn, before any action:

- top_yields: the best pools or markets by recent yield. `chain` may be any name or chain id
  ("Ethereum", "mainnet", "Base", "Arbitrum One", "1"); leave it out for the wallet's chain.
  Narrow it with `project` (uniswap-v3, aave-v3, lido…), `symbol` (a token, e.g. USDC) or
  `kind` (lend, lp or stake) only when the user asked for that; "top pools" means no kind.
  Show the user at most 3 rows: project, symbol, APY, 30-day mean APY, TVL. If the result has
  a chain note (e.g. the wallet is on a testnet), say it.
- yield_history: how one pool's APY moved, by the `pool_id` top_yields returned.
- dex_pool: live price, liquidity and 24h volume of one DEX pool by its address.

Rules:
- APY is past performance, not a promise. Say so, and name the source and its time.
- LP pools (kind lp) carry impermanent-loss risk; say so when il_risk is "yes".
- Never use these numbers as transaction amounts. Actions read amounts from the chain.
- These are mainnet numbers. On a testnet they only describe mainnet.
