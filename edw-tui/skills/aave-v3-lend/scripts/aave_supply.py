"""aave_supply: an exact approval (reset to 0 first when some other amount is set), then supply."""

import aave_common as aave
import edw_skill

_, args, context = edw_skill.invoke()
if not context.get("me"):
    edw_skill.fail("the wallet is locked; unlock a network first (Aave needs its chain and address)")
pool = context.get("contracts", {}).get("pool")
if not pool:
    edw_skill.fail(f"this skill does not know Aave v3 on chain {context.get('chain_id')}")
token_id, info = aave.token(context, args.get("token", ""))
amount = aave.base_units(args.get("amount", ""), info["decimals"], info["symbol"])

held = aave.balance(info["address"], context["me"])
if amount > held:
    edw_skill.fail(
        f"not enough {info['symbol']}: the profile holds {aave.whole(held, info['decimals'])}, "
        f"supplying needs {aave.whole(amount, info['decimals'])}"
    )

steps = []
allowance = int(edw_skill.call(info["address"], aave.ALLOWANCE, [context["me"], pool])[0])
if allowance < amount:
    if allowance > 0:
        # USDT refuses to change a non-zero allowance to another non-zero one.
        steps.append({"approve": {"token": token_id, "spender": "pool", "amount": "0"}})
    steps.append({"approve": {"token": token_id, "spender": "pool", "amount": str(amount)}})
steps.append({
    "call": {
        "contract": "pool",
        "function": "supply",
        "args": [token_id, str(amount), "$self", "0"],
    }
})
edw_skill.plan(steps)
