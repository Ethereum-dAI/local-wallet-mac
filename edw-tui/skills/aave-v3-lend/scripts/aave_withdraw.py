"""aave_withdraw: withdraw an amount, or everything, back to the sending profile."""

import aave_common as aave
import edw_skill

_, args, context = edw_skill.invoke()
pool = context.get("contracts", {}).get("pool")
if not pool:
    edw_skill.fail(f"this skill does not know Aave v3 on chain {context.get('chain_id')}")
token_id, info = aave.token(context, args.get("token", ""))
receipt = aave.a_token(context, token_id)
supplied = aave.balance(receipt["address"], context["me"])
if supplied == 0:
    edw_skill.fail(f"the profile has no {info['symbol']} supplied to Aave on this chain")

requested = str(args.get("amount", "")).strip().lower()
if requested == "all":
    amount = aave.UINT_MAX
else:
    units = aave.base_units(requested, info["decimals"], info["symbol"])
    if units > supplied:
        edw_skill.fail(
            f"only {aave.whole(supplied, info['decimals'])} {info['symbol']} is supplied; "
            f"cannot withdraw {aave.whole(units, info['decimals'])}"
        )
    amount = str(units)

edw_skill.plan([{
    "call": {
        "contract": "pool",
        "function": "withdraw",
        "args": [token_id, amount, "$self"],
    }
}])
