"""aave_repay: pay back variable-rate debt, an amount or all of it. A token is approved for exactly
what is repaid; ETH is sent as the value of the WETH gateway's repayETH. "all" covers the debt
plus 0.01% for interest until it is mined: the token's approval is reset to 0 afterwards, and the
gateway returns unused ETH."""

import aave_common as aave
import edw_skill

args, context, pool = aave.started()
me = context["me"]
token_id, info, native = aave.asset(context, args.get("token", ""))
symbol = aave.shown(info, native)
owed = aave.balance(aave.debt_token(context, token_id)["address"], me)
if owed == 0:
    edw_skill.fail(f"the profile owes no {symbol} on Aave on this chain")

everything = str(args.get("amount", "")).strip().lower() == "all"
if everything:
    units = aave.with_interest_margin(owed)
else:
    units = aave.base_units(args.get("amount", ""), info["decimals"], symbol)
    if units > owed:
        edw_skill.fail(
            f"the profile owes {aave.whole(owed, info['decimals'])} {symbol}; "
            "to repay all of it, ask for all"
        )
held = aave.held(info, native, me)
if units > held:
    edw_skill.fail(
        f"not enough {symbol}: repaying needs {aave.whole(units, info['decimals'])}"
        f"{' (the debt and interest until it is mined)' if everything else ''}, "
        f"the profile holds {aave.whole(held, info['decimals'])}"
    )
amount = aave.UINT_MAX if everything else str(units)
notes = None
if everything:
    notes = ["Covers the debt plus 0.01% for interest until it is mined; what is not needed stays with you."]

if native:
    aave.gateway(context)
    edw_skill.plan([{
        "call": {
            "contract": "gateway",
            "function": "repayETH",
            "args": ["pool", amount] + aave.gateway_rate_mode(context) + ["$self"],
            "value": str(units),
        }
    }], notes)

steps = aave.approve_steps(token_id, info["address"], "pool", pool, me, units)
steps.append({
    "call": {
        "contract": "pool",
        "function": "repay",
        "args": [token_id, amount, aave.VARIABLE, "$self"],
    }
})
if everything:
    steps.append({"approve": {"token": token_id, "spender": "pool", "amount": "0"}})
edw_skill.plan(steps, notes)
