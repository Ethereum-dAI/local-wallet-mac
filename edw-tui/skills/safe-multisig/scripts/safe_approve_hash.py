"""safe_approve_hash: approve a queued Safe transaction on chain, as one of the Safe's owners.

The service names the transaction; the Safe itself says what its hash is. They must agree, so a
service that swapped the payload cannot get an approval for something else.
"""

import safe_common as safe
import edw_skill

IS_OWNER = "function isOwner(address owner) view returns (bool)"
APPROVED = "function approvedHashes(address owner,bytes32 hash) view returns (uint256)"


def main():
    _, args, context = edw_skill.invoke()
    address = safe.safe_address(args.get("address"))
    me = context.get("me")
    chain_id, short = safe.wallet_chain(args, context, "approving")
    try:
        owner = edw_skill.call(address, IS_OWNER, [me])[0]
        current = int(edw_skill.call(address, safe.NONCE)[0])
    except edw_skill.HostError:
        edw_skill.fail(f"{address} is not a Safe on {safe.CHAIN_LABEL[chain_id]}")
    if owner not in (True, "true"):
        edw_skill.fail(f"the sending profile {me} is not an owner of this Safe, so its approval would not count")
    tx, onchain = safe.waiting_tx(address, short, args, current)
    if int(edw_skill.call(address, APPROVED, [me, onchain])[0]) != 0:
        edw_skill.result({"already_approved": True, "safe": address, "nonce": tx["nonce"], "safe_tx_hash": onchain})
    safe.check_warnings(tx, short, chain_id, args)
    edw_skill.plan([{"call": {"contract": "safe", "function": "approveHash", "args": [onchain]}}])


main()
