"""dex_pool: one DEX pool's live numbers from GeckoTerminal, or DexScreener when it is rate-limited."""

import json
import re

import chains
import edw_skill

# chain id → (GeckoTerminal network, DexScreener chain)
NETWORKS = {
    1: ("eth", "ethereum"),
    8453: ("base", "base"),
    42161: ("arbitrum", "arbitrum"),
    10: ("optimism", "optimism"),
    137: ("polygon_pos", "polygon"),
    56: ("bsc", "bsc"),
    43114: ("avax", "avalanche"),
}


def number(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def main():
    _, args, context = edw_skill.invoke()
    address = str(args.get("address", "")).lower()
    if not re.fullmatch(r"0x[0-9a-f]{40}", address):
        edw_skill.fail("dex_pool needs the pool's 0x address (40 hex characters)")
    resolved = chains.resolve(args.get("chain"), context)
    chain = resolved["name"]
    networks = NETWORKS.get(resolved["chain_id"])
    if networks is None:
        edw_skill.fail(f"dex_pool has no pool data for {chain}")
    gecko, screener = networks

    status, body = edw_skill.http_get_status(
        f"https://api.geckoterminal.com/api/v2/networks/{gecko}/pools/{address}"
    )
    if status == 200:
        attributes = json.loads(body)["data"]["attributes"]
        edw_skill.result({
            "source": "GeckoTerminal",
            "name": attributes.get("name"),
            "base_token_price_usd": number(attributes.get("base_token_price_usd")),
            "quote_token_price_usd": number(attributes.get("quote_token_price_usd")),
            "liquidity_usd": number(attributes.get("reserve_in_usd")),
            "volume_usd_24h": number((attributes.get("volume_usd") or {}).get("h24")),
            "fee_percent": number(attributes.get("pool_fee_percentage")),
        })

    status, body = edw_skill.http_get_status(
        f"https://api.dexscreener.com/latest/dex/pairs/{screener}/{address}"
    )
    pairs = (json.loads(body).get("pairs") or []) if status == 200 else []
    if not pairs:
        edw_skill.fail(f"no pool data for {address} on {chain} (GeckoTerminal and DexScreener)")
    pair = pairs[0]
    edw_skill.result({
        "source": "DexScreener",
        "name": f"{pair['baseToken']['symbol']} / {pair['quoteToken']['symbol']}",
        "base_token_price_usd": number(pair.get("priceUsd")),
        "liquidity_usd": number((pair.get("liquidity") or {}).get("usd")),
        "volume_usd_24h": number((pair.get("volume") or {}).get("h24")),
    })


main()
