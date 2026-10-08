# skill.toml: what edw-tui enforces

A skill is `SKILL.md` (frontmatter `name`, `description`; body at most 4 KiB, what you read after
`load_skill`) plus an optional `skill.toml`. No `skill.toml` = instructions only.

```toml
version = "0.1.0"
hosts = ["api.example.com"]        # HTTP hosts its scripts may reach. Nothing else is reachable.
requires = ["defi-data"]           # other skills loaded with this one

[[contract]]                       # the only contracts a plan may call
id = "pool"
label = "Aave Pool"
functions = ["function supply(address asset,uint256 amount,address onBehalfOf,uint16 referralCode)"]
amounts = { supply = { amount = "asset" } }   # show `amount` in the units of the `asset` parameter
address = { 1 = "0x8787...", 11155111 = "0x6Ae4..." }   # pinned per chain id
# address_arg = "safe"             # instead of `address`: the address comes from the user's call

[[token]]
id = "usdc"
symbol = "USDC"
decimals = 6
address = { 1 = "0xA0b8...", 11155111 = "0x94a9..." }
movable = true                     # false = named in the review, never approved

[[read_tool]]                      # a script that only reads and returns data
name = "pool_info"
run = "scripts/pool_info.py"
description = "One sentence the model sees when choosing the tool."
cache = { "https://api.example.com/pools" = "15m" }   # URL prefix = how long a response is kept
schema = { type = "object", required = ["asset"], properties = { asset = { type = "string" } } }

[[action]]                         # a script that returns a transaction plan the user reviews
name = "supply"
run = "scripts/supply.py"
description = "Supply an asset."
approves = ["pool"]                # contracts it may approve as spender (exact amounts only)
schema = { type = "object", required = ["amount"], properties = { amount = { type = "string" } } }
```

Rules the loader enforces: `run` stays inside the skill folder; functions that approve or move
tokens themselves (`approve`, `permit`, `transfer`, ...) or take raw `bytes` are refused (plans
approve only through the checked `approve` step); text fields are one line with no control
characters; tool names are unique across all skills and never a built-in's name.

Plans (what an action returns) are at most 6 steps: `{"approve": {"token", "spender", "amount"}}`
or `{"call": {"contract", "function", "args"}}`. The user reviews every plan before anything is
signed, and the checker rejects any call outside the manifest.
