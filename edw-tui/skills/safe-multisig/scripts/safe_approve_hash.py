"""safe_approve_hash: approve a queued Safe transaction on chain, as one of the Safe's owners.

The service names the transaction; the Safe itself says what its hash is. They must agree, so a
service that swapped the payload cannot get an approval for something else.
"""

import safe_common as safe
import edw_skill

HASH = (
    "function getTransactionHash(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,"
    "uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 _nonce) view returns (bytes32)"
)
IS_OWNER = "function isOwner(address owner) view returns (bool)"
NONCE = "function nonce() view returns (uint256)"
APPROVED = "function approvedHashes(address owner,bytes32 hash) view returns (uint256)"


def main():
    _, args, context = edw_skill.invoke()
    address = safe.safe_address(args.get("address"))
    me = context.get("me")
    if not me or not context.get("chain_id"):
        edw_skill.fail("the wallet is locked; unlock a network first (approving needs its chain and address)")
    chain_id, short = safe.chain(args.get("chain"), context)
    if chain_id != context["chain_id"]:
        edw_skill.fail(
            f"the wallet is on {safe.CHAIN_LABEL.get(context['chain_id'], context['chain_id'])}, "
            f"not {safe.CHAIN_LABEL[chain_id]}; switch networks to approve there"
        )
    try:
        owner = edw_skill.call(address, IS_OWNER, [me])[0]
        current = int(edw_skill.call(address, NONCE)[0])
    except edw_skill.HostError:
        edw_skill.fail(f"{address} is not a Safe on {safe.CHAIN_LABEL[chain_id]}")
    if owner not in (True, "true"):
        edw_skill.fail(f"the sending profile {me} is not an owner of this Safe, so its approval would not count")

    page = safe.service(
        short, f"safes/{address}/multisig-transactions/?executed=false&nonce__gte={current}&ordering=nonce&limit=20"
    ) or {}
    pending = page.get("results", [])
    nonce = args.get("nonce")
    if nonce is None or nonce == "":
        nonces = sorted({tx["nonce"] for tx in pending})
        if len(nonces) != 1:
            edw_skill.fail(
                "say which transaction to approve (its nonce); waiting nonces: "
                + (", ".join(map(str, nonces)) or "none")
            )
        nonce = nonces[0]
    nonce = int(nonce)
    if nonce < current:
        edw_skill.fail(f"nonce {nonce} has already been used; the Safe's next nonce is {current}")
    rows = [tx for tx in pending if tx["nonce"] == nonce]
    wanted = (args.get("safe_tx_hash") or "").lower()
    if wanted:
        rows = [tx for tx in rows if tx["safeTxHash"].lower() == wanted]
    if not rows:
        edw_skill.fail(f"no transaction is waiting at nonce {nonce}")
    if len(rows) > 1:
        edw_skill.fail(
            f"{len(rows)} competing proposals share nonce {nonce}; only one can ever run. Pass safe_tx_hash, one of: "
            + ", ".join(tx["safeTxHash"] for tx in rows)
        )
    tx = rows[0]

    onchain = edw_skill.call(
        address,
        HASH,
        [
            tx["to"], str(tx["value"]), tx.get("data") or "0x", str(tx["operation"]), str(tx["safeTxGas"]),
            str(tx["baseGas"]), str(tx["gasPrice"]), tx["gasToken"], tx["refundReceiver"], str(tx["nonce"]),
        ],
    )[0]
    if onchain.lower() != tx["safeTxHash"].lower():
        edw_skill.fail(
            f"the service's transaction at nonce {nonce} does not hash to what the Safe computes "
            f"({tx['safeTxHash']} vs {onchain}); not approving"
        )
    if int(edw_skill.call(address, APPROVED, [me, onchain])[0]) != 0:
        edw_skill.result({"already_approved": True, "safe": address, "nonce": nonce, "safe_tx_hash": onchain})

    described = safe.summarize(tx, short, chain_id)
    if described["warnings"] and not args.get("acknowledge_warnings"):
        edw_skill.fail(
            f"nonce {nonce} is: {described['summary']}. Warnings: " + " | ".join(described["warnings"])
            + ". Tell the user every warning; call again with acknowledge_warnings=true only if they still want to approve."
        )
    edw_skill.plan([{"call": {"contract": "safe", "function": "approveHash", "args": [onchain]}}])


main()
