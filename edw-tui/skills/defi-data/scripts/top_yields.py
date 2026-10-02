"""top_yields: DefiLlama's pool list, filtered and sorted here so the model sees a handful of rows."""

import json

import edw_skill

SOURCE = "DefiLlama yields (yields.llama.fi)"
LENDING = {
    "aave-v3", "aave-v2", "compound-v3", "compound-v2", "spark", "sparklend", "morpho-blue",
    "morpho-v1", "fluid-lending", "euler-v2", "radiant-v2", "venus-core-pool", "moonwell-lending",
}
STAKING = {"lido", "rocket-pool", "binance-staked-eth", "coinbase-wrapped-staked-eth", "frax-ether", "stakewise-v2", "mantle-staked-eth", "ether.fi-stake"}
MAX_ROWS = 10


def matches_kind(pool, kind):
    project = pool.get("project", "")
    if kind == "lend":
        return project in LENDING and pool.get("exposure") == "single"
    if kind == "stake":
        return project in STAKING
    if kind == "lp":
        return pool.get("exposure") == "multi"
    return True


def holds(pool, symbol):
    parts = [p.upper() for p in str(pool.get("symbol", "")).replace("/", "-").split("-")]
    return symbol.upper() in parts


def apy_of(pool):
    value = pool.get("apyBase")
    if value is None:
        value = pool.get("apy")
    return value if isinstance(value, (int, float)) else None


def main():
    _, args, _ = edw_skill.invoke()
    chain = str(args.get("chain", "")).strip()
    if not chain:
        edw_skill.fail("top_yields needs a chain, e.g. Ethereum")
    project = args.get("project")
    symbol = args.get("symbol")
    kind = args.get("kind")
    min_tvl = float(args.get("min_tvl_usd", 1_000_000) or 0)
    limit = max(1, min(int(args.get("limit", 5) or 5), MAX_ROWS))

    pools = json.loads(edw_skill.http_get("https://yields.llama.fi/pools"))["data"]
    rows = []
    for pool in pools:
        if str(pool.get("chain", "")).lower() != chain.lower():
            continue
        if project and pool.get("project") != project:
            continue
        if symbol and not holds(pool, symbol):
            continue
        if kind and not matches_kind(pool, kind):
            continue
        if (pool.get("tvlUsd") or 0) < min_tvl or pool.get("outlier"):
            continue
        apy = apy_of(pool)
        if apy is None:
            continue
        rows.append((apy, pool))
    rows.sort(key=lambda row: row[0], reverse=True)
    edw_skill.result({
        "source": SOURCE,
        "note": "APY is past performance over DefiLlama's window, not a promise.",
        "matched": len(rows),
        "rows": [
            {
                "project": pool.get("project"),
                "symbol": pool.get("symbol"),
                "pool_meta": pool.get("poolMeta"),
                "tvl_usd": round(pool.get("tvlUsd") or 0),
                "apy_base": round(apy, 3),
                "apy_reward": pool.get("apyReward"),
                "apy_mean_30d": None if pool.get("apyMean30d") is None else round(pool["apyMean30d"], 3),
                "volume_usd_7d": None if pool.get("volumeUsd7d") is None else round(pool["volumeUsd7d"]),
                "il_risk": pool.get("ilRisk"),
                "pool_id": pool.get("pool"),
            }
            for apy, pool in rows[:limit]
        ],
    })


main()
