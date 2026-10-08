# Writing a script: the `edw_skill` module

Scripts are Python 3, standard library only. They run in a throwaway Docker container with no
network. Every request goes through the harness, which serves it and limits HTTP to `hosts`.

```python
import edw_skill

tool, args, context = edw_skill.invoke()
# context: chain_id, me (sender address), network, wallet ("locked"/"unlocked"),
#          contracts {id: address} and tokens {id: {address, symbol, decimals, movable}}
#          for this chain, from skill.toml. Read addresses from here; never hard-code them.

body = edw_skill.http_get("https://api.example.com/x")        # text; raises HostError
status, body = edw_skill.http_get_status(url)                 # does not raise on non-200
status, body = edw_skill.http_post(url, body)
out = edw_skill.call(to, "function balanceOf(address) view returns (uint256)", [me])  # decoded list
wei = edw_skill.get_balance(address)                          # int
n = edw_skill.block_number()
```

A script ends with exactly one of:

- `edw_skill.result(value)`: a read tool's answer (JSON-serializable). Keep it small: at most 8 KiB
  reaches the model.
- `edw_skill.plan(steps, notes=None)`: an action's transaction plan. `notes` are shown to the user as
  "Skill says (not checked)".
- `edw_skill.fail("one sentence the user can act on")`.

Validate arguments and fail early with a clear message. Read tools run with the wallet locked
(`context["me"]` is None); actions need it unlocked. Put code shared by several scripts in
`scripts/<name>_common.py` and `import` it.
