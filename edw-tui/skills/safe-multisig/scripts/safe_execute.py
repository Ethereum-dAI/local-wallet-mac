"""safe_execute: run the Safe's next waiting transaction once enough owners have signed it.

Anyone may send it; the Safe runs it only if the owners' signatures cover exactly these fields.
Before proposing, the Safe itself must agree on the hash and accept the signatures.
"""

import safe_common as safe
import edw_skill

THRESHOLD = "function getThreshold() view returns (uint256)"
CHECK = "function checkNSignatures(bytes32 dataHash,bytes data,bytes signatures,uint256 requiredSignatures) view"
CONTRACT_SIGNATURE = "CONTRACT_SIGNATURE"


def signatures(tx, threshold):
    """`threshold` owners' signatures, concatenated and sorted by owner address, as the Safe wants."""
    usable = []
    for c in tx.get("confirmations") or []:
        if c.get("signatureType") == CONTRACT_SIGNATURE:
            continue  # needs a dynamic part this skill does not build
        sig = (c.get("signature") or "")[2:]
        if len(sig) == 130:
            usable.append((int(c["owner"], 16), sig))
    if len(usable) < threshold:
        return None
    usable.sort()
    return "0x" + "".join(sig for _, sig in usable[:threshold])


def main():
    _, args, context = edw_skill.invoke()
    address = safe.safe_address(args.get("address"))
    chain_id, short = safe.wallet_chain(args, context, "executing")
    try:
        current = int(edw_skill.call(address, safe.NONCE)[0])
        threshold = int(edw_skill.call(address, THRESHOLD)[0])
    except edw_skill.HostError:
        edw_skill.fail(f"{address} is not a Safe on {safe.CHAIN_LABEL[chain_id]}")
    tx, onchain = safe.waiting_tx(address, short, args, current, only_next=True)
    if tx["nonce"] != current:
        edw_skill.fail(f"only the Safe's next nonce ({current}) can run now; nonce {tx['nonce']} has to wait")
    joined = signatures(tx, threshold)
    if joined is None:
        have = len(tx.get("confirmations") or [])
        edw_skill.fail(f"not enough signatures to execute: {have} of {threshold} (contract signatures are not supported)")
    try:
        edw_skill.call(address, CHECK, [onchain, "0x", joined, str(threshold)])
    except edw_skill.HostError:
        edw_skill.fail("the Safe rejected these signatures (it checks them before running anything); not sending")
    safe.check_warnings(tx, short, chain_id, args)
    edw_skill.plan([{"call": {"contract": "safe", "function": "execTransaction", "args": [
        tx["to"], str(tx["value"]), tx.get("data") or "0x", str(tx["operation"]), str(tx["safeTxGas"]),
        str(tx["baseGas"]), str(tx["gasPrice"]), tx["gasToken"], tx["refundReceiver"], joined,
    ]}}])


main()
