# A complete small skill: balance-of

### FILE: SKILL.md
```
---
name: balance-of
description: Look up the ETH balance of any address on the wallet's chain. Use when the user asks what an address holds.
---
Call balance_of with the address the user gave. Report the amount in ETH and say which chain it
is from. This only reads; it never needs the wallet unlocked for the lookup itself.
```

### FILE: skill.toml
```
version = "0.1.0"

[[read_tool]]
name = "balance_of"
run = "scripts/balance_of.py"
description = "ETH balance of one address on the wallet's chain."
schema = { type = "object", required = ["address"], properties = { address = { type = "string", description = "The 0x address." } } }
```

### FILE: scripts/balance_of.py
```
import re

import edw_skill

_, args, context = edw_skill.invoke()
address = str(args.get("address", ""))
if not re.fullmatch(r"0x[0-9a-fA-F]{40}", address):
    edw_skill.fail("balance_of needs a 0x address")
wei = edw_skill.get_balance(address)
edw_skill.result({
    "address": address,
    "chain_id": context.get("chain_id"),
    "eth": f"{wei / 10**18:.6f}",
})
```
