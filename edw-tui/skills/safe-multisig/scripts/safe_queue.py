"""safe_queue: transactions waiting for signatures on a Safe, in plain English, with who has not signed."""

import safe_common as safe
import edw_skill

MAX = 8
APPROVED = "function approvedHashes(address owner,bytes32 hash) view returns (uint256)"


def main():
    _, args, context = edw_skill.invoke()
    address = safe.safe_address(args.get("address"))
    chain_id, short = safe.chain(args.get("chain"), context)
    info = safe.service(short, f"safes/{address}/")
    if info is None:
        edw_skill.fail(f"{address} is not a Safe on {safe.CHAIN_LABEL[chain_id]}")
    limit = max(1, min(int(args.get("limit", 5) or 5), MAX))
    page = safe.service(
        short,
        f"safes/{address}/multisig-transactions/?executed=false&nonce__gte={info['nonce']}&ordering=nonce&limit={limit}",
    ) or {}
    owners = [o.lower() for o in info["owners"]]
    me = (context.get("me") or "").lower()
    rows = []
    for tx in page.get("results", []):
        signed = [c["owner"].lower() for c in tx.get("confirmations") or []]
        needed = tx.get("confirmationsRequired") or info["threshold"]
        row = safe.summarize(tx, short, chain_id)
        row.update({
            "nonce": tx["nonce"],
            "safe_tx_hash": tx["safeTxHash"],
            "proposed": (tx.get("submissionDate") or "")[:10],
            "signatures": f"{len(signed)} of {needed}",
            "ready_to_execute": len(signed) >= needed,
            "still_needs": [o for o in owners if o not in signed] if len(signed) < needed else [],
        })
        if me and me in owners:
            row["you_have_signed"] = me in signed
        if me and me not in signed and context.get("chain_id") == chain_id:
            # An approval sent on chain (safe_approve_hash) is not in the service's list; the
            # Safe's own record is the truth.
            try:
                approved = int(edw_skill.call(address, APPROVED, [me, tx["safeTxHash"]])[0]) != 0
            except edw_skill.HostError:
                approved = False
            if approved:
                row["you_have_signed"] = True
                row["you_approved_on_chain"] = True
        rows.append(row)
    # The service lists every proposal at a nonce; two at the same nonce are competing, only one can run.
    nonces = [r["nonce"] for r in rows]
    for row in rows:
        if nonces.count(row["nonce"]) > 1:
            row["warnings"].append("another proposal has the same nonce; only one of them can ever run")
    edw_skill.result({
        "source": "Safe Transaction Service (api.safe.global)",
        "chain": safe.CHAIN_LABEL[chain_id],
        "safe": address,
        "rule": f"{info['threshold']} of {len(owners)} owners must sign",
        "next_nonce": info["nonce"],
        "waiting": len(rows),
        "more_than_shown": bool(page.get("next")),
        "transactions": rows,
        "note": "This only reads. To approve one on chain use safe_approve_hash; executing happens in the Safe app.",
    })


main()
