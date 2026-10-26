"""aave_borrow: borrow at the variable rate against what the profile supplied. ETH comes through
the WETH gateway, which borrows in the profile's name: a credit delegation of exactly the
amount comes first."""

from decimal import Decimal

import aave_common as aave
import edw_skill

args, context, pool = aave.started()
me = context["me"]
token_id, info, native = aave.asset(context, args.get("token", ""))
symbol = aave.shown(info, native)
amount = aave.base_units(args.get("amount", ""), info["decimals"], symbol)
if not aave.borrowable(pool, info["address"]):
    edw_skill.fail(f"Aave does not lend {symbol} on this chain now (borrowing it is turned off)")

collateral, debt, can_borrow, threshold, _, _ = aave.account(pool, me)
if collateral == 0:
    edw_skill.fail("the profile has no collateral on Aave; supply something first")
value = amount * aave.price(pool, info["address"]) // 10 ** info["decimals"]
if value > can_borrow:
    edw_skill.fail(
        f"Aave lets the profile borrow about {aave.usd(can_borrow)} USD more; "
        f"{aave.whole(amount, info['decimals'])} {symbol} is about {aave.usd(value)} USD"
    )
notes = None
if debt + value:
    after = Decimal(collateral) * threshold / 10_000 / (debt + value)
    if after < Decimal("1.5"):
        notes = [
            f"After this borrow the health factor would be about {aave.cut(after)}, below 1.5: "
            "a small price move could get the collateral liquidated."
        ]

if native:
    gateway = aave.gateway(context)
    owed_token = aave.debt_token(context, token_id)
    delegated = int(edw_skill.call(owed_token["address"], aave.BORROW_ALLOWANCE, [me, gateway])[0])
    steps = []
    if delegated < amount:
        steps.append(edw_skill.approve_step(token_id + "_debt", "gateway", amount))
    steps.append(edw_skill.call_step("gateway", "borrowETH", ["pool", str(amount)] + aave.gateway_rate_mode(context) + ["0"]))
    edw_skill.plan(steps, notes)

edw_skill.plan([edw_skill.call_step("pool", "borrow", [token_id, str(amount), aave.VARIABLE, "0", "$self"])], notes)
