"""safe_execute: run the Safe's next waiting transaction once enough owners have signed it.

Anyone may send it; the Safe runs it only if the owners' signatures cover exactly these fields.
Signatures are built from the owners' own signatures and from approvals the Safe records on chain,
never from the service's word that someone approved. Before proposing, the Safe itself must agree
on the hash and accept the signatures.
"""

import safe_common as safe
import edw_skill

OLD_CHECK = "function checkNSignatures(bytes32 dataHash,bytes data,bytes signatures,uint256 requiredSignatures) view"
CHECK_150 = "function checkNSignatures(address executor,bytes32 dataHash,bytes signatures,uint256 requiredSignatures) view"
OWN_KINDS = ("EOA", "ETH_SIGN")


def gather(tx, owners, onchain, threshold):
    """{owner as int: signature hex without 0x}: owners' own ECDSA signatures, plus every approval
    the Safe itself records. The service's own `v=1` entries are ignored: the Safe is asked instead."""
    have = {}
    for c in tx.get("confirmations") or []:
        owner, sig = (c.get("owner") or "").lower(), c.get("signature") or ""
        if c.get("signatureType") in OWN_KINDS and owner in owners and len(sig) == 132 and sig[-2:].lower() in ("1b", "1c", "1f", "20"):
            have[int(owner, 16)] = sig[2:]
    for owner in owners:
        if len(have) >= threshold:
            break
        if int(owner, 16) in have:
            continue
        try:
            approved = int(edw_skill.call(tx["safe"], safe.APPROVED, [owner, onchain])[0]) != 0
        except edw_skill.HostError:
            approved = False
        if approved:
            have[int(owner, 16)] = "00" * 12 + owner[2:] + "00" * 32 + "01"
    return have


def main():
    _, args, context = edw_skill.invoke()
    address = safe.safe_address(args.get("address"))
    me = context.get("me")
    chain_id, short = safe.wallet_chain(args, context, "executing")
    version = safe.require_safe(address, chain_id)
    current = int(edw_skill.call(address, safe.NONCE)[0])
    threshold = int(edw_skill.call(address, safe.GET_THRESHOLD)[0])
    owners = [o.lower() for o in edw_skill.call(address, safe.GET_OWNERS)[0]]
    tx, onchain = safe.waiting_tx(address, short, args, current, only_next=True)
    if tx["nonce"] != current:
        edw_skill.fail(f"only the Safe's next nonce ({current}) can run now; nonce {tx['nonce']} has to wait")
    tx = dict(tx, safe=address)
    have = gather(tx, owners, onchain, threshold)
    if len(have) < threshold:
        edw_skill.fail(f"not enough signatures to execute: {len(have)} of {threshold} (contract signatures are not supported)")
    chosen = sorted(have.items())[:threshold]
    joined = "0x" + "".join(sig for _, sig in chosen)
    # 1.5.0 takes the executor and no `data`; earlier versions the other form. Never the other
    # way round: a Safe with no fallback handler answers an unknown selector with an empty success,
    # which would read as "signatures valid".
    if safe.version_tuple(version) >= (1, 5, 0):
        signature, call_args, empty = CHECK_150, [me, onchain, joined, str(threshold)], [me, onchain, "0x", str(threshold)]
    else:
        signature, call_args, empty = OLD_CHECK, [onchain, "0x", joined, str(threshold)], [onchain, "0x", "0x", str(threshold)]
    try:
        edw_skill.call(address, signature, call_args)
    except edw_skill.HostError:
        edw_skill.fail("the Safe rejected these signatures (it checks them before running anything); not sending")
    # Control: the same check with no signatures must fail. If it does not, this call is not
    # reaching a real signature check (an unknown selector falls through to the fallback), and
    # the answer above means nothing.
    try:
        edw_skill.call(address, signature, empty)
    except edw_skill.HostError:
        pass
    else:
        edw_skill.fail("this Safe's signature check could not be confirmed to be real; not sending")
    described = safe.check_warnings(tx, short, chain_id, args)
    approved = sum(1 for _, sig in chosen if sig.endswith("01") and sig[:24] == "00" * 12 and len(sig) == 130 and sig[-66:-2] == "00" * 32)
    edw_skill.plan(
        [{"call": {"contract": "safe", "function": "execTransaction", "args": [
            tx["to"], str(tx["value"]), tx.get("data") or "0x", str(tx["operation"]), str(tx["safeTxGas"]),
            str(tx["baseGas"]), str(tx["gasPrice"]), tx["gasToken"], tx["refundReceiver"], joined,
        ]}}],
        notes=[
            f"nonce {tx['nonce']}: {described['summary']} (read from the calldata)",
            f"{threshold} of {len(owners)} owners' signatures, {approved} of them approvals recorded on chain; the Safe accepted them in a dry check",
        ]
        + [f"warning heard: {w}" for w in described["warnings"]],
    )


main()
