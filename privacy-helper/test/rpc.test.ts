// test/rpc.test.ts
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import fs from "node:fs";
import { serveRpc } from "../src/rpc.ts";

const socketPath = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "rpc-")), "s.sock");
const post = (body: object, token = "tok") =>
  new Promise<any>((resolve, reject) => {
    const data = JSON.stringify(body);
    const req = http.request(
      { socketPath, path: "/", method: "POST", headers: { "content-type": "application/json", "content-length": Buffer.byteLength(data), authorization: `Bearer ${token}` } },
      (res) => { let d = ""; res.on("data", (c) => (d += c)); res.on("end", () => resolve({ status: res.statusCode, body: d ? JSON.parse(d) : null })); },
    );
    req.on("error", reject); req.write(data); req.end();
  });

let server: http.Server;

// Start one server for the whole suite; tear it down once after all tests.
before(async () => {
  server = await serveRpc({ socketPath, token: "tok", handlers: { ping: async () => "pong" } });
});

after(() => server.close());

test("dispatches an authed request", async () => {
  const r = await post({ jsonrpc: "2.0", id: 1, method: "ping" });
  assert.deepEqual(r.body, { jsonrpc: "2.0", id: 1, result: "pong" });
});

test("rejects a bad token with 401", async () => {
  const r = await post({ jsonrpc: "2.0", id: 2, method: "ping" }, "nope");
  assert.equal(r.status, 401);
});
