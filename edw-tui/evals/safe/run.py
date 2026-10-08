"""Ask a local model to turn each intent into Safe calls and score it against ground truth.

usage: run.py <model>  (deepseek-*/org/name models use EF_INTERNAL_INFERENCE_* from the environment)
       run.py <model> [bare|recipe|both] [limit]
  bare    only the intent and the context a read tool would have returned
  recipe  the same plus the facts the safe-multisig skill would carry (signatures, addresses, decimals)
Scoring: a case passes only if every expected call matches function, target and the first `args_checked`
arguments (values compared after lowercasing; amounts are integer base units). Order matters unless `unordered`.
"""
import json, sys, pathlib, urllib.request, collections, re, os

HERE = pathlib.Path(__file__).parent
MODEL = sys.argv[1]; MODE = sys.argv[2] if len(sys.argv) > 2 else "both"; LIMIT = int(sys.argv[3]) if len(sys.argv) > 3 else 10**9
cases = json.load(open(HERE / "cases.json"))[:LIMIT]

BASE = """You prepare transactions for a Safe multisig wallet on Ethereum mainnet. The user states an intent. Answer with the calls the Safe must make, as JSON only:
{"calls":[{"to":"0x...","function":"name","args":[ordered argument values],"value":"0"}],"safe_nonce":null}
Rules: amounts are integers in the token's smallest unit; addresses are full 0x addresses; "args" lists values in the function's parameter order; for a call with no function (a plain value transfer or an empty call) use "function":"" and "args":[]."""
RECIPE = """Facts about Safe and the protocols involved:
- Safe management calls go to the Safe itself: addOwnerWithThreshold(address owner,uint256 _threshold), removeOwner(address prevOwner,address owner,uint256 _threshold), swapOwner(address prevOwner,address oldOwner,address newOwner), changeThreshold(uint256 _threshold), enableModule(address module).
- Owners are a linked list; prevOwner is the owner listed just before the target in getOwners() order, or 0x0000000000000000000000000000000000000001 if the target is first.
- Approve a queued transaction on-chain: call approveHash(bytes32 hash) on the Safe with the transaction's safeTxHash.
- Execute a queued transaction: execTransaction(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,bytes signatures) on the Safe, with the queued transaction's fields.
- Reject a queued transaction: propose a call to the Safe itself with value 0 and no data at the SAME nonce (set safe_nonce to it).
- CoW Protocol settlement contract: 0x9008D19f58AAbD9eD0D60971565AA8510560ab41. Authorise an order on-chain with setPreSignature(bytes orderUid,bool signed) there, signed=true.
- Compound v2 markets (cTokens): supply is mint(uint256 mintAmount), borrow is borrow(uint256 borrowAmount); both are called on the market address.
- ERC-20: transfer(address to,uint256 amount), approve(address spender,uint256 amount). Mainnet tokens: USDC 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 (6 decimals), USDT 0xdAC17F958D2ee523a2206206994597C13D831ec7 (6), DAI 0x6B175474E89094C44Da98b954EedeAC495271d0F (18), WETH 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 (18)."""

REMOTE = MODEL.startswith("deepseek") or "/" in MODEL  # served by an OpenAI-compatible endpoint (EF_INTERNAL_INFERENCE_*)

def ask(prompt):
    if REMOTE:
        body = {"model": MODEL, "temperature": 0, "response_format": {"type": "json_object"}, "messages": [{"role": "user", "content": prompt}]}
        req = urllib.request.Request(os.environ["EF_INTERNAL_INFERENCE_BASE_URL"].rstrip("/") + "/chat/completions", json.dumps(body).encode(),
                                     {"content-type": "application/json", "authorization": "Bearer " + os.environ["EF_INTERNAL_INFERENCE_API_KEY"]})
        return json.load(urllib.request.urlopen(req, timeout=600))["choices"][0]["message"]["content"]
    body = {"model": MODEL, "stream": False, "format": "json", "think": False, "options": {"temperature": 0}, "messages": [{"role": "user", "content": prompt}]}
    req = urllib.request.Request("http://localhost:11434/api/chat", json.dumps(body).encode(), {"content-type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=600))["message"]["content"]

def norm(v):
    if v is None: return ""
    if isinstance(v, bool): return "true" if v else "false"
    s = str(v).strip().lower()
    return {"true": "true", "false": "false"}.get(s, s)

def calls_of(out):
    cs = out.get("calls") if isinstance(out, dict) else None
    if not isinstance(cs, list): return []
    res = []
    for c in cs:
        if not isinstance(c, dict): continue
        a = c.get("args", [])
        a = list(a.values()) if isinstance(a, dict) else (a if isinstance(a, list) else [a])
        res.append({"to": norm(c.get("to")), "function": re.split(r"[( ]", str(c.get("function") or ""))[0].lower(), "args": [norm(x) for x in a]})
    return res

def score(case, out):
    got = calls_of(out); exp = case["expect"]; k = case["args_checked"]
    def key(c): return (c["to"].lower() if c["to"] else "", c["function"].lower(), tuple(norm(x) for x in c["args"][:k]))
    E = [key({"to": norm(e["to"]), "function": e["function"], "args": e["args"]}) for e in exp]
    G = [key(g) for g in got]
    if "safe_nonce" in case and norm(out.get("safe_nonce") if isinstance(out, dict) else None) != norm(case["safe_nonce"]): nonce_ok = False
    else: nonce_ok = True
    full = nonce_ok and (sorted(E) == sorted(G) if case.get("unordered") else E == G)
    fn = [g[1] for g in G] == [e[1] for e in E] if not case.get("unordered") else sorted(g[1] for g in G) == sorted(e[1] for e in E)
    to = [g[0] for g in G] == [e[0] for e in E] if not case.get("unordered") else sorted(g[0] for g in G) == sorted(e[0] for e in E)
    return full, fn, to, got

def prompt(case, recipe):
    p = BASE + ("\n\n" + RECIPE if recipe else "")
    p += "\n\nContext:\n" + json.dumps(case["context"], indent=1) + "\n\nIntent: " + case["intent"] + "\nSafe: " + case["safe"]
    return p

modes = ["bare", "recipe"] if MODE == "both" else [MODE]
report = {}; errors = collections.Counter()
for mode in modes:
    stats = collections.defaultdict(lambda: [0, 0, 0, 0]); log = []
    for c in cases:
        out = {}; err = 0
        for attempt in range(2):
            try: out = json.loads(ask(prompt(c, mode == "recipe"))); err = 0; break
            except Exception: err = 1
        errors[mode] += err
        full, fn, to, got = score(c, out)
        s = stats[c["family"]]; s[0] += 1; s[1] += full; s[2] += fn; s[3] += to
        log.append({"family": c["family"], "intent": c["intent"][:90], "pass": full, "fn": fn, "to": to, "expected": c["expect"], "got": got})
    report[mode] = {"stats": stats, "log": log}
    n = sum(s[0] for s in stats.values())
    print(f"\n== {MODEL} / {mode} ({errors[mode]} unparseable or failed replies): pass {sum(s[1] for s in stats.values())}/{n}  function {sum(s[2] for s in stats.values())}/{n}  target {sum(s[3] for s in stats.values())}/{n}")
    for f, s in stats.items(): print(f"  {f:16s} pass {s[1]}/{s[0]}  fn {s[2]}  to {s[3]}")
json.dump({m: {"stats": r["stats"], "log": r["log"]} for m, r in report.items()}, open(HERE / f"results_{MODEL.replace(':', '_').replace('/', '_')}.json", "w"), indent=1)
