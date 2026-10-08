"""Shared by the safe-multisig tools: the Safe Transaction Service, EIP-55, and plain-English labels.

The labels are rules, not a model's guess: a recorded sample of ~3,300 executed Safe transactions
on Ethereum and Gnosis Chain (80 busy Safes each) showed a handful of shapes covering most
human-driven activity, and gemma4 asked to complete such a batch got the last call's function
right only 12% of the time. So the shapes are matched here, and the model only phrases the result.
"""

import json
import re

import edw_skill

SERVICE = "https://api.safe.global/tx-service"
# Chains the Transaction Service shortnames cover that this wallet may be unlocked on.
SHORTNAMES = {1: "eth", 100: "gno", 11155111: "sep", 10: "oeth", 137: "pol", 42161: "arb1", 8453: "base"}
NAMES = {
    "ethereum": 1, "mainnet": 1, "eth": 1, "gnosis": 100, "gnosis chain": 100, "xdai": 100, "gno": 100,
    "sepolia": 11155111, "optimism": 10, "polygon": 137, "arbitrum": 42161, "base": 8453,
}
CHAIN_LABEL = {1: "Ethereum", 100: "Gnosis Chain", 11155111: "Sepolia", 10: "Optimism", 137: "Polygon", 42161: "Arbitrum One", 8453: "Base"}

COW_SETTLEMENT = "0x9008d19f58aabd9ed0d60971565aa8510560ab41"
# Safe's own MultiSend deployments: a delegatecall to these is just batching.
MULTISEND = {
    a.lower() for a in (
        "0x40A2aCCbd92BCA938b02010E17A5b8929b49130D", "0x9641d764fc13c8B624c04430C7356C1C7C8102e2",
        "0xA238CBeb142c10Ef7Ad8442C6D1f9E89e07e7761", "0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526",
        "0x218543288004CD07832472D464648173c77D7eB7", "0xA83c336B20401Af773B6219BA5027174338D1836",
    )
}
# Functions that change who controls the Safe or what may act as it.
CONTROL = {
    "addOwnerWithThreshold": "adds an owner", "removeOwner": "removes an owner", "swapOwner": "replaces an owner",
    "changeThreshold": "changes how many signatures are needed", "enableModule": "enables a module that can move funds without signatures",
    "disableModule": "disables a module", "setGuard": "sets a transaction guard", "setFallbackHandler": "changes the fallback handler",
}
# Common tokens by chain, so an amount reads as "2,500 USDC". Anything else falls back to the service.
KNOWN = {
    1: {"0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48": ("USDC", 6), "0xdac17f958d2ee523a2206206994597c13d831ec7": ("USDT", 6),
        "0x6b175474e89094c44da98b954eedeac495271d0f": ("DAI", 18), "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2": ("WETH", 18)},
    100: {"0xddafbb505ad214d7b80b1f830fccc89b60fb7a83": ("USDC", 6), "0x4ecaba5870353805a9f068101a40e0f32ed605c6": ("USDT", 6),
          "0xe91d153e0b41518a2ce8dd3d7944fa863463a97d": ("WXDAI", 18), "0xcb444e90d8198415266c6a2724b7900fb12fc56e": ("EURe", 18)},
}


# --- Keccak-256 (EIP-55 needs it; the container's hashlib has only NIST SHA-3) -----------------
_RC = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000, 0x000000000000808B,
    0x0000000080000001, 0x8000000080008081, 0x8000000000008009, 0x000000000000008A, 0x0000000000000088,
    0x0000000080008009, 0x000000008000000A, 0x000000008000808B, 0x800000000000008B, 0x8000000000008089,
    0x8000000000008003, 0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]
_ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]
_M = (1 << 64) - 1


def _rol(x, n):
    return ((x << n) | (x >> (64 - n))) & _M if n else x


def keccak256(data):
    state = [[0] * 5 for _ in range(5)]
    padded = bytearray(data) + b"\x01"
    padded += b"\x00" * (-len(padded) % 136)
    padded[-1] |= 0x80
    for off in range(0, len(padded), 136):
        for i in range(17):
            state[i % 5][i // 5] ^= int.from_bytes(padded[off + 8 * i: off + 8 * i + 8], "little")
        for rc in _RC:
            c = [state[x][0] ^ state[x][1] ^ state[x][2] ^ state[x][3] ^ state[x][4] for x in range(5)]
            d = [c[(x - 1) % 5] ^ _rol(c[(x + 1) % 5], 1) for x in range(5)]
            state = [[state[x][y] ^ d[x] for y in range(5)] for x in range(5)]
            b = [[0] * 5 for _ in range(5)]
            for x in range(5):
                for y in range(5):
                    b[y][(2 * x + 3 * y) % 5] = _rol(state[x][y], _ROT[x][y])
            state = [[b[x][y] ^ (~b[(x + 1) % 5][y] & b[(x + 2) % 5][y]) for y in range(5)] for x in range(5)]
            state[0][0] ^= rc
    return b"".join(state[i % 5][i // 5].to_bytes(8, "little") for i in range(4))[:32]


def checksum(address):
    low = address.lower().removeprefix("0x")
    digest = keccak256(low.encode()).hex()
    return "0x" + "".join(c.upper() if int(digest[i], 16) >= 8 else c for i, c in enumerate(low))


def safe_address(value):
    text = str(value or "").strip()
    if not re.fullmatch(r"0x[0-9a-fA-F]{40}", text):
        edw_skill.fail("give the Safe's 0x address (40 hex characters)")
    return checksum(text)


# --- Chain and service ---------------------------------------------------------------------------
def chain(asked, context):
    """(chain_id, shortname). With nothing asked, the wallet's chain; a locked wallet means Ethereum."""
    if asked in (None, ""):
        chain_id = context.get("chain_id") or 1
    elif str(asked).isdigit():
        chain_id = int(asked)
    else:
        chain_id = NAMES.get(str(asked).strip().lower())
    if chain_id not in SHORTNAMES:
        edw_skill.fail(f"the Safe service does not cover {asked!r}; try one of {', '.join(sorted(CHAIN_LABEL.values()))}")
    return chain_id, SHORTNAMES[chain_id]


def service(short, path):
    status, body = edw_skill.http_get_status(f"{SERVICE}/{short}/api/v1/{path}")
    if status == 404:
        return None
    if status != 200:
        edw_skill.fail(f"the Safe service answered HTTP {status} for {path.split('?')[0]}")
    return json.loads(body)


def token_info(short, chain_id, address):
    known = KNOWN.get(chain_id, {}).get(address.lower())
    if known:
        return known
    try:
        data = service(short, f"tokens/{checksum(address)}/")
    except edw_skill.HostError:
        data = None
    if data and data.get("decimals") is not None:
        return data.get("symbol") or "token", int(data["decimals"])
    return None


def amount(raw, decimals):
    raw = int(raw)
    whole, frac = divmod(raw, 10 ** decimals)
    text = f"{whole:,}" + (("." + str(frac).rjust(decimals, "0").rstrip("0")[:6]) if frac and decimals else "")
    return text


def _arg(call, index):
    """The index-th decoded argument. Names differ per token (to/recipient/dst), positions do not."""
    params = (call.get("dataDecoded") or {}).get("parameters") or []
    return params[index]["value"] if index < len(params) else None


def _short(address):
    return f"{address[:6]}…{address[-4:]}"


def describe_call(call, short, chain_id):
    """One call as (text, kind). kind: transfer, swap_order, control, approval, call."""
    data = call.get("data")
    to = call["to"]
    decoded = call.get("dataDecoded") or {}
    method = decoded.get("method")
    if not data or data == "0x":
        wei = int(call.get("value") or 0)
        return (f"sends {amount(wei, 18)} native coin to {_short(to)}" if wei else "does nothing (empty call)"), "transfer"
    if method in CONTROL:
        return f"{CONTROL[method]}", "control"
    if to.lower() == COW_SETTLEMENT and method == "setPreSignature":
        return "places a CoW Protocol swap order (signs it on chain)", "swap_order"
    if method == "transfer":
        info = token_info(short, chain_id, to)
        to_addr, value = _arg(call, 0), _arg(call, 1)
        if info and value is not None and to_addr:
            return f"sends {amount(value, info[1])} {info[0]} to {_short(to_addr)}", "transfer"
        return f"transfers a token ({_short(to)}) to {_short(to_addr or to)}", "transfer"
    if method == "approve":
        info = token_info(short, chain_id, to)
        spender, value = _arg(call, 0), _arg(call, 1)
        token = info[0] if info else f"token {_short(to)}"
        if value is not None and int(value) >= 2 ** 255:
            return f"lets {_short(spender or to)} spend an unlimited amount of {token}", "approval"
        what = f"{amount(value, info[1])} {info[0]}" if info and value is not None else f"an amount of {token}"
        return f"lets {_short(spender or to)} spend {what}", "approval"
    if method:
        return f"calls {method} on {_short(to)}", "call"
    return f"calls {_short(to)} with data {data[:10]}", "call"


def inner_calls(tx):
    decoded = tx.get("dataDecoded") or {}
    if decoded.get("method") == "multiSend":
        for sub in (decoded.get("parameters") or [{}])[0].get("valueDecoded") or []:
            yield sub
    else:
        yield tx


def _payout(calls, parts, short, chain_id):
    """One line for a batch that only pays one token to several recipients."""
    if len(calls) < 2 or any(k != "transfer" for _, k in parts):
        return None
    if any((c.get("dataDecoded") or {}).get("method") != "transfer" for c in calls) or len({c["to"].lower() for c in calls}) != 1:
        return None
    info = token_info(short, chain_id, calls[0]["to"])
    total = sum(int(_arg(c, 1) or 0) for c in calls)
    recipients = len({str(_arg(c, 0)).lower() for c in calls})
    what = f"{amount(total, info[1])} {info[0]}" if info else f"{total} units of token {_short(calls[0]['to'])}"
    return f"Pays {what} to {recipients} recipient{'s' if recipients != 1 else ''} in {len(calls)} transfers"


def summarize(tx, short, chain_id):
    """{"summary", "kind", "warnings"} for one multisig transaction from the service."""
    warnings = []
    to = tx["to"].lower()
    decoded = tx.get("dataDecoded") or {}
    batched = decoded.get("method") == "multiSend"
    if tx.get("operation") == 1 and to not in MULTISEND:
        warnings.append(
            f"DELEGATECALL to {_short(tx['to'])}: that contract's code runs as the Safe and can do anything with it"
        )
    if (not tx.get("data") or tx["data"] == "0x") and int(tx.get("value") or 0) == 0 and to == (tx.get("safe") or "").lower():
        return {
            "summary": f"Rejects the proposal at nonce {tx['nonce']} (an empty call to itself that takes its place)",
            "kind": "rejection",
            "warnings": warnings,
        }
    calls = list(inner_calls(tx))
    if tx.get("operation") == 1 and to in MULTISEND and not calls:
        # An undecoded MultiSend: the service did not understand the batch.
        return {"summary": "a batch of calls the Safe service could not decode", "kind": "batch", "warnings": warnings + ["undecoded batch; check it in the Safe app before signing"]}
    for sub in calls if batched else []:
        if sub.get("operation") == 1:
            warnings.append(f"a call in the batch is a DELEGATECALL to {_short(sub['to'])}")
    if any((c.get("dataDecoded") or {}).get("method") == "approve" and int(_arg(c, 1) or 0) >= 2 ** 255 for c in calls):
        warnings.append("unlimited approval: that address can spend all of this token the Safe holds, now and later")
    parts = [describe_call(c, short, chain_id) for c in calls]
    kinds = {k for _, k in parts}
    payout = _payout(calls, parts, short, chain_id)
    if payout:
        return {"summary": payout, "kind": "payout", "warnings": warnings}
    if len(calls) == 0:
        text, kind = "an empty transaction", "call"
    elif len(parts) == 1:
        (text, kind), = parts
    else:
        kind = "payout" if kinds == {"transfer"} else "swap" if "swap_order" in kinds else "control" if "control" in kinds else "batch"
        shown = "; ".join(t for t, _ in parts[:4]) + (f"; and {len(parts) - 4} more" if len(parts) > 4 else "")
        text = f"{len(parts)} calls in one batch: {shown}"
    if "control" in kinds:
        warnings.append("changes who controls the Safe")
    return {"summary": text[0].upper() + text[1:] if text else text, "kind": kind, "warnings": warnings}
