"""Build cases.json: intent -> Safe calls, ground truth taken from real Safe transactions.

usage: build_cases.py <dir with eth.json gno.json> <fixtures dir>   (writes cases.json next to this file)
"""
import json, random, sys, pathlib

DATA, FIX = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
HERE = pathlib.Path(__file__).parent
random.seed(11)
COW = "0x9008D19f58AAbD9eD0D60971565AA8510560ab41"
TOKENS = {"USDC": ("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", 6), "USDT": ("0xdAC17F958D2ee523a2206206994597C13D831ec7", 6),
          "DAI": ("0x6B175474E89094C44Da98b954EedeAC495271d0F", 18), "WETH": ("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", 18)}
ROUTER = "0xE592427A0AEce92De3Edee1F18E0157C05861564"
cases = []

def short(x):
    d = x["dataDecoded"]
    return {"to": x["to"], "function": d["method"], "args": [str(p["value"])[:46] for p in d["parameters"]]}

def real_batches():
    seen = set()
    for chain in ("eth", "gno"):
        for r in json.load(open(DATA / f"{chain}.json")):
            dd = r["dataDecoded"]
            if not (dd and dd["method"] == "multiSend"): continue
            vd = dd["parameters"][0].get("valueDecoded") or []
            if len(vd) < 2 or len(vd) > 6 or not all(x.get("dataDecoded") for x in vd): continue
            yield chain, r["safe"], vd

# A/B: finish a real batch from an intent
fam = {"setPreSignature": [], "borrow": [], "mint": []}
for chain, safe, vd in real_batches():
    last = vd[-1]["dataDecoded"]
    m = last["method"]
    if m not in fam: continue
    key = (m, last["parameters"][0]["value"])
    if any(key == k for k, *_ in fam[m]): continue
    fam[m].append((key, chain, safe, vd))
for (key, chain, safe, vd) in fam["setPreSignature"][:10]:
    uid = vd[-1]["dataDecoded"]["parameters"][0]["value"]
    cases.append({"family": "cow_presign", "chain": chain, "safe": safe,
        "intent": f"The batch so far approved the sell token for CoW Protocol. Finish it: authorise CoW order {uid} on-chain so solvers can fill it. Return only that final call, not the earlier ones.",
        "context": {"batch_so_far": [short(x) for x in vd[:-1]]},
        "expect": [{"to": COW, "function": "setPreSignature", "args": [uid, "true"]}], "args_checked": 2})
for (key, chain, safe, vd) in fam["borrow"][:8]:
    t = vd[-1]
    amt = t["dataDecoded"]["parameters"][0]["value"]
    cases.append({"family": "defi_borrow", "chain": chain, "safe": safe,
        "intent": f"Collateral is enabled. Now borrow {amt} base units from the Compound market at {t['to']}. Return only that final call, not the earlier ones.",
        "context": {"batch_so_far": [short(x) for x in vd[:-1]]},
        "expect": [{"to": t["to"], "function": "borrow", "args": [amt]}], "args_checked": 1})
for (key, chain, safe, vd) in fam["mint"][:8]:
    t = vd[-1]
    amt = t["dataDecoded"]["parameters"][0]["value"]
    cases.append({"family": "defi_supply", "chain": chain, "safe": safe,
        "intent": f"The token is approved. Now supply {amt} base units to the Compound market at {t['to']} so it earns interest. Return only that final call, not the earlier ones.",
        "context": {"batch_so_far": [short(x) for x in vd[:-1]]},
        "expect": [{"to": t["to"], "function": "mint", "args": [amt]}], "args_checked": 1})

# C: owner management on a real Safe (owners in getOwners() order)
info = json.load(open(FIX / "info.json"))
safe = info["address"]; owners = info["owners"]
SENT = "0x0000000000000000000000000000000000000001"
newo = ["0x5B38Da6a701c568545dCfcB03FcB875f56beddC4", "0xAb8483F64d9C6d1EcF9b849Ae677dD3315835cb2", "0x4B20993Bc481177ec7E8f571ceCaE8A9e22C02db", "0x78731D3Ca6b7E34aC0F824c42a7cC18A495cabaB"]
ctx = {"safe": safe, "owners_in_getOwners_order": owners, "threshold": info["threshold"]}
for i in range(3):
    o, t = newo[i], random.choice([2, 3, 4])
    cases.append({"family": "owner_add", "safe": safe, "intent": f"Add {o} as an owner and set the threshold to {t}.", "context": ctx,
        "expect": [{"to": safe, "function": "addOwnerWithThreshold", "args": [o, str(t)]}], "args_checked": 2})
for i in (0, 3, 6):
    o = owners[i]; prev = SENT if i == 0 else owners[i - 1]
    cases.append({"family": "owner_remove", "safe": safe, "intent": f"Remove owner {o} and keep the threshold at {info['threshold']}.", "context": ctx,
        "expect": [{"to": safe, "function": "removeOwner", "args": [prev, o, str(info["threshold"])]}], "args_checked": 3})
for j, i in enumerate((1, 4)):
    o = owners[i]; prev = owners[i - 1]
    cases.append({"family": "owner_swap", "safe": safe, "intent": f"Replace owner {o} with {newo[j + 2]}.", "context": ctx,
        "expect": [{"to": safe, "function": "swapOwner", "args": [prev, o, newo[j + 2]]}], "args_checked": 3})
for t in (2, 5):
    cases.append({"family": "threshold", "safe": safe, "intent": f"Change the signing threshold to {t}.", "context": ctx,
        "expect": [{"to": safe, "function": "changeThreshold", "args": [str(t)]}], "args_checked": 1})
for m in newo[:2]:
    cases.append({"family": "module", "safe": safe, "intent": f"Enable the module at {m} on this Safe.", "context": ctx,
        "expect": [{"to": safe, "function": "enableModule", "args": [m]}], "args_checked": 1})

# D/E/F: act on pending transactions from a recorded queue
q = json.load(open(FIX / "queue.json"))["results"]
def qview(e):
    return {"nonce": e["nonce"], "safeTxHash": e["safeTxHash"], "to": e["to"], "value": e["value"], "data": e["data"] or "0x",
            "operation": e["operation"], "confirmations": f"{len(e['confirmations'])} of {e['confirmationsRequired']}"}
qs = [qview(e) for e in q]
qctx = {"safe": safe, "pending_queue": qs}
for e in q:
    for ph in ("Sign the pending transaction at nonce {n}. My wallet is a smart contract, so I can only send on-chain transactions, not off-chain signatures.",
               "I want to approve queued transaction #{n} as an owner. I cannot produce an off-chain signature."):
        cases.append({"family": "sign_existing", "safe": safe, "intent": ph.format(n=e["nonce"]), "context": qctx,
            "expect": [{"to": safe, "function": "approveHash", "args": [e["safeTxHash"]]}], "args_checked": 1})
    v = qview(e)
    cases.append({"family": "execute_signed", "safe": safe,
        "intent": f"Transaction at nonce {e['nonce']} has collected all required signatures. Execute it.", "context": qctx,
        "expect": [{"to": safe, "function": "execTransaction", "args": [v["to"], v["value"], v["data"], str(v["operation"])]}], "args_checked": 4})
    cases.append({"family": "reject", "safe": safe,
        "intent": f"Cancel the pending transaction at nonce {e['nonce']} by replacing it with a rejection.", "context": qctx,
        "expect": [{"to": safe, "function": "", "args": [], "value": "0"}], "args_checked": 0, "safe_nonce": e["nonce"]})

# G/H: token payouts and limited approvals (token addresses and decimals are the knowledge under test)
rcpt = ["0x1c20Fd4b76E2ec0BFd417eD18C02F45c1e8190C0", "0x6C9F86423e5F36D6E42FbC1BAf966d3c1E0B5711", "0x2e7c372981944a94138B5A7D7fDdC8EaeF01B5AD", "0x9E60E47215A9e71c862fef93bA2Bc6F800929114"]
for i, (sym, (addr, dec)) in enumerate(TOKENS.items()):
    for k in range(2):
        a, b = rcpt[(2 * k) % 4], rcpt[(2 * k + 1) % 4]
        x, y = random.choice([100, 250, 1200]), random.choice([5, 40, 75])
        cases.append({"family": "payout", "safe": safe, "context": {"safe": safe},
            "intent": f"Pay {x} {sym} to {a} and {y} {sym} to {b} from this Safe, in one batch.",
            "expect": [{"to": addr, "function": "transfer", "args": [a, str(x * 10 ** dec)]}, {"to": addr, "function": "transfer", "args": [b, str(y * 10 ** dec)]}],
            "args_checked": 2, "unordered": True})
for sym, n in (("USDC", 500), ("USDT", 1000), ("DAI", 300), ("WETH", 2)):
    addr, dec = TOKENS[sym]
    cases.append({"family": "limited_approve", "safe": safe, "context": {"safe": safe},
        "intent": f"Allow the Uniswap V3 router at {ROUTER} to spend exactly {n} {sym} from this Safe for a swap. Do not grant more.",
        "expect": [{"to": addr, "function": "approve", "args": [ROUTER, str(n * 10 ** dec)]}], "args_checked": 2})

json.dump(cases, open(HERE / "cases.json", "w"), indent=1)
import collections
print(len(cases), dict(collections.Counter(c["family"] for c in cases)))
