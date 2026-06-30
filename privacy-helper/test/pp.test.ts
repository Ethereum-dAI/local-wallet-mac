// test/pp.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { pickEthBalanceHexWei, mapShieldTx, mnemonicFromEntropyHex } from "../src/pp.ts";

const E = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";

test("pickEthBalanceHexWei returns approved native balance as hex", () => {
  const balances = [
    { asset: { contract: E }, amount: 1000n },
    { asset: { contract: E }, amount: 7n, tag: "pending" },
  ];
  assert.equal(pickEthBalanceHexWei(balances as any, E), "0x3e8"); // 1000
});

test("mapShieldTx extracts to/data/value", () => {
  assert.deepEqual(mapShieldTx({ txns: [{ to: "0xpool", data: "0xabcd", value: 5n }] } as any), { to: "0xpool", data: "0xabcd", value: "5" });
});

test("mnemonicFromEntropyHex yields 24 words for 32-byte entropy", () => {
  const m = mnemonicFromEntropyHex("0x" + "00".repeat(32));
  assert.equal(m.split(" ").length, 24);
});
