---
name: aave-v3-lend
description: Lend and borrow on Aave v3. Supply USDC, USDT, DAI, WETH or ETH to earn interest, borrow against it, repay, choose what counts as collateral, and check the account's health factor.
---
Read tools: aave_markets (supply and borrow rates; what the user holds, supplied and owes) and
aave_account (collateral, debt, how much more can be borrowed, health factor, each position).

To earn interest:
1. Call aave_markets. On Ethereum you may also compare with defi-data's top_yields(chain="Ethereum",
   kind="lend", symbol=<token>) and say if another lender pays more.
2. If the user did not say which token or how much, ask once. Then call aave_supply with the token
   and the amount in whole tokens (e.g. "100").
3. To get it back, call aave_withdraw with an amount or "all".

ETH: pass token "ETH". It goes through Aave's WETH gateway and is held as aWETH (aave_account
shows it as WETH). "WETH" means the ERC-20 token itself. With ETH:
- supplying sends the ETH as the transaction's value;
- withdrawing first approves exactly that much aWETH to the gateway;
- borrowing first lets the gateway borrow exactly that amount in the user's name (credit
  delegation);
- repaying sends the ETH as the value.

To borrow:
1. Call aave_account first. Tell the user the health factor now and roughly what it would be
   after: collateral_usd x liquidation_threshold_percent / 100 / (debt_usd + borrowed USD).
2. If that is below 1.5, say so plainly before calling aave_borrow. Below 1, Aave liquidates
   part of the collateral, and prices move. Never propose more than
   can_borrow_keeping_health_factor_1_5_usd without saying it is riskier.
3. Call aave_borrow. The review shows the health factor before and after, from a simulation.

To repay, call aave_repay with an amount or "all". "all" needs slightly more than the debt
(interest accrues until it is mined). If the user holds less, say how much is missing.

aave_collateral(token, use_as_collateral) turns a supplied asset's use as collateral on or off.
With debt, turning it off lowers the health factor (Aave refuses below 1): warn first.

Rules:
- The user reviews every transaction; call the tool instead of asking for confirmation.
- Only say funds moved, a loan was taken or debt was repaid when the tool result says the
  transactions succeeded. A declined or failed action sent nothing.
- Rates move with demand and are not guaranteed. Funds carry smart-contract and liquidation risk.
- On Sepolia these are Aave's test tokens from its faucet, not real USDC.
