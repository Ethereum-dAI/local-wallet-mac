# Kohaku Shield v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a private deposit (shield) round-trip on Sepolia — a `privacy-helper` Node sidecar hosting Kohaku Privacy Pools, fed the shielded seed over fd-5, with chain reads routed through the daemon, plus an in-app shielded-balance display.

**Architecture:** A new `local-wallet-mac/privacy-helper/` Node sidecar hosts the Kohaku `PrivacyPoolsV1Protocol`. It implements the Kohaku `Host` (`provider` forwards `eth_*` reads to the daemon's authenticated JSON-RPC; `storage` is a JSON file; `keystore` is a `MnemonicKeystore` from the seed). The Swift app spawns it exactly like `wallet-node` (fd-3 ready, fd-4 alive, fd-5 secret), exposes a `shield` tool intent that turns `prepareShield` output into a Kernel `execute` UserOp signed by the existing passkey, and renders the sidecar's `balance()` in the UI.

**Tech Stack:** TypeScript/Node (esbuild bundle), `@kohaku-eth/privacy-pools` + `@kohaku-eth/plugins` + `@kohaku-eth/provider`, Swift 6 / SwiftUI, the existing `wallet-node` daemon (Rust) and `wallet-ffi` signing path.

## Global Constraints

- Chains: Ethereum Mainnet (1) and Sepolia (11155111) only. **v1 targets Sepolia (11155111).**
- PP Sepolia entrypoint: `0x34A2068192b1297f2a7f85D7D8CdE66F8F0921cB`, deploymentBlock `8461453` (`PrivacyPoolsV1_0xBow[11155111]`). Native ETH asset id uses `E_ADDRESS = 0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee`.
- **No new daemon RPC methods** — the sidecar reuses standard `eth_*` reads.
- **`local-wallet-protocol`: no changes.**
- Sidecar ships as one esbuild bundle + `.wasm` proving assets inside the `.app`; `node_modules` stays dev/CI-only.
- Shielded seed at rest: Keychain generic-password, `kSecAttrAccessControl = .biometryCurrentSet`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, testnet-tagged. Seed/daemon-conn reach the sidecar only over fd-5 (never argv/env/disk).
- The sidecar gets its **own** fd contract (3=ready, 4=alive, 5=secret) mirroring the daemon's; do **not** alter the daemon's fd contract.
- Never commit to `main`. Work continues on branch `kohaku-shield-v1`. `docs/` is gitignored — `git add -f` the plan/spec docs.
- Spec: `docs/superpowers/specs/2026-06-26-kohaku-shield-v1-design.md`.

---

## File structure

**New — `local-wallet-mac/privacy-helper/` (Node sidecar):**
- `package.json`, `tsconfig.json`, `build.mjs` — project + esbuild bundling.
- `src/rpc.ts` — newline-delimited JSON-RPC loop over stdin/stdout (app ↔ sidecar).
- `src/daemon-provider.ts` — `EthereumProvider` backed by the daemon's Unix-socket JSON-RPC.
- `src/secret.ts` — read + parse the fd-5 payload (`{ seedHex, daemon: { socketPath, token } }`).
- `src/pp.ts` — build the `Host`, instantiate `PrivacyPoolsV1Protocol`, expose `balance()` / `prepareShield()`.
- `src/index.ts` — entry: read fd-5, signal ready on fd-3, watch fd-4, serve RPC.
- `test/daemon-provider.test.ts`, `test/pp.test.ts`, `test/rpc.test.ts` — `node:test`.

**Modified — Swift (`local-wallet-mac/wallet-macos/Sources/`):**
- `WalletMacOSApp/ShieldedSeedStore.swift` (NEW) — Keychain custody of the shielded seed.
- `WalletMacOSApp/PrivacyHelperSidecar.swift` (NEW) — spawn/lifecycle, mirrors `WalletNodeDaemon.swift`.
- `WalletToolLayer/ToolIntent.swift` — add `shield` to `Tool`.
- `WalletToolLayer/ToolDefinitions.swift` — add the `shield` `ToolDefinition` + include in `phase1`.
- The view that renders public balance (shielded-balance row) — located in Step of Task 9.
- `project.yml` — bundle the sidecar artifact as an app resource.

**Modified — daemon (`local-wallet-daemon`):**
- `crates/wallet-bundler/src/policy.rs` — confirm/raise `max_call_gas_limit` for ZK deposits.

---

## Task 1: Scaffold the `privacy-helper` Node project

**Files:**
- Create: `local-wallet-mac/privacy-helper/package.json`
- Create: `local-wallet-mac/privacy-helper/tsconfig.json`
- Create: `local-wallet-mac/privacy-helper/build.mjs`
- Create: `local-wallet-mac/privacy-helper/src/rpc.ts`
- Test: `local-wallet-mac/privacy-helper/test/rpc.test.ts`

**Interfaces:**
- Produces: `createRpcServer(handlers: Record<string, (params: any) => Promise<any>>, input: NodeJS.ReadableStream, output: NodeJS.WritableStream): void` — reads newline-delimited JSON-RPC 2.0 requests, writes one JSON response line each.

- [ ] **Step 1: Create `package.json`**

```json
{
  "name": "privacy-helper",
  "private": true,
  "type": "module",
  "version": "0.0.0",
  "scripts": {
    "build": "node build.mjs",
    "test": "node --test --experimental-strip-types test/"
  },
  "dependencies": {
    "@kohaku-eth/privacy-pools": "*",
    "@kohaku-eth/plugins": "*",
    "@kohaku-eth/provider": "*"
  },
  "devDependencies": {
    "esbuild": "^0.23.0",
    "typescript": "^5.5.0"
  }
}
```

- [ ] **Step 2: Create `tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "noEmit": true
  },
  "include": ["src", "test"]
}
```

- [ ] **Step 3: Create `build.mjs` (esbuild → one bundled file)**

```js
import { build } from "esbuild";

await build({
  entryPoints: ["src/index.ts"],
  bundle: true,
  platform: "node",
  format: "esm",
  target: "node20",
  outfile: "dist/privacy-helper.mjs",
  banner: { js: "import { createRequire } from 'module'; const require = createRequire(import.meta.url);" },
  loader: { ".wasm": "file" },
});
console.log("built dist/privacy-helper.mjs");
```

- [ ] **Step 4: Write the failing test for the RPC loop**

```ts
// test/rpc.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { PassThrough } from "node:stream";
import { createRpcServer } from "../src/rpc.ts";

test("dispatches a request and writes a result line", async () => {
  const input = new PassThrough();
  const output = new PassThrough();
  createRpcServer({ ping: async () => "pong" }, input, output);

  const line = new Promise<string>((resolve) => {
    output.once("data", (b) => resolve(b.toString().trim()));
  });
  input.write(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "ping" }) + "\n");

  assert.equal(await line, JSON.stringify({ jsonrpc: "2.0", id: 1, result: "pong" }));
});
```

- [ ] **Step 5: Run the test, verify it fails**

Run: `cd local-wallet-mac/privacy-helper && npm install && npm test`
Expected: FAIL — `Cannot find module '../src/rpc.ts'`.

- [ ] **Step 6: Implement `src/rpc.ts`**

```ts
import { createInterface } from "node:readline";

type Handler = (params: any) => Promise<any>;

export function createRpcServer(
  handlers: Record<string, Handler>,
  input: NodeJS.ReadableStream,
  output: NodeJS.WritableStream,
): void {
  const rl = createInterface({ input });
  rl.on("line", async (line) => {
    if (!line.trim()) return;
    let id: unknown = null;
    try {
      const req = JSON.parse(line);
      id = req.id ?? null;
      const handler = handlers[req.method];
      if (!handler) throw new Error(`unknown method: ${req.method}`);
      const result = await handler(req.params);
      output.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e);
      output.write(JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32000, message } }) + "\n");
    }
  });
}
```

- [ ] **Step 7: Run the test, verify it passes**

Run: `npm test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add -f privacy-helper/package.json privacy-helper/tsconfig.json privacy-helper/build.mjs privacy-helper/src/rpc.ts privacy-helper/test/rpc.test.ts
git commit -m "feat(privacy-helper): scaffold Node sidecar + JSON-RPC loop"
```

> Note: `privacy-helper/` may be partly gitignored if a parent rule catches `dist/` or `node_modules/`. Add a `privacy-helper/.gitignore` with `node_modules/` and `dist/`; `git add -f` only source files.

---

## Task 2: Daemon-backed `EthereumProvider`

**Files:**
- Create: `local-wallet-mac/privacy-helper/src/daemon-provider.ts`
- Test: `local-wallet-mac/privacy-helper/test/daemon-provider.test.ts`

**Interfaces:**
- Consumes: the daemon's standard `eth_*` JSON-RPC over a Unix socket with a `Bearer` token (e.g. `eth_chainId`, `eth_getCode`, `eth_call`, `eth_getLogs`, `eth_blockNumber`, `eth_getTransactionReceipt`, `eth_gasPrice`, `eth_estimateGas`, `eth_getBalance`, `eth_getTransactionCount`).
- Produces: `createDaemonProvider(conn: { socketPath: string; token: string }): EthereumProvider` (from `@kohaku-eth/provider`), plus an internal `rpc(method, params)` used by every method.

- [ ] **Step 1: Write the failing test (method→RPC translation against a mock Unix-socket server)**

```ts
// test/daemon-provider.test.ts
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import fs from "node:fs";
import { createDaemonProvider } from "../src/daemon-provider.ts";

let server: http.Server;
let socketPath: string;
let lastBody: any;

before(async () => {
  socketPath = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "ph-")), "d.sock");
  server = http.createServer((req, res) => {
    let data = "";
    req.on("data", (c) => (data += c));
    req.on("end", () => {
      lastBody = JSON.parse(data);
      const map: Record<string, unknown> = {
        eth_chainId: "0xaa36a7", // 11155111
        eth_getCode: "0x1234",
      };
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify({ jsonrpc: "2.0", id: lastBody.id, result: map[lastBody.method] }));
    });
  });
  await new Promise<void>((r) => server.listen(socketPath, r));
});

after(() => server.close());

test("getChainId issues eth_chainId with bearer auth and parses hex", async () => {
  const p = createDaemonProvider({ socketPath, token: "tok123" });
  const chainId = await p.getChainId();
  assert.equal(chainId, 11155111n);
  assert.equal(lastBody.method, "eth_chainId");
});

test("getCode forwards address param", async () => {
  const p = createDaemonProvider({ socketPath, token: "tok123" });
  const code = await p.getCode("0xabc");
  assert.equal(code, "0x1234");
  assert.deepEqual(lastBody.params, ["0xabc", "latest"]);
});
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `npm test`
Expected: FAIL — `Cannot find module '../src/daemon-provider.ts'`.

- [ ] **Step 3: Implement `src/daemon-provider.ts`**

```ts
import http from "node:http";
import type { EthereumProvider } from "@kohaku-eth/provider";

export function createDaemonProvider(conn: { socketPath: string; token: string }): EthereumProvider {
  let nextId = 1;
  const rpc = (method: string, params: unknown[] = []): Promise<any> =>
    new Promise((resolve, reject) => {
      const body = JSON.stringify({ jsonrpc: "2.0", id: nextId++, method, params });
      const req = http.request(
        {
          socketPath: conn.socketPath,
          path: "/",
          method: "POST",
          headers: {
            "content-type": "application/json",
            "content-length": Buffer.byteLength(body),
            authorization: `Bearer ${conn.token}`,
          },
        },
        (res) => {
          let data = "";
          res.on("data", (c) => (data += c));
          res.on("end", () => {
            try {
              const parsed = JSON.parse(data);
              if (parsed.error) reject(new Error(parsed.error.message ?? "rpc error"));
              else resolve(parsed.result);
            } catch (e) {
              reject(e);
            }
          });
        },
      );
      req.on("error", reject);
      req.write(body);
      req.end();
    });

  const toBig = (hex: string) => BigInt(hex);

  return {
    _internal: rpc,
    getChainId: async () => toBig(await rpc("eth_chainId")),
    getBlockNumber: async () => toBig(await rpc("eth_blockNumber")),
    getBalance: async (address) => toBig(await rpc("eth_getBalance", [address, "latest"])),
    getCode: async (address) => await rpc("eth_getCode", [address, "latest"]),
    getGasPrice: async () => toBig(await rpc("eth_gasPrice")),
    getTransactionCount: async (address, block) =>
      Number(toBig(await rpc("eth_getTransactionCount", [address, block ?? "latest"]))),
    getTransactionReceipt: async (txHash) => (await rpc("eth_getTransactionReceipt", [txHash])) ?? null,
    getLogs: async (params) => await rpc("eth_getLogs", [params]),
    estimateGas: async (call) => toBig(await rpc("eth_estimateGas", [call])),
    call: async (call) => (await rpc("eth_call", [call, "latest"])) as `0x${string}` | undefined,
    request: async ({ method, params }) => await rpc(method, (params as unknown[]) ?? []),
    waitForTransaction: async (txHash) => {
      // ponytail: poll receipt; good enough for a sidecar that only reads.
      for (;;) {
        const r = await rpc("eth_getTransactionReceipt", [txHash]);
        if (r) return;
        await new Promise((res) => setTimeout(res, 1500));
      }
    },
  } as EthereumProvider;
}
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `npm test`
Expected: PASS (both cases).

- [ ] **Step 5: Commit**

```bash
git add -f privacy-helper/src/daemon-provider.ts privacy-helper/test/daemon-provider.test.ts
git commit -m "feat(privacy-helper): EthereumProvider backed by daemon Unix-socket RPC"
```

---

## Task 3: fd-5 secret payload reader

**Files:**
- Create: `local-wallet-mac/privacy-helper/src/secret.ts`
- Test: `local-wallet-mac/privacy-helper/test/secret.test.ts`

**Interfaces:**
- Consumes: a single JSON object written to fd-5 then EOF: `{ "seedHex": "0x…", "daemon": { "socketPath": "…", "token": "…" } }`.
- Produces: `readSecretPayload(fd: number): Promise<{ seedHex: string; daemon: { socketPath: string; token: string } }>`.

- [ ] **Step 1: Write the failing test (pipe a payload through a real fd)**

```ts
// test/secret.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { readSecretPayload } from "../src/secret.ts";

test("reads and parses the fd payload to EOF", async () => {
  const [r, w] = (() => {
    const path = require("node:os").tmpdir() + "/sec-" + Date.now();
    fs.writeFileSync(path, "");
    return [path, path] as const;
  })();
  const payload = { seedHex: "0xdead", daemon: { socketPath: "/tmp/d.sock", token: "t" } };
  fs.writeFileSync(w, JSON.stringify(payload));
  const fd = fs.openSync(r, "r");
  const got = await readSecretPayload(fd);
  assert.deepEqual(got, payload);
});
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `npm test`
Expected: FAIL — `Cannot find module '../src/secret.ts'`.

- [ ] **Step 3: Implement `src/secret.ts`**

```ts
import fs from "node:fs";

export async function readSecretPayload(
  fd: number,
): Promise<{ seedHex: string; daemon: { socketPath: string; token: string } }> {
  const chunks: Buffer[] = [];
  const stream = fs.createReadStream("", { fd, autoClose: true });
  for await (const chunk of stream) chunks.push(chunk as Buffer);
  const text = Buffer.concat(chunks).toString("utf8").trim();
  const parsed = JSON.parse(text);
  if (typeof parsed.seedHex !== "string" || !parsed.daemon?.socketPath || !parsed.daemon?.token) {
    throw new Error("invalid fd-5 secret payload");
  }
  return parsed;
}
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `npm test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -f privacy-helper/src/secret.ts privacy-helper/test/secret.test.ts
git commit -m "feat(privacy-helper): read seed+daemon-conn from fd-5 payload"
```

---

## Task 4: Privacy Pools host + `balance()` / `prepareShield()`

**Files:**
- Create: `local-wallet-mac/privacy-helper/src/pp.ts`
- Test: `local-wallet-mac/privacy-helper/test/pp.test.ts`

**Interfaces:**
- Consumes: `EthereumProvider` (Task 2); `MnemonicKeystore`, `MemoryStorage` from `@kohaku-eth/plugins`; `PrivacyPoolsV1Protocol`, `PrivacyPoolsV1_0xBow`, `E_ADDRESS` from `@kohaku-eth/privacy-pools`.
- Produces:
  - `createPrivacyPools(opts: { seedHex: string; provider: EthereumProvider; chainId: 11155111 }): { balanceEthWei(): Promise<string>; prepareShieldEth(amountWei: string): Promise<{ to: string; data: string; value: string }> }`.
  - `balanceEthWei` returns the approved native-ETH balance as a decimal wei string.
  - `prepareShieldEth` returns the first deposit tx as `{ to, data, value }` (hex strings) for the app to wrap in a Kernel `execute`.

- [ ] **Step 1: Write the failing test (inject a fake plugin to assert wiring + mapping)**

```ts
// test/pp.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { mapShieldTx, pickEthBalance } from "../src/pp.ts";

test("pickEthBalance sums approved native-ETH entries to a wei string", () => {
  const E = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
  const balances = [
    { asset: { contract: E, __type: "erc20" }, amount: 1000n },
    { asset: { contract: E, __type: "erc20" }, amount: 7n, tag: "pending" },
  ];
  assert.equal(pickEthBalance(balances as any, E), "1000");
});

test("mapShieldTx extracts to/data/value from the PublicOperation", () => {
  const op = { txns: [{ to: "0xpool", data: "0xabcd", value: 5n }] };
  assert.deepEqual(mapShieldTx(op as any), { to: "0xpool", data: "0xabcd", value: "5" });
});
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `npm test`
Expected: FAIL — `Cannot find module '../src/pp.ts'`.

- [ ] **Step 3: Implement `src/pp.ts`**

```ts
import { MnemonicKeystore, MemoryStorage, type Host } from "@kohaku-eth/plugins";
import { PrivacyPoolsV1Protocol, PrivacyPoolsV1_0xBow, E_ADDRESS } from "@kohaku-eth/privacy-pools";
import type { EthereumProvider } from "@kohaku-eth/provider";

// Pure helpers (unit-tested):
export function pickEthBalance(balances: { asset: { contract: string }; amount: bigint; tag?: string }[], eAddr: string): string {
  const approved = balances.find((b) => b.asset.contract.toLowerCase() === eAddr.toLowerCase() && b.tag !== "pending");
  return (approved?.amount ?? 0n).toString();
}

export function mapShieldTx(op: { txns: { to: string; data: string; value: bigint }[] }): { to: string; data: string; value: string } {
  const tx = op.txns[0];
  if (!tx) throw new Error("prepareShield returned no txns");
  return { to: tx.to, data: tx.data, value: (tx.value ?? 0n).toString() };
}

export function createPrivacyPools(opts: { seedHex: string; provider: EthereumProvider; chainId: 11155111 }) {
  // seedHex is a BIP-39 mnemonic-derived key transport; for v1 we accept a mnemonic
  // string. MnemonicKeystore expects a mnemonic — see Swift side (Task 5) which stores one.
  const host: Host = {
    network: { fetch: (input, init) => fetch(input as any, init) },
    storage: new MemoryStorage(), // ponytail: swapped for file storage in Task wiring (index.ts); MemoryStorage keeps Task 4 pure.
    keystore: new MnemonicKeystore(opts.seedHex),
    provider: opts.provider,
  };

  const { entrypoint } = PrivacyPoolsV1_0xBow[opts.chainId];
  const pp = new PrivacyPoolsV1Protocol(host, { entrypoint, accountIndex: 0 });
  const ethAsset = { __type: "erc20" as const, contract: E_ADDRESS };

  return {
    async balanceEthWei(): Promise<string> {
      const balances = await pp.balance([ethAsset]);
      return pickEthBalance(balances as any, E_ADDRESS);
    },
    async prepareShieldEth(amountWei: string): Promise<{ to: string; data: string; value: string }> {
      const op = await pp.prepareShield({ asset: ethAsset, amount: BigInt(amountWei) });
      return mapShieldTx(op as any);
    },
  };
}
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `npm test`
Expected: PASS (both pure-helper cases). `createPrivacyPools` is exercised in Task 5's integration gate.

- [ ] **Step 5: Commit**

```bash
git add -f privacy-helper/src/pp.ts privacy-helper/test/pp.test.ts
git commit -m "feat(privacy-helper): PP host wiring + balance/prepareShield mappers"
```

---

## Task 5: Sidecar entrypoint + standalone Sepolia integration gate

**Files:**
- Create: `local-wallet-mac/privacy-helper/src/index.ts`
- Create: `local-wallet-mac/privacy-helper/src/file-storage.ts`
- Manual gate: run against a dev daemon on Sepolia.

**Interfaces:**
- Consumes: `createRpcServer` (T1), `createDaemonProvider` (T2), `readSecretPayload` (T3), `createPrivacyPools` (T4).
- Produces: a runnable sidecar. RPC methods exposed to the app: `balance() → string (wei)`, `prepareShield({ amountWei }) → { to, data, value }`. fd contract: reads fd-5 payload, writes `"ready\n"` to fd-3, exits on fd-4 EOF.

- [ ] **Step 1: Implement `src/file-storage.ts` (Kohaku `Storage` backed by a JSON file)**

```ts
import fs from "node:fs";
import type { Storage } from "@kohaku-eth/plugins";

export function createFileStorage(filePath: string): Storage {
  const read = (): Record<string, string> => {
    try { return JSON.parse(fs.readFileSync(filePath, "utf8")); } catch { return {}; }
  };
  return {
    _brand: "Storage",
    async get(key) { return read()[key] ?? null; },
    async set(key, value) {
      const all = read();
      all[key] = value;
      fs.writeFileSync(filePath, JSON.stringify(all), { mode: 0o600 });
    },
  };
}
```

- [ ] **Step 2: Implement `src/index.ts`**

```ts
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { createRpcServer } from "./rpc.ts";
import { createDaemonProvider } from "./daemon-provider.ts";
import { readSecretPayload } from "./secret.ts";
import { MnemonicKeystore, type Host } from "@kohaku-eth/plugins";
import { PrivacyPoolsV1Protocol, PrivacyPoolsV1_0xBow, E_ADDRESS } from "@kohaku-eth/privacy-pools";
import { createFileStorage } from "./file-storage.ts";

const READY_FD = 3;
const ALIVE_FD = 4;
const SECRET_FD = 5;
const CHAIN_ID = 11155111 as const;

async function main() {
  const { seedHex, daemon } = await readSecretPayload(SECRET_FD);
  const provider = createDaemonProvider(daemon);

  const storageFile = path.join(
    process.env.HOME ?? os.tmpdir(),
    "Library/Application Support/LocalWallet/privacy-pools-sepolia.json",
  );
  fs.mkdirSync(path.dirname(storageFile), { recursive: true });

  const host: Host = {
    network: { fetch: (input, init) => fetch(input as any, init) },
    storage: createFileStorage(storageFile),
    keystore: new MnemonicKeystore(seedHex),
    provider,
  };
  const { entrypoint } = PrivacyPoolsV1_0xBow[CHAIN_ID];
  const pp = new PrivacyPoolsV1Protocol(host, { entrypoint, accountIndex: 0 });
  const ethAsset = { __type: "erc20" as const, contract: E_ADDRESS };

  createRpcServer(
    {
      balance: async () => {
        const balances = await pp.balance([ethAsset]);
        const approved = (balances as any[]).find((b) => b.asset.contract.toLowerCase() === E_ADDRESS && b.tag !== "pending");
        return (approved?.amount ?? 0n).toString();
      },
      prepareShield: async ({ amountWei }: { amountWei: string }) => {
        const op = await pp.prepareShield({ asset: ethAsset, amount: BigInt(amountWei) });
        const tx = (op as any).txns[0];
        return { to: tx.to, data: tx.data, value: (tx.value ?? 0n).toString() };
      },
    },
    process.stdin,
    process.stdout,
  );

  // ready + liveness
  fs.writeSync(READY_FD, "ready\n");
  const alive = fs.createReadStream("", { fd: ALIVE_FD });
  alive.on("end", () => process.exit(0));
}

main().catch((e) => {
  fs.writeSync(2, `privacy-helper fatal: ${e?.message ?? e}\n`);
  process.exit(1);
});
```

- [ ] **Step 3: Build the bundle**

Run: `cd local-wallet-mac/privacy-helper && npm run build`
Expected: `built dist/privacy-helper.mjs`, no errors.

- [ ] **Step 4: Manual Sepolia integration gate (standalone, proves the TS↔daemon seam)**

```bash
# Terminal A — dev daemon on Sepolia (loopback HTTP, prints token + httpAddr):
cd ../local-wallet-daemon
cargo run -p wallet-node -- --http 127.0.0.1:0 --print-ready --debug
# note the printed bearer token + http addr; for the sidecar's Unix-socket provider,
# instead run the daemon in socket mode (the app uses sockets); for this gate either
# adapt createDaemonProvider to an http base-URL variant, OR point socketPath at the
# daemon's Unix socket if running in socket mode.
```

Drive the built sidecar with a hand-written fd-5 payload (seed = a throwaway test mnemonic) and a couple of RPC lines on stdin; confirm:
- `balance` returns `"0"` for a fresh mnemonic.
- `prepareShield` with `{ "amountWei": "10000000000000000" }` returns `{ to: <Sepolia entrypoint or pool>, data: 0x…, value: "10000000000000000" }`.
- Kill the daemon → `balance` errors (reads route through the daemon, not a 2nd RPC). **This is the spec's provider-routing check.**

Record the exact commands you used in `privacy-helper/README.md` so the gate is repeatable.

- [ ] **Step 5: Commit**

```bash
git add -f privacy-helper/src/index.ts privacy-helper/src/file-storage.ts privacy-helper/README.md
git commit -m "feat(privacy-helper): entrypoint, file storage, standalone Sepolia gate"
```

---

## Task 6: Shielded seed Keychain custody (Swift)

**Files:**
- Create: `local-wallet-mac/wallet-macos/Sources/WalletMacOSApp/ShieldedSeedStore.swift`
- Test: `local-wallet-mac/wallet-macos/Tests/WalletMacOSAppTests/ShieldedSeedStoreTests.swift`

**Interfaces:**
- Produces: `struct ShieldedSeedStore { func loadOrCreateMnemonic(reason: String) throws -> String; func deleteMnemonic() throws }`. Stores a BIP-39 mnemonic string as a Keychain generic-password with biometric + `ThisDeviceOnly` access control. (Mirrors the `SecAccessControlCreateWithFlags` pattern in `KeyStore.swift:111-144`, but `kSecClassGenericPassword` instead of a Secure-Enclave `SecKey`, because the seed must be readable to feed the sidecar.)

- [ ] **Step 1: Write the unit-testable slice — access-control flag construction**

Keychain round-trips need a signed bundle (`OSStatus -34018` under `swift test`), so the **unit** test covers only the pure access-control construction; the round-trip is a manual gate (Step 4).

```swift
// Tests/WalletMacOSAppTests/ShieldedSeedStoreTests.swift
import XCTest
@testable import WalletMacOSApp

final class ShieldedSeedStoreTests: XCTestCase {
    func testAccessControlIsBiometricAndThisDeviceOnly() throws {
        var err: Unmanaged<CFError>?
        let ac = ShieldedSeedStore.makeAccessControl(&err)
        XCTAssertNil(err)
        XCTAssertNotNil(ac)
    }
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `cd local-wallet-mac && ./scripts/build-ffi.sh && cd wallet-macos && swift test --filter ShieldedSeedStoreTests`
Expected: FAIL — `ShieldedSeedStore` not found.

- [ ] **Step 3: Implement `ShieldedSeedStore.swift`**

```swift
import Foundation
import LocalAuthentication
import Security

struct ShieldedSeedStore {
    private let service = "com.localwallet.wallet-macos.shielded-seed"
    private let account = "privacy-pools-sepolia"  // testnet-tagged

    static func makeAccessControl(_ error: inout Unmanaged<CFError>?) -> SecAccessControl? {
        SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.biometryCurrentSet],
            &error
        )
    }

    func loadOrCreateMnemonic(reason: String) throws -> String {
        if let existing = try load(reason: reason) { return existing }
        let mnemonic = Self.generateMnemonic()
        try store(mnemonic)
        return mnemonic
    }

    private func load(reason: String) throws -> String? {
        let context = LAContext()
        context.localizedReason = reason
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let s = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return s
    }

    private func store(_ mnemonic: String) throws {
        var acErr: Unmanaged<CFError>?
        guard let ac = Self.makeAccessControl(&acErr) else { throw acErr!.takeRetainedValue() as Error }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(mnemonic.utf8),
            kSecAttrAccessControl as String: ac,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    func deleteMnemonic() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    // ponytail: 24-word BIP-39 generation. Reuse an existing BIP-39 helper if the app
    // already vendors one (grep for "mnemonic"/"bip39"); else add @scure/bip39's wordlist
    // equivalent in Swift. For v1 testnet a CSPRNG-backed 256-bit entropy → wordlist map.
    static func generateMnemonic() -> String { /* see Step 3a */ fatalError("implement in 3a") }
}
```

- [ ] **Step 3a: Resolve mnemonic generation (no placeholder)**

Run: `grep -rin "mnemonic\|bip39\|bip-39" local-wallet-mac/wallet-macos/Sources local-wallet-protocol 2>/dev/null`
- If a BIP-39 generator exists, call it and delete the `generateMnemonic` stub's `fatalError`.
- If none exists: the **sidecar already depends on a BIP-39 lib** (`@scure/bip39` via Kohaku). Rather than add Swift BIP-39, generate the mnemonic **in the sidecar** on first run (expose an RPC `newMnemonic()` returning a phrase) and have Swift store what the sidecar returns. Update `loadOrCreateMnemonic` to take a `make: () async throws -> String` closure the caller wires to the sidecar. Pick this path if no Swift BIP-39 exists — it avoids a new Swift dependency.

> Decision recorded here so the implementer doesn't invent a Swift BIP-39: **prefer the sidecar-generated mnemonic** unless the grep finds an existing Swift generator.

- [ ] **Step 4: Manual Keychain round-trip gate (signed bundle)**

Build/run the app from Xcode (`LocalWalletApp` scheme). Trigger seed creation, confirm Face/Touch ID prompts on read, confirm the item persists across relaunch. (`swift test` cannot cover this — `OSStatus -34018` outside a signed bundle, per CLAUDE.md.)

- [ ] **Step 5: Run the unit test, verify it passes; commit**

Run: `cd wallet-macos && swift test --filter ShieldedSeedStoreTests`
Expected: PASS.

```bash
git add wallet-macos/Sources/WalletMacOSApp/ShieldedSeedStore.swift wallet-macos/Tests/WalletMacOSAppTests/ShieldedSeedStoreTests.swift
git commit -m "feat(app): shielded-seed Keychain custody (biometric, device-only, testnet)"
```

---

## Task 7: Spawn the sidecar (Swift, mirrors `WalletNodeDaemon`)

**Files:**
- Create: `local-wallet-mac/wallet-macos/Sources/WalletMacOSApp/PrivacyHelperSidecar.swift`
- Modify: `local-wallet-mac/project.yml` (bundle `privacy-helper/dist/privacy-helper.mjs` + node runtime as a resource)
- Test: `local-wallet-mac/wallet-macos/Tests/WalletMacOSAppTests/PrivacyHelperSidecarTests.swift`

**Interfaces:**
- Consumes: the running daemon's `ReadyEvent { token, socketPath }` (from `WalletNodeDaemon`, `WalletNodeDaemon.swift:114-134`); `ShieldedSeedStore` (Task 6); the `spawnHelper`/pipe/`readLineWithTimeout` pattern (`WalletNodeDaemon.swift:172-226`).
- Produces: `final class PrivacyHelperSidecar { static func launch(seedMnemonic: String, daemonSocketPath: String, daemonToken: String) async throws -> PrivacyHelperSidecar; func balanceWei() async throws -> String; func prepareShield(amountWei: String) async throws -> (to: String, data: String, value: String) }`. fd-5 payload is JSON `{ seedHex, daemon: { socketPath, token } }` (here `seedHex` carries the mnemonic string for `MnemonicKeystore`).

- [ ] **Step 1: Write the spawn integration test (mirrors `SpawnHelperTests`)**

```swift
// Tests/WalletMacOSAppTests/PrivacyHelperSidecarTests.swift
import XCTest
@testable import WalletMacOSApp

final class PrivacyHelperSidecarTests: XCTestCase {
    // Integration: needs the built dist/privacy-helper.mjs + node. Skips if absent.
    func testLaunchAndBalanceZero() async throws {
        try XCTSkipUnless(PrivacyHelperSidecar.bundledScriptExists, "build privacy-helper first")
        // Spawn against a mock daemon socket that answers eth_* with empty results.
        let mock = try MockDaemonSocket.start()  // helper that serves eth_getLogs=[] etc.
        defer { mock.stop() }
        let sidecar = try await PrivacyHelperSidecar.launch(
            seedMnemonic: "test test test test test test test test test test test junk",
            daemonSocketPath: mock.socketPath,
            daemonToken: "tok"
        )
        let bal = try await sidecar.balanceWei()
        XCTAssertEqual(bal, "0")
    }
}
```

- [ ] **Step 2: Run it, verify it fails**

Run: `cd wallet-macos && swift test --filter PrivacyHelperSidecarTests`
Expected: FAIL — `PrivacyHelperSidecar` not found.

- [ ] **Step 3: Implement `PrivacyHelperSidecar.swift`**

Mirror `WalletNodeDaemon.launchBlocking` (`WalletNodeDaemon.swift:158-226`): create ready/alive/secret pipes, `setCloseOnExec`, `spawnHelper(execPath: <node>, args: [scriptPath], readyWrite:3, aliveRead:4, secretRead:5)`, write the JSON fd-5 payload via `writeSecretPayload`-style helper, `readLineWithTimeout(fd: readyPipe[0], timeout: 8)` expecting `"ready"`. The app↔sidecar JSON-RPC runs over the child's **stdin/stdout** (capture both pipes); implement `balanceWei()`/`prepareShield()` by writing one request line and awaiting the matching `id` response line.

```swift
import Darwin
import Foundation
import SpawnHelper

final class PrivacyHelperSidecar: @unchecked Sendable {
    static var bundledScriptExists: Bool { resolveScriptPath() != nil }

    // resolveScriptPath(): Bundle.main resource "privacy-helper.mjs", else
    // #filePath-relative ../../privacy-helper/dist/privacy-helper.mjs (dev), mirroring
    // WalletNodeDaemon.resolveExecutablePath / sourceRootWalletNodePath.
    static func resolveScriptPath() -> String? { /* mirror WalletNodeDaemon.swift:228-264 */ return nil }
    static func resolveNodePath() -> String { "/usr/bin/env" } // args: ["node", scriptPath]; ponytail: bundle node for release

    static func launch(seedMnemonic: String, daemonSocketPath: String, daemonToken: String) async throws -> PrivacyHelperSidecar {
        // ... pipes + spawnHelper + fd-5 JSON payload + ready read, exactly mirroring
        // WalletNodeDaemon.launchBlocking. Payload:
        //   {"seedHex": seedMnemonic, "daemon": {"socketPath": daemonSocketPath, "token": daemonToken}}
        fatalError("mirror WalletNodeDaemon.launchBlocking; see Step 3 notes")
    }

    func balanceWei() async throws -> String { /* JSON-RPC over child stdio: {"method":"balance"} */ fatalError() }
    func prepareShield(amountWei: String) async throws -> (to: String, data: String, value: String) { fatalError() }
}
```

> The `fatalError` bodies above are **structural markers, not the deliverable** — the implementer fills them by copying the cited `WalletNodeDaemon` spawn code (it is the proven, in-repo pattern) and the Task-1 JSON-RPC framing. Do not ship `fatalError`. Verify by the Step-1 test passing.

- [ ] **Step 4: Bundle the sidecar in `project.yml`**

Add `privacy-helper/dist/privacy-helper.mjs` to the `LocalWalletApp` target resources (alongside the daemon binary entry). Then `xcodegen generate`.

- [ ] **Step 5: Run the integration test, verify it passes; commit**

Run: `cd local-wallet-mac/privacy-helper && npm run build && cd ../wallet-macos && swift test --filter PrivacyHelperSidecarTests`
Expected: PASS (balance `"0"` against the mock daemon).

```bash
git add wallet-macos/Sources/WalletMacOSApp/PrivacyHelperSidecar.swift wallet-macos/Tests/WalletMacOSAppTests/PrivacyHelperSidecarTests.swift project.yml
git commit -m "feat(app): spawn privacy-helper sidecar (fd-3/4/5), JSON-RPC over stdio"
```

---

## Task 8: `shield` tool intent → Kernel `execute` UserOp

**Files:**
- Modify: `local-wallet-mac/wallet-macos/Sources/WalletToolLayer/ToolIntent.swift:4-6`
- Modify: `local-wallet-mac/wallet-macos/Sources/WalletToolLayer/ToolDefinitions.swift`
- Modify: the app's send path that handles `transfer`/`swap` intents (grep below) — add a `shield` branch.
- Test: `local-wallet-mac/wallet-macos/Tests/WalletToolLayerTests/ShieldIntentTests.swift`

**Interfaces:**
- Consumes: `PrivacyHelperSidecar.prepareShield` (Task 7); the existing UserOp build+sign+submit path (Kernel `execute(to,value,data)` → passkey sign → `localwallet_sendUserOperation`).
- Produces: `ToolIntent.Tool.shield`; `ToolDefinitions.shield`; a send-path branch that maps `args["amount"]` (ETH decimal) → wei → `prepareShield` → Kernel `execute` UserOp.

- [ ] **Step 1: Add `shield` to the `Tool` enum (failing test first)**

```swift
// Tests/WalletToolLayerTests/ShieldIntentTests.swift
import XCTest
@testable import WalletToolLayer

final class ShieldIntentTests: XCTestCase {
    func testShieldToolDecodes() throws {
        let intent = ToolIntent(tool: .shield, args: ["amount": "0.01"], source: .slash)
        XCTAssertEqual(intent.tool, .shield)
    }
    func testShieldDefinitionInPhase1() {
        XCTAssertTrue(ToolDefinitions.phase1.contains { $0.name == "shield" })
    }
}
```

- [ ] **Step 2: Run, verify it fails**

Run: `cd wallet-macos && swift test --filter ShieldIntentTests`
Expected: FAIL — `.shield` not a member; `phase1` lacks shield.

- [ ] **Step 3: Implement the enum + definition**

In `ToolIntent.swift:5`:
```swift
public enum Tool: String, Codable, Sendable {
    case transfer, swap, shield
}
```

In `ToolDefinitions.swift` (add, and include in `phase1`):
```swift
public static let shield = ToolDefinition(
    name: "shield",
    description: """
    Deposit native ETH from the user's smart account into the Privacy Pool (shield).     Use when the user asks to shield, make private, or deposit into the privacy pool.     Sepolia only in this version. If the amount is missing or ambiguous, ask a short     clarifying question instead of calling the tool.
    """,
    parametersJSONSchema: #"""
    {"type":"object","properties":{"amount":{"type":"string","description":"ETH amount to shield as a decimal string, e.g. \"0.01\". Native ETH only."}},"required":["amount"]}
    """#
)

public static let phase1: [ToolDefinition] = [transfer, swap, shield]
```

- [ ] **Step 4: Run, verify it passes**

Run: `swift test --filter ShieldIntentTests`
Expected: PASS.

- [ ] **Step 5: Wire the send-path branch**

Run: `grep -rln "case .transfer\|Tool.transfer\|\.swap" wallet-macos/Sources/WalletMacOSApp` to find the intent dispatcher.
In that dispatcher add a `.shield` branch:
1. parse `args["amount"]` ETH decimal → wei (reuse the existing ETH-decimal→wei helper used by `transfer`; grep `weiFrom`/`parseEther`/`decimal`),
2. `let tx = try await sidecar.prepareShield(amountWei: wei)`,
3. build a Kernel `execute(to: tx.to, value: UInt256(tx.value), data: tx.data)` UserOp via the **same** builder `transfer` uses,
4. sign with the passkey + submit via the existing `sendUserOperation` path,
5. on success, trigger a shielded-balance refresh (Task 9).

> No new signing/submit code — this branch only differs from `transfer` in *where the calldata comes from* (sidecar `prepareShield` instead of a plain ETH transfer). Reuse everything else.

- [ ] **Step 6: Commit**

```bash
git add wallet-macos/Sources/WalletToolLayer/ToolIntent.swift wallet-macos/Sources/WalletToolLayer/ToolDefinitions.swift wallet-macos/Sources/WalletMacOSApp wallet-macos/Tests/WalletToolLayerTests/ShieldIntentTests.swift
git commit -m "feat(app): shield tool intent -> Kernel execute deposit UserOp"
```

---

## Task 9: Shielded-balance display (Swift UI)

**Files:**
- Modify: the SwiftUI view rendering the public ETH balance (grep below).
- Test: a ViewModel-level unit test for the wei→ETH formatting + refresh trigger.

**Interfaces:**
- Consumes: `PrivacyHelperSidecar.balanceWei` (Task 7).
- Produces: a "Shielded" balance row that shows `balanceWei` formatted as ETH, refreshed after a successful shield (Task 8) and on a light poll.

- [ ] **Step 1: Locate the balance view + its view model**

Run: `grep -rln "balance" wallet-macos/Sources/WalletMacOSApp | grep -i view`
Identify the view model that fetches/holds the public balance.

- [ ] **Step 2: Write a failing formatting/refresh unit test**

```swift
// Tests/WalletMacOSAppTests/ShieldedBalanceTests.swift
import XCTest
@testable import WalletMacOSApp

final class ShieldedBalanceTests: XCTestCase {
    func testWeiToEthString() {
        XCTAssertEqual(ShieldedBalanceFormatter.eth(fromWei: "10000000000000000"), "0.01")
        XCTAssertEqual(ShieldedBalanceFormatter.eth(fromWei: "0"), "0")
    }
}
```

- [ ] **Step 3: Run, verify it fails**

Run: `cd wallet-macos && swift test --filter ShieldedBalanceTests`
Expected: FAIL — `ShieldedBalanceFormatter` not found.

- [ ] **Step 4: Implement the formatter + the view row**

```swift
enum ShieldedBalanceFormatter {
    static func eth(fromWei wei: String) -> String {
        guard let v = Decimal(string: wei) else { return "—" }
        let eth = v / Decimal(sign: .plus, exponent: 18, significand: 1)
        var s = "\(eth)"
        if s.contains(".") { while s.hasSuffix("0") { s.removeLast() }; if s.hasSuffix(".") { s.removeLast() } }
        return s
    }
}
```
Add a "Shielded" row to the balance view that calls `sidecar.balanceWei()`, formats via `ShieldedBalanceFormatter.eth`, refreshes after a shield and on a light timer. `ponytail:` reuse the existing public-balance row's layout/refresh; no new balance framework.

- [ ] **Step 5: Run, verify it passes; commit**

Run: `swift test --filter ShieldedBalanceTests`
Expected: PASS.

```bash
git add wallet-macos/Sources/WalletMacOSApp wallet-macos/Tests/WalletMacOSAppTests/ShieldedBalanceTests.swift
git commit -m "feat(app): shielded balance row (wei->ETH), refresh after shield"
```

---

## Task 10: Daemon gas-cap check for ZK deposits

**Files:**
- Inspect/Modify: `local-wallet-daemon/crates/wallet-bundler/src/policy.rs`
- Test: existing daemon test suite + mainnet-fork fixture.

**Interfaces:**
- Produces: a `max_call_gas_limit` high enough that a Kernel `execute` wrapping a Privacy Pools deposit passes `EntryPointSimulations.simulateValidation` without policy rejection.

- [ ] **Step 1: Read the current cap**

Run: `grep -n "max_call_gas_limit" local-wallet-daemon/crates/wallet-bundler/src/policy.rs`
Record the current value and where it's enforced.

- [ ] **Step 2: Decide if a change is needed**

The Sepolia gate (Task 5) plus the first end-to-end shield (Task 11) will reveal whether a deposit is rejected on gas. If Task 11's UserOp is rejected with a gas-cap policy error, raise the cap to fit a ZK pool deposit (PP deposits are gas-heavy). If it passes, **no change** — record "cap sufficient" and skip Steps 3-4.

- [ ] **Step 3: If needed, raise the cap (TDD)**

Add/adjust the policy unit test asserting a deposit-sized `callGasLimit` is accepted, raise `max_call_gas_limit`, then:

Run: `cd local-wallet-daemon && cargo test -p wallet-bundler && cargo fmt --check && cargo clippy --workspace -- -D warnings`
Expected: PASS / clean.

- [ ] **Step 4: Re-run the canonical fork fixture (policy change → required)**

Run: `ETH_RPC_URL=<archive-rpc> WALLET_FORK_BLOCK_NUMBER=25001071 ./scripts/run-kernel-mainnet-fork-check.sh`
Expected: PASS (per CLAUDE.md, required for any policy change).

- [ ] **Step 5: Commit (only if changed)**

```bash
cd local-wallet-daemon
git add crates/wallet-bundler/src/policy.rs
git commit -m "fix(bundler): raise max_call_gas_limit to fit ZK pool deposits"
# then bump the daemon rev pin in local-wallet-mac per CLAUDE.md if shipping
```

---

## Task 11: End-to-end shield round-trip on Sepolia (acceptance)

**Files:** none (acceptance gate).

- [ ] **Step 1: Run the app on Sepolia from Xcode**, ensure the daemon + sidecar both spawn (check logs for sidecar `ready`).

- [ ] **Step 2: Confirm provider routing** — with the app running, the shielded balance shows `0`; kill the daemon process → the shielded-balance refresh errors (reads route through the daemon). Restart.

- [ ] **Step 3: Issue `/shield 0.01`** (or natural language). Approve the passkey (Face/Touch ID) prompt.

- [ ] **Step 4: Verify on-chain** — a `UserOperationEvent` lands; the deposit is observable at the Sepolia entrypoint `0x34A2068192b1297f2a7f85D7D8CdE66F8F0921cB`.

- [ ] **Step 5: Verify the UI** — shielded balance updates `0 → 0.01`.

- [ ] **Step 6: Regression** — existing `/transfer` and `/swap` flows still work with the sidecar running.

- [ ] **Step 7: Record results** in the PR description (tx hash, screenshots). Open the PR from `kohaku-shield-v1`.

---

## Self-review notes

- **Spec coverage:** sidecar (T1-5), provider/Helios unification (T2 + T7 wiring), Keychain custody biometric+device-only (T6), fd-5 transport (T3/T7), shield intent + Kernel execute (T8), balance display (T9), daemon gas cap (T10), all verification bullets (T5 routing, T11 e2e + regression). Recovery/rotation are explicitly PR #2 (not in this plan).
- **Known honest gaps for the implementer:** (a) the app↔daemon transport for the *standalone* Task-5 gate may need an http base-URL variant of `createDaemonProvider` since dev mode is loopback HTTP while the app uses a Unix socket — both supported by `http.request` (`socketPath` vs `host/port`); add the variant if the gate needs it. (b) mnemonic generation is resolved in Task 6 Step 3a (prefer sidecar-generated). (c) Swift spawn/UI tasks carry `fatalError` structural markers that MUST be replaced by mirroring the cited in-repo code — they are not shippable as written.
