// test/secret.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { readSecretPayload } from "../src/secret.ts";

test("parses fd payload to EOF", async () => {
  const p = path.join(os.tmpdir(), "sec-" + Date.now());
  const payload = { entropyHex: "0x" + "ab".repeat(32), sidecarSocketPath: "/tmp/ph.sock", daemon: { socketPath: "/tmp/d.sock", token: "t" } };
  fs.writeFileSync(p, JSON.stringify(payload));
  const fd = fs.openSync(p, "r");
  assert.deepEqual(await readSecretPayload(fd), payload);
});
