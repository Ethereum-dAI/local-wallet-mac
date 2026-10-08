"""safe_approve_hash: approve a queued Safe transaction on chain, as one of the Safe's owners.

The service names the transaction; the Safe itself says what its hash is. They must agree, so a
service that swapped the payload cannot get an approval for something else. What the transaction
does is read from its own calldata, never taken from the service's description.
"""

import safe_common as safe
import edw_skill

IS_OWNER = "function isOwner(address owner) view returns (bool)"


def main():
    _, args, context = edw_skill.invoke()
    address = safe.safe_address(args.get("address"))
    me = context.get("me")
    chain_id, short = safe.wallet_chain(args, context, "approving")
    safe.require_safe(address, chain_id)
    current = int(edw_skill.call(address, safe.NONCE)[0])
    if edw_skill.call(address, IS_OWNER, [me])[0] not in (True, "true"):
        edw_skill.fail(f"the sending profile {me} is not an owner of this Safe, so its approval would not count")
    tx, onchain = safe.waiting_tx(address, short, args, current, only_next=True)
    if tx["nonce"] != current:
        edw_skill.fail(
            f"only the Safe's next nonce ({current}) can be approved here. An on-chain approval never expires and "
            f"cannot be taken back, so approving nonce {tx['nonce']} early is not offered; approve it when its turn comes"
        )
    if int(edw_skill.call(address, safe.APPROVED, [me, onchain])[0]) != 0:
        edw_skill.result({"already_approved": True, "safe": address, "nonce": tx["nonce"], "safe_tx_hash": onchain})
    described = safe.check_warnings(tx, short, chain_id, args)
    edw_skill.plan(
        [{"call": {
            "contract": "safe", "function": "approveHash", "args": [onchain],
            # The harness asks the Safe whether these fields hash to the approved value, and only
            # then explains them in the review.
            "explain": {
                "to": tx["to"], "value": str(tx["value"]), "data": tx.get("data") or "0x", "operation": tx["operation"],
                "safeTxGas": str(tx["safeTxGas"]), "baseGas": str(tx["baseGas"]), "gasPrice": str(tx["gasPrice"]),
                "gasToken": tx["gasToken"], "refundReceiver": tx["refundReceiver"], "nonce": str(tx["nonce"]),
            },
        }}],
        notes=[
            f"nonce {tx['nonce']}: {described['summary']} (read from the calldata)",
            "an on-chain approval cannot be taken back: it stays valid until this nonce is used or you stop being an owner",
        ]
        + [f"warning heard: {w}" for w in described["warnings"]],
    )


main()
