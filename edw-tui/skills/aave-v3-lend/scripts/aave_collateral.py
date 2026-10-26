"""aave_collateral: turn using a supplied asset as collateral on or off."""

import aave_common as aave
import edw_skill

args, context, pool = aave.started()
me = context["me"]
token_id, info, native = aave.asset(context, args.get("token", ""))
symbol = aave.shown(info, native)
use = args.get("use_as_collateral")
if isinstance(use, str) and use.strip().lower() in ("true", "false"):
    use = use.strip().lower() == "true"
if not isinstance(use, bool):
    edw_skill.fail("use_as_collateral must be true or false")
if aave.balance(aave.a_token(context, token_id)["address"], me) == 0:
    edw_skill.fail(f"the profile has no {symbol} supplied to Aave on this chain")
if aave.is_collateral(pool, me, info["address"]) == use:
    edw_skill.fail(f"{symbol} is already {'' if use else 'not '}used as collateral; nothing to change")

edw_skill.plan([{
    "call": {
        "contract": "pool",
        "function": "setUserUseReserveAsCollateral",
        "args": [token_id, use],
    }
}])
