"""safe_info: who controls a Safe and how many must sign, from the Safe service and cross-checked on chain."""

import safe_common as safe
import edw_skill


def main():
    _, args, context = edw_skill.invoke()
    address = safe.safe_address(args.get("address"))
    chain_id, short = safe.chain(args.get("chain"), context)
    info = safe.service(short, f"safes/{address}/")
    if info is None:
        edw_skill.fail(f"{address} is not a Safe on {safe.CHAIN_LABEL[chain_id]} (the Safe service has no record of it)")
    owners, threshold = info["owners"], info["threshold"]
    # The service is a convenience, not an authority: when the wallet is on this very chain,
    # the signer set that decides every transaction is read from the Safe itself, and every
    # field below is derived from what was read there.
    check = None
    if context.get("chain_id") == chain_id:
        try:
            chain_threshold = int(edw_skill.call(address, safe.GET_THRESHOLD)[0])
            chain_owners = list(edw_skill.call(address, safe.GET_OWNERS)[0])
            same = chain_threshold == threshold and sorted(o.lower() for o in chain_owners) == sorted(o.lower() for o in owners)
            check = "owners and threshold match the chain" if same else "MISMATCH: the service disagrees with the chain; the chain's owners and threshold are shown"
            if not same:
                owners, threshold = chain_owners, chain_threshold
        except edw_skill.HostError as error:
            check = f"not checked ({error})"
    else:
        check = f"not checked: the wallet is not on {safe.CHAIN_LABEL[chain_id]}"
    out = {
        "source": "Safe Transaction Service (api.safe.global)",
        "chain": safe.CHAIN_LABEL[chain_id],
        "safe": address,
        "version": info.get("version"),
        "threshold": threshold,
        "owner_count": len(owners),
        "owners": owners,
        "rule": f"{threshold} of {len(owners)} owners must sign",
        "next_nonce": info["nonce"],
        "modules": info.get("modules") or [],
        "guard": None if info.get("guard") in (None, "0x" + "0" * 40) else info["guard"],
        "onchain_check": check,
    }
    if out["modules"]:
        out["warning"] = "Modules can move this Safe's funds without any owner signing"
    me = (context.get("me") or "").lower()
    if me:
        out["you_are_an_owner"] = me in [o.lower() for o in owners]
    edw_skill.result(out)


main()
