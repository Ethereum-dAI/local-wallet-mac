"""safe_info: who controls a Safe and how many must sign, from the Safe service and cross-checked on chain."""

import safe_common as safe
import edw_skill

GET_OWNERS = "function getOwners() view returns (address[])"
GET_THRESHOLD = "function getThreshold() view returns (uint256)"


def main():
    _, args, context = edw_skill.invoke()
    address = safe.safe_address(args.get("address"))
    chain_id, short = safe.chain(args.get("chain"), context)
    info = safe.service(short, f"safes/{address}/")
    if info is None:
        edw_skill.fail(f"{address} is not a Safe on {safe.CHAIN_LABEL[chain_id]} (the Safe service has no record of it)")
    owners = info["owners"]
    out = {
        "source": "Safe Transaction Service (api.safe.global)",
        "chain": safe.CHAIN_LABEL[chain_id],
        "safe": address,
        "version": info.get("version"),
        "threshold": info["threshold"],
        "owner_count": len(owners),
        "owners": owners,
        "rule": f"{info['threshold']} of {len(owners)} owners must sign",
        "next_nonce": info["nonce"],
        "modules": info.get("modules") or [],
        "guard": None if info.get("guard") in (None, "0x" + "0" * 40) else info["guard"],
    }
    if out["modules"]:
        out["warning"] = "Modules can move this Safe's funds without any owner signing"
    me = (context.get("me") or "").lower()
    if me:
        out["you_are_an_owner"] = me in [o.lower() for o in owners]
    # The service is a convenience, not an authority: when the wallet is on this very chain,
    # the signer set that decides every transaction is read from the Safe itself.
    if context.get("chain_id") == chain_id:
        try:
            chain_threshold = int(edw_skill.call(address, GET_THRESHOLD)[0])
            chain_owners = [o.lower() for o in edw_skill.call(address, GET_OWNERS)[0]]
            same = chain_threshold == info["threshold"] and sorted(chain_owners) == sorted(o.lower() for o in owners)
            out["onchain_check"] = "owners and threshold match the chain" if same else "MISMATCH: the service disagrees with the chain; trust the chain"
            if not same:
                out["threshold"], out["owners"] = chain_threshold, chain_owners
        except edw_skill.HostError as error:
            out["onchain_check"] = f"not checked ({error})"
    else:
        out["onchain_check"] = f"not checked: the wallet is not on {safe.CHAIN_LABEL[chain_id]}"
    edw_skill.result(out)


main()
