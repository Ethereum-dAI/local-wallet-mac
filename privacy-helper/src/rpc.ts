import http from "node:http";
import fs from "node:fs";

type Handler = (params: any) => Promise<any>;

export function serveRpc(opts: {
  socketPath: string;
  token: string;
  handlers: Record<string, Handler>;
}): Promise<http.Server> {
  const server = http.createServer((req, res) => {
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
