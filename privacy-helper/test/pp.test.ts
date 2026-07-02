// test/pp.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { splitEthBalanceHexWei, mapShieldTx, mnemonicFromEntropyHex } from "../src/pp.ts";

const E = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";

test("splitEthBalanceHexWei separates approved from pending native balance", () => {
  const balances = [
    { asset: { contract: E }, amount: 1000n },
    { asset: { contract: E }, amount: 7n, tag: "pending" },
  ];
  assert.deepEqual(splitEthBalanceHexWei(balances as any, E), { approved: "0x3e8", pending: "0x7" });
});

test("splitEthBalanceHexWei is 0x0/0x0 when the asset has no notes", () => {
  assert.deepEqual(splitEthBalanceHexWei([] as any, E), { approved: "0x0", pending: "0x0" });
});

test("mapShieldTx extracts to/data/value", () => {
  assert.deepEqual(mapShieldTx({ txns: [{ to: "0xpool", data: "0xabcd", value: 5n }] } as any), { to: "0xpool", data: "0xabcd", value: "5" });
});

test("mnemonicFromEntropyHex yields 24 words for 32-byte entropy", () => {
  const m = mnemonicFromEntropyHex("0x" + "00".repeat(32));
  assert.equal(m.split(" ").length, 24);
});
