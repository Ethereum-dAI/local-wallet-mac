"""Which chain the user means, however it is written.

"Ethereum Mainnet", "mainnet", "1", "ETH", "Arbitrum One", "BSC": the name goes through
CoinGecko's platform list (names, short names and ids, with their EVM chain id), and the chain
id through DefiLlama's chain list, to the names DefiLlama's pools use. With no chain given, the
wallet's own chain is used; testnets have no DeFi data, so they fall back to Ethereum.
"""

import difflib
import json
import re

import edw_skill

PLATFORMS = "https://api.coingecko.com/api/v3/asset_platforms"
LLAMA_CHAINS = "https://api.llama.fi/v2/chains"
# Words people add that never tell chains apart.
FILLER = {"mainnet", "main", "net", "network", "chain", "blockchain", "the"}
ALIASES = {"eth": 1, "op": 10, "bnb": 56, "matic": 137, "arb": 42161}
TESTNETS = {11155111: "Sepolia", 17000: "Holesky", 560048: "Hoodi", 31337: "a local chain"}


def normalize(text):
    words = re.sub(r"[^a-z0-9]+", " ", str(text).lower()).split()
    return "".join(w for w in words if w not in FILLER)


def _lists():
    chains = json.loads(edw_skill.http_get(LLAMA_CHAINS))
    try:
        platforms = json.loads(edw_skill.http_get(PLATFORMS))
    except (edw_skill.HostError, ValueError):
        # CoinGecko down or rate-limited: DefiLlama's own names still resolve most chains.
        platforms = []
    return platforms, chains


def _by_id(chain_id, chains, asked, note=None):
    names = [c["name"] for c in chains if c.get("chainId") == chain_id]
    if not names:
        edw_skill.fail(f"DefiLlama has no data for chain id {chain_id} ({asked})")
    # The busiest name first: that is the one DefiLlama's pools mostly use.
    names.sort(key=lambda n: -max((c.get("tvl") or 0) for c in chains if c["name"] == n))
    resolved = {"name": names[0], "chain_id": chain_id, "names": names, "asked": asked}
    if note:
        resolved["note"] = note
    return resolved


def resolve(asked, context):
    """{"name", "chain_id", "names": every DefiLlama name for it, "asked", "note"?}."""
    platforms, chains = _lists()
    asked = "" if asked is None else str(asked).strip()
    if not asked:
        chain_id = context.get("chain_id")
        if chain_id in TESTNETS:
            note = (
                f"The wallet is on {TESTNETS[chain_id]}, a testnet with no DeFi data; "
                "these are Ethereum mainnet numbers."
            )
            return _by_id(1, chains, "the wallet's chain", note)
        if chain_id is None:
            edw_skill.fail("say which chain, e.g. Ethereum, Base or Arbitrum")
        return _by_id(chain_id, chains, "the wallet's chain")
    if asked.isdigit():
        return _by_id(int(asked), chains, asked)

    key = normalize(asked)
    if key == "" or key in ALIASES:
        return _by_id(ALIASES.get(key, 1), chains, asked)
    ids = {}
    for p in platforms:
        if p.get("chain_identifier") is None:
            continue
        for field in ("id", "name", "shortname"):
            if p.get(field):
                ids.setdefault(normalize(p[field]), p["chain_identifier"])
    if key in ids:
        return _by_id(ids[key], chains, asked)
    # Chains without an EVM id (Solana, …): DefiLlama's own names.
    for c in chains:
        if normalize(c["name"]) == key:
            if c.get("chainId"):
                return _by_id(c["chainId"], chains, asked)
            return {"name": c["name"], "chain_id": None, "names": [c["name"]], "asked": asked}

    display = sorted({c["name"] for c in chains} | {p["name"] for p in platforms if p.get("name")})
    by_key = {normalize(name): name for name in display}
    close = difflib.get_close_matches(key, list(by_key), n=3, cutoff=0.6)
    hint = f"; did you mean {', '.join(by_key[k] for k in close)}?" if close else ""
    edw_skill.fail(f"unknown chain {asked!r}{hint}")
