"""aave_withdraw: withdraw an amount, or everything, back to the sending profile. ETH comes
through the WETH gateway, which first needs an approval of exactly that much aWETH."""

import aave_common as aave
import edw_skill

args, context, pool = aave.started()
me = context["me"]
token_id, info, native = aave.asset(context, args.get("token", ""))
symbol = aave.shown(info, native)
receipt = aave.a_token(context, token_id)
supplied = aave.balance(receipt["address"], me)
if supplied == 0:
    edw_skill.fail(f"the profile has no {symbol} supplied to Aave on this chain")

everything = str(args.get("amount", "")).strip().lower() == "all"
if everything:
    units = supplied
else:
    units = aave.base_units(args.get("amount", ""), info["decimals"], symbol)
    if units > supplied:
        edw_skill.fail(
            f"only {aave.whole(supplied, info['decimals'])} {symbol} is supplied; "
            f"cannot withdraw {aave.whole(units, info['decimals'])}"
        )

if native:
    gateway = aave.gateway(context)
    steps = aave.approve_steps("a" + token_id, receipt["address"], "gateway", gateway, me, units)
    steps.append({
        "call": {
            "contract": "gateway",
            "function": "withdrawETH",
            "args": ["pool", str(units), "$self"],
        }
    })
    notes = None
    if everything:
        # The gateway pulls aWETH under an exact approval, and the balance grows every second.
        notes = ["This withdraws what is supplied now; interest earned until it is mined (a few wei) stays supplied."]
    edw_skill.plan(steps, notes)

edw_skill.plan([{
    "call": {
        "contract": "pool",
        "function": "withdraw",
        "args": [token_id, aave.UINT_MAX if everything else str(units), "$self"],
    }
}])
