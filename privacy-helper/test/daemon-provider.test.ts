// test/daemon-provider.test.ts
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import fs from "node:fs";
import { createDaemonProvider } from "../src/daemon-provider.ts";

let server: http.Server, socketPath: string, lastBody: any;
before(async () => {
  socketPath = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "dp-")), "d.sock");
  server = http.createServer((req, res) => {
    let d = ""; req.on("data", (c) => (d += c));
    req.on("end", () => {
      lastBody = JSON.parse(d);
      const map: Record<string, unknown> = { eth_chainId: "0xaa36a7", eth_getCode: "0x1234" };
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify({ jsonrpc: "2.0", id: lastBody.id, result: map[lastBody.method] }));
    });
  });
  await new Promise<void>((r) => server.listen(socketPath, r));
});
after(() => server.close());

test("getChainId parses hex", async () => {
  const p = createDaemonProvider({ socketPath, token: "t" });
  assert.equal(await p.getChainId(), 11155111n);
  assert.equal(lastBody.method, "eth_chainId");
});
test("getCode forwards [addr, latest]", async () => {
  const p = createDaemonProvider({ socketPath, token: "t" });
  assert.equal(await p.getCode("0xabc"), "0x1234");
  assert.deepEqual(lastBody.params, ["0xabc", "latest"]);
});
