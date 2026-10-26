"""aave_supply: an exact approval (reset to 0 first when some other amount is set), then supply.
ETH goes to the WETH gateway as the transaction's value, with no approval."""

import aave_common as aave
import edw_skill

args, context, pool = aave.started()
me = context["me"]
token_id, info, native = aave.asset(context, args.get("token", ""))
symbol = aave.shown(info, native)
amount = aave.base_units(args.get("amount", ""), info["decimals"], symbol)

held = aave.held(info, native, me)
if amount > held:
    edw_skill.fail(
        f"not enough {symbol}: the profile holds {aave.whole(held, info['decimals'])}, "
        f"supplying needs {aave.whole(amount, info['decimals'])}"
    )

if native:
    aave.gateway(context)
    edw_skill.plan([edw_skill.call_step("gateway", "depositETH", ["pool", "$self", "0"], value=amount)])

steps = aave.approve_steps(token_id, info["address"], "pool", pool, me, amount)
steps.append(edw_skill.call_step("pool", "supply", [token_id, str(amount), "$self", "0"]))
edw_skill.plan(steps)
