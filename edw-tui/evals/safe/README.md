# Safe intent eval

Can a local model turn an intent ("sign the pending tx at nonce 1445", "finish this CoW order") into the right Safe calls?
62 cases in 13 families. Ground truth comes from real Safe transactions (CoW pre-sign, Compound borrow/supply) and from
recorded Safe state (owners, queue); owner, payout and approval cases are synthesised from the ABI.

    python3 -I build_cases.py <dir with eth.json gno.json> ../../tests/fixtures/safe   # regenerate cases.json
    python3 -I run.py gemma4:latest both          # Ollama; modes: bare | recipe | both

`bare` gives the model the intent and the context a read tool would return. `recipe` adds the facts the skill would carry
(function signatures, CoW and token addresses, decimals, linked-list owner rule). A case passes only if every expected call
matches function, target and the checked arguments, in order (payouts: any order). Temperature 0, one run per case.
`results_*.json` are local output and not committed.
