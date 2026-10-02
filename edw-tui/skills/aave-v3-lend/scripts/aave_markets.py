"""aave_markets: each stablecoin's supply APY and what the sender has supplied, read on chain."""

import aave_common as aave
import edw_skill

_, _, context = edw_skill.invoke()
pool = context.get("contracts", {}).get("pool")
if not pool:
    edw_skill.fail(f"this skill does not know Aave v3 on chain {context.get('chain_id')}")

rows = []
for token_id, info in context["tokens"].items():
    if not info.get("movable"):
        continue
    apy, a_token_address = aave.supply_apy(pool, info["address"])
    expected = aave.a_token(context, token_id)
    if expected and expected["address"].lower() != a_token_address.lower():
        edw_skill.fail(f"Aave reports a different receipt token for {info['symbol']}; refusing to continue")
    supplied = aave.balance(a_token_address, context["me"])
    rows.append({
        "token": info["symbol"],
        "supply_apy_percent": apy,
        "you_supplied": aave.whole(supplied, info["decimals"]),
        "you_hold": aave.whole(aave.balance(info["address"], context["me"]), info["decimals"]),
    })
edw_skill.result({
    "source": f"Aave v3 Pool on chain {context['chain_id']}, read now",
    "note": "The rate moves with demand; it is not guaranteed.",
    "markets": rows,
})
