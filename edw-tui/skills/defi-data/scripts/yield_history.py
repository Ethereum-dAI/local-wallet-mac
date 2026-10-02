"""yield_history: one pool's daily APY and TVL from DefiLlama, cut to at most 30 points."""

import json
import re

import edw_skill

MAX_POINTS = 30


def main():
    _, args, _ = edw_skill.invoke()
    pool_id = str(args.get("pool_id", ""))
    if not re.fullmatch(r"[0-9a-fA-F-]{8,64}", pool_id):
        edw_skill.fail("yield_history needs the pool_id that top_yields returned")
    days = max(1, min(int(args.get("days", 30) or 30), 90))
    data = json.loads(edw_skill.http_get(f"https://yields.llama.fi/chart/{pool_id}"))["data"]
    data = data[-days:]
    if len(data) > MAX_POINTS:
        step = len(data) / MAX_POINTS
        picked = [data[int(i * step)] for i in range(MAX_POINTS - 1)]
        data = picked + [data[-1]]
    edw_skill.result({
        "source": "DefiLlama yields (yields.llama.fi)",
        "pool_id": pool_id,
        "points": [
            {
                "date": point["timestamp"][:10],
                "apy_base": point.get("apyBase", point.get("apy")),
                "tvl_usd": point.get("tvlUsd"),
            }
            for point in data
        ],
    })


main()
