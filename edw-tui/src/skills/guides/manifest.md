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
address = { 1 = "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2", 11155111 = "0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951" }
# address_arg = "safe"             # instead of `address`: the address comes from the action's input

[[token]]
id = "usdc"
symbol = "USDC"
decimals = 6
address = { 1 = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", 11155111 = "0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8" }
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

Rules the loader enforces: `hosts` are reached over HTTPS only. `run` stays inside the skill
folder. A contract needs exactly one of `address` (per chain id) or `address_arg` (not both, not
neither). Functions that approve or move tokens themselves (`approve`, `permit`, `transfer`, ...)
are refused, and so are functions that take raw `bytes`, unless the contract is an `address_arg`
contract and the function is listed in its `signed_calls`. Text fields are one line with no control
characters. Tool names are unique across all skills and never a built-in's name.

Plans (what an action returns) are at most 6 steps. Each step is one of:

- `{"approve": {"token", "spender", "amount"}}`: `token` is a token id and `spender` a contract id
  from this manifest, not addresses. The spender must be listed in the action's `approves`.
  `amount` is exact (never unlimited).
- `{"call": {"contract", "function", "args"}}`: `contract` is a contract id, `function` is one of
  that contract's listed function names, and `args` is a list. In `args`, an address may be a
  token id, a contract id, or `"$self"` (the sender). A raw `0x` address is refused.
  `signed_calls` functions are the exception: their addresses and bytes are literal `0x` values.
- A step may also carry `"value"`: a decimal string (or small JSON number) of wei. It is allowed
  only on payable functions, and never on a `signed_calls` function. Values are summed across
  the plan.

The user reviews every plan before anything is signed, and the checker rejects any call outside
the manifest.
