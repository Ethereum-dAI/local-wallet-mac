#!/usr/bin/env python3
"""Convert the evals-local-llm combined benchmark (tests.combined.yaml) into the
flat JSON the `wallet-eval userop` runner consumes.

Eligibility (per task-C brief): only cases whose gold is a SINGLE `transfer`
or `swap` tool call can produce a UserOp through `UserOperationBuilder.
buildDraft`. Everything else is excluded and counted:
  - 0 expected_calls: refusal / ablation cases (gold is "no call")
  - 1 expected_call, tool == "executeTx": aave-*/safe-* categories (the app
    registers no tool for these at all, so gold falls back to executeTx)
  - 1 expected_call, tool in {shield, unshield}: railgun-* cases. NOTE: six of
    these (ids railgun-shield-mt-0001/0002, railgun-unshield-mt-0003..0006)
    are mislabeled under category "multiturn-amount"/"multiturn-to" in the
    source YAML, not "railgun-*" — filtering on category alone would have
    silently let them through. This script filters on the gold tool name in
    expected_calls, not on category, specifically to avoid that trap.
  - anything else (0 or >1 calls with an unrecognized shape): reported as
    "unclassified" rather than silently dropped or force-counted.

For every other field, this is a lossless copy from the source YAML — no
re-derivation.

Usage:
    python3 scripts/convert-userop-eval-dataset.py \
        <path/to/tests.combined.yaml> \
        wallet-macos/Sources/wallet-eval/Dataset/userop_cases.json
"""
import collections
import json
import sys

import yaml


def normalize_case(raw: dict) -> dict:
    vars_ = raw.get("vars", {})
    meta = raw.get("metadata", {})

    if "messages" in vars_:
        turns = [{"role": m["role"], "content": m["content"]} for m in vars_["messages"]]
    else:
        turns = [{"role": "user", "content": vars_["user_message"]}]

    expected_calls = meta.get("expected_calls") or []

    return {
        "id": meta.get("id"),
        "category": meta.get("category"),
        "protocol": meta.get("protocol"),
        "language": meta.get("language"),
        "query_type": meta.get("query_type"),
        "turns": turns,
        "expected_summary": vars_.get("expected_summary"),
        "expected_calls": expected_calls,
    }


def classify(case: dict) -> str:
    calls = case["expected_calls"]
    if len(calls) == 1 and calls[0]["tool"] in ("transfer", "swap"):
        return "eligible"
    if len(calls) == 0:
        return "excluded-no-call"
    if len(calls) == 1 and calls[0]["tool"] == "executeTx":
        return "excluded-executeTx"
    if len(calls) == 1 and calls[0]["tool"] in ("shield", "unshield"):
        return "excluded-railgun"
    return "unclassified"


def main() -> None:
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)

    src_path, dst_path = sys.argv[1], sys.argv[2]

    with open(src_path, "r", encoding="utf-8") as f:
        raw_cases = yaml.safe_load(f)

    all_cases = [normalize_case(c) for c in raw_cases]

    buckets: dict[str, list[dict]] = collections.defaultdict(list)
    for c in all_cases:
        buckets[classify(c)].append(c)

    eligible = buckets["eligible"]

    with open(dst_path, "w", encoding="utf-8") as f:
        json.dump({"schema": "userop-eval/v1", "cases": eligible}, f, indent=2, sort_keys=True)
        f.write("\n")

    print(f"source: {src_path} ({len(all_cases)} total cases)")
    print(f"wrote {len(eligible)} eligible cases to {dst_path}")
    print()
    print("breakdown:")
    for reason in ("eligible", "excluded-no-call", "excluded-executeTx", "excluded-railgun", "unclassified"):
        cases = buckets.get(reason, [])
        if not cases:
            continue
        by_cat = collections.Counter(c["category"] for c in cases)
        print(f"  {reason}: {len(cases)}  {dict(by_cat)}")
    if buckets["unclassified"]:
        print()
        print("UNCLASSIFIED ids (investigate before trusting N):")
        for c in buckets["unclassified"]:
            print(f"    {c['id']}: {c['expected_calls']}")


if __name__ == "__main__":
    main()
