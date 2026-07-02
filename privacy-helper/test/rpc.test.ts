// test/rpc.test.ts
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import net from "node:net";
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

// Regression: the Swift client (PrivacyHelperSidecar.callBlocking) and the daemon's
// hyper transport both read the HTTP response to EOF. bun's node:http server does NOT
// close the socket on its own, so without the explicit close-on-finish the client would
// hang forever. This asserts the server announces `Connection: close` and the socket
// reaches EOF after a single request — exactly mirroring the daemon's transport.
test("closes the connection after the response (read-to-EOF terminates)", async () => {
  const body = JSON.stringify({ jsonrpc: "2.0", id: 3, method: "ping" });
  const raw = await new Promise<string>((resolve, reject) => {
    const sock = net.connect({ path: socketPath });
    sock.setTimeout(5000, () => { sock.destroy(); reject(new Error("client read timed out — server did not close")); });
    let buf = "";
    sock.on("data", (c) => (buf += c.toString()));
    sock.on("end", () => resolve(buf)); // fires only when the server sends FIN
    sock.on("error", reject);
    sock.write(
      `POST / HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n` +
        `Authorization: Bearer tok\r\nContent-Length: ${Buffer.byteLength(body)}\r\nConnection: close\r\n\r\n${body}`,
    );
  });
  assert.match(raw, /^HTTP\/1\.1 200/);
  assert.match(raw.toLowerCase(), /connection: close/);
  assert.deepEqual(JSON.parse(raw.split("\r\n\r\n")[1]), { jsonrpc: "2.0", id: 3, result: "pong" });
});
