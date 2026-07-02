import http from "node:http";
import fs from "node:fs";

type Handler = (params: any) => Promise<any>;

export function serveRpc(opts: {
  socketPath: string;
  token: string;
  handlers: Record<string, Handler>;
}): Promise<http.Server> {
  const server = http.createServer((req, res) => {
    // One request per connection: signal close and tear the socket down once the
    // response is flushed. The Swift client (PrivacyHelperSidecar.callBlocking) and the
    // daemon's hyper server both use Connection: close + read-to-EOF; bun's node:http
    // compat layer does NOT close the socket on its own, so the client's read-to-EOF
    // would hang forever (it returns the body + Content-Length but keeps the connection
    // alive). Closing here makes the transport behave exactly like the daemon's.
    res.setHeader("connection", "close");
    res.on("finish", () => req.socket.end());

    if (req.headers.authorization !== `Bearer ${opts.token}`) {
      res.statusCode = 401;
      res.end();
      return;
    }
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", async () => {
      let id: unknown = null;
      try {
        const reqObj = JSON.parse(body);
        id = reqObj.id ?? null;
        const handler = opts.handlers[reqObj.method];
        if (!handler) throw new Error(`unknown method: ${reqObj.method}`);
        const result = await handler(reqObj.params);
        res.setHeader("content-type", "application/json");
        res.end(JSON.stringify({ jsonrpc: "2.0", id, result }));
      } catch (e) {
        process.stderr.write(`[rpc] handler error: ${(e as any)?.stack ?? e}\n`);
        res.setHeader("content-type", "application/json");
        res.end(JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32000, message: e instanceof Error ? e.message : String(e) } }));
      }
    });
  });

  return new Promise((resolve) => {
    try { fs.unlinkSync(opts.socketPath); } catch { /* fresh start */ }
    server.listen(opts.socketPath, () => resolve(server));
  });
}
