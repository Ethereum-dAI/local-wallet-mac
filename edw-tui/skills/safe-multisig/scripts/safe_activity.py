"""safe_activity: what a Safe recently did, one plain-English line per executed transaction."""

import safe_common as safe
import edw_skill

MAX = 10


def main():
    _, args, context = edw_skill.invoke()
    address = safe.safe_address(args.get("address"))
    chain_id, short = safe.chain(args.get("chain"), context)
    limit = max(1, min(int(args.get("limit", 5) or 5), MAX))
    page = safe.service(
        short, f"safes/{address}/multisig-transactions/?executed=true&ordering=-executionDate&limit={limit}"
    )
    if page is None:
        edw_skill.fail(f"{address} is not a Safe on {safe.CHAIN_LABEL[chain_id]}")
    rows = []
    for tx in page.get("results", []):
        row = safe.summarize(tx, short, chain_id)
        row.update({
            "date": (tx.get("executionDate") or "")[:10],
            "nonce": tx["nonce"],
            "succeeded": tx.get("isSuccessful"),
            "signatures": len(tx.get("confirmations") or []),
            "tx_hash": tx.get("transactionHash"),
        })
        rows.append(row)
    kinds = {}
    for r in rows:
        kinds[r["kind"]] = kinds.get(r["kind"], 0) + 1
    edw_skill.result({
        "source": "Safe Transaction Service (api.safe.global)",
        "chain": safe.CHAIN_LABEL[chain_id],
        "safe": address,
        "shown": len(rows),
        "by_kind": kinds,
        "transactions": rows,
    })


main()
