import http from "node:http";
import https from "node:https";
import type { EthereumProvider, CallData } from "@kohaku-eth/provider";
import type { Filter } from "ox/Filter";

// Per-request timeout so a slow/non-responding daemon (e.g. Helios verifying a huge
// eth_getLogs range) can never hang the sidecar — it fails fast and the error
// propagates up to the app, which shows "—" rather than freezing.
const REQUEST_TIMEOUT_MS = 10_000;

export function createDaemonProvider(conn: { socketPath?: string; url?: string; token: string }): EthereumProvider {
  let nextId = 1;
  const rpc = (method: string, params: unknown[] = []): Promise<any> =>
    new Promise((resolve, reject) => {
      const body = JSON.stringify({ jsonrpc: "2.0", id: nextId++, method, params });
      const headers: Record<string, string | number> = { "content-type": "application/json", "content-length": Buffer.byteLength(body) };
      // Unix socket (daemon) → http at "/", authenticated with the daemon bearer token.
      // HTTP(S) URL (direct RPC, e.g. Infura) → honor the URL's protocol/host/port/path
      // and send NO Authorization header: a public RPC reads an `Authorization: Bearer`
      // as a (failing) JWT and rejects the request ("JWT is invalid"). The API key is
      // already in the URL path.
      let reqFn = http.request;
      let options: http.RequestOptions;
      if (conn.socketPath) {
        headers.authorization = `Bearer ${conn.token}`;
        options = { method: "POST", path: "/", headers, socketPath: conn.socketPath };
      } else {
        const u = parseUrl(conn.url!);
        reqFn = u.isHttps ? (https.request as typeof http.request) : http.request;
        options = { method: "POST", path: u.path, headers, host: u.host, port: u.port };
      }
      const req = reqFn(options, (res) => {
        let d = ""; res.on("data", (c) => (d += c));
        res.on("end", () => {
          try {
            const p = JSON.parse(d);
            p.error ? reject(new Error(`${method}: ${p.error.message ?? "rpc error"}`)) : resolve(p.result);
          } catch {
            reject(new Error(`${method}: non-JSON response (status ${res.statusCode}): ${d.slice(0, 200)}`));
          }
        });
      });
      req.on("error", reject);
      req.setTimeout(REQUEST_TIMEOUT_MS, () => req.destroy(new Error(`daemon RPC ${method} timed out after ${REQUEST_TIMEOUT_MS}ms`)));
      req.write(body); req.end();
    });
  const toBig = (h: string) => BigInt(h);
  return {
    _internal: rpc,
    getChainId: async () => toBig(await rpc("eth_chainId")),
    getBlockNumber: async () => toBig(await rpc("eth_blockNumber")),
    getBalance: async (a: string) => toBig(await rpc("eth_getBalance", [a, "latest"])),
    getCode: async (a: string) => await rpc("eth_getCode", [a, "latest"]),
    getGasPrice: async () => toBig(await rpc("eth_gasPrice")),
    getTransactionReceipt: async (h: string) => (await rpc("eth_getTransactionReceipt", [h])) ?? null,
    getLogs: async (params: Filter) => await rpc("eth_getLogs", [params]),
    estimateGas: async (c: CallData) => toBig(await rpc("eth_estimateGas", [c])),
    call: async (c: CallData) => (await rpc("eth_call", [c, "latest"])) as `0x${string}` | undefined,
    request: async ({ method, params }: { method: string; params?: unknown }) => await rpc(method, (params as unknown[]) ?? []),
    waitForTransaction: async (h: string) => { for (;;) { if (await rpc("eth_getTransactionReceipt", [h])) return; await new Promise((r) => setTimeout(r, 1500)); } },
  } as EthereumProvider;
}

export function parseUrl(url: string): { host: string; port: number; path: string; isHttps: boolean } {
  const u = new URL(url);
  const isHttps = u.protocol === "https:";
  return {
    host: u.hostname,
    port: Number(u.port || (isHttps ? 443 : 80)),
    path: (u.pathname || "/") + u.search, // Infura: /v3/<key>; daemon-style: /
    isHttps,
  };
}
