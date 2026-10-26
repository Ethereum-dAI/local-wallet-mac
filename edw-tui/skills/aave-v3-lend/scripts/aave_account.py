"""aave_account: the sender's Aave position, its health factor, and each asset supplied or owed."""

from decimal import Decimal

import aave_common as aave
import edw_skill

_, context, pool = aave.started()
me = context["me"]
collateral, debt, can_borrow, threshold, ltv, health = aave.account(pool, me)
# The most debt that keeps the health factor at 1.5: collateral x threshold / 1.5.
keeping_safe = max(Decimal(0), Decimal(collateral) * threshold / 10_000 / Decimal("1.5") - debt)

positions = []
for token_id, info in aave.reserves(context):
    supplied = aave.balance(aave.a_token(context, token_id)["address"], me)
    owed = aave.balance(aave.debt_token(context, token_id)["address"], me)
    if supplied == 0 and owed == 0:
        continue
    row = {"token": info["symbol"]}
    if supplied:
        row["supplied"] = aave.whole(supplied, info["decimals"])
        row["used_as_collateral"] = aave.is_collateral(pool, me, info["address"])
    if owed:
        row["owed"] = aave.whole(owed, info["decimals"])
    positions.append(row)

edw_skill.result({
    "source": f"Aave v3 Pool on chain {context['chain_id']}, read now",
    "health_factor": aave.health(health),
    "collateral_usd": aave.usd(collateral),
    "debt_usd": aave.usd(debt),
    "can_borrow_usd": aave.usd(can_borrow),
    "can_borrow_keeping_health_factor_1_5_usd": aave.usd(min(Decimal(can_borrow), keeping_safe)),
    "ltv_percent": float(Decimal(ltv) / 100),
    "liquidation_threshold_percent": float(Decimal(threshold) / 100),
    "positions": positions,
    "note": "Below a health factor of 1 Aave lets others liquidate part of the collateral. "
    "ETH supplied or borrowed through the gateway shows as WETH.",
})
