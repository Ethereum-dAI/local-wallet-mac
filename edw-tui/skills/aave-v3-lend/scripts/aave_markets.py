"""aave_markets: each asset's supply and borrow APY, and what the sender holds, supplied and owes."""

import aave_common as aave
import edw_skill

_, context, pool = aave.started()
me = context["me"]

rows = []
for token_id, info in aave.reserves(context):
    data = aave.reserve(pool, info["address"])
    expected = aave.a_token(context, token_id)
    if expected["address"].lower() != data[8].lower():
        edw_skill.fail(f"Aave reports a different receipt token for {info['symbol']}; refusing to continue")
    debt = aave.debt_token(context, token_id)
    rows.append({
        "token": info["symbol"],
        "supply_apy_percent": aave.apy(data[2]),
        "borrow_apy_percent": aave.apy(data[4]),
        "you_supplied": aave.whole(aave.balance(data[8], me), info["decimals"]),
        "you_owe": aave.whole(aave.balance(debt["address"], me), info["decimals"]) if debt else "0",
        "you_hold": aave.whole(aave.balance(info["address"], me), info["decimals"]),
    })
edw_skill.result({
    "source": f"Aave v3 Pool on chain {context['chain_id']}, read now",
    "note": "Rates move with demand; they are not guaranteed. ETH is supplied and borrowed as the WETH market.",
    "you_hold_eth": aave.whole(edw_skill.get_balance(me), 18),
    "markets": rows,
})
