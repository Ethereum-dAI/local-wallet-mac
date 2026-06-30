import http from "node:http";
import type { EthereumProvider, CallData } from "@kohaku-eth/provider";
import type { Filter } from "ox/Filter";

export function createDaemonProvider(conn: { socketPath?: string; url?: string; token: string }): EthereumProvider {
  let nextId = 1;
  const rpc = (method: string, params: unknown[] = []): Promise<any> =>
    new Promise((resolve, reject) => {
      const body = JSON.stringify({ jsonrpc: "2.0", id: nextId++, method, params });
      const common = { method: "POST", path: "/", headers: { "content-type": "application/json", "content-length": Buffer.byteLength(body), authorization: `Bearer ${conn.token}` } };
      const options = conn.socketPath ? { ...common, socketPath: conn.socketPath } : { ...common, ...hostPort(conn.url!) };
      const req = http.request(options as http.RequestOptions, (res) => {
        let d = ""; res.on("data", (c) => (d += c));
        res.on("end", () => { try { const p = JSON.parse(d); p.error ? reject(new Error(p.error.message ?? "rpc error")) : resolve(p.result); } catch (e) { reject(e); } });
      });
      req.on("error", reject); req.write(body); req.end();
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

export function hostPort(url: string): { host: string; port: number } {
  const u = new URL(url);
  return { host: u.hostname, port: Number(u.port || (u.protocol === "https:" ? 443 : 80)) };
}
