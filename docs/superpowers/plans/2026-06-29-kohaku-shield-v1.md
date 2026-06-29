# Kohaku Shield v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a private deposit (shield) round-trip on Sepolia — a `privacy-helper` sidecar (single self-contained binary) hosting Kohaku Privacy Pools, fed the shielded entropy over fd-5, serving JSON-RPC over a Unix socket, with chain reads routed through the daemon, plus an in-app shielded-balance display.

**Architecture:** A new `local-wallet-mac/privacy-helper/` Node/TS project is **compiled to one executable** (`bun build --compile`) and bundled at `Contents/Resources/bin/privacy-helper` exactly like `wallet-node`. The Swift app spawns it via the existing `spawnHelper(execPath:readyWrite:aliveRead:secretRead:)` (no argv) — fd-3 ready, fd-4 alive, fd-5 secret. The sidecar reads `{ entropyHex, sidecarSocketPath, daemon: { socketPath, token } }` from fd-5, converts the entropy to a BIP-39 mnemonic (`@scure/bip39`), instantiates `PrivacyPoolsV1Protocol` with a `Host` whose `provider` forwards `eth_*` to the daemon's socket, and serves JSON-RPC (`balance`, `prepareShield`) over a Unix socket the app connects to. A `shield` tool intent turns `prepareShield` output into a Kernel `execute` UserOp signed by the existing passkey; the shielded balance renders next to the public balance.

**Tech Stack:** TypeScript compiled with `bun build --compile`, `@kohaku-eth/privacy-pools` + `@kohaku-eth/plugins` + `@kohaku-eth/provider` + `@scure/bip39`, Swift 6 / SwiftUI, the existing `wallet-node` daemon (Rust) and `wallet-ffi`/`UserOperationSigning` path.

## Global Constraints

- Chains: Mainnet (1) + Sepolia (11155111) only. **v1 targets Sepolia (11155111).**
- PP Sepolia entrypoint `0x34A2068192b1297f2a7f85D7D8CdE66F8F0921cB`, deploymentBlock `8461453` (`PrivacyPoolsV1_0xBow[11155111]`). Native ETH asset uses `E_ADDRESS = 0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee`.
- **No new daemon RPC methods**; the sidecar reuses standard `eth_*` reads. **`local-wallet-protocol`: no changes.**
- Sidecar ships as ONE executable at `Contents/Resources/bin/privacy-helper` (mirrors `wallet-node`); resolved via `Bundle.main.url(forResource:subdirectory:"bin")`. **Do not** add an `argv` parameter to `spawnHelper` / the spawn contract.
- Shielded secret origin: **Swift generates 32 bytes via `SecRandomCopyBytes`**, stored as a Keychain generic-password with `kSecAttrAccessControl = .biometryCurrentSet` + `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, testnet-tagged. Entropy reaches the sidecar only over fd-5 (never argv/env/disk). The sidecar converts entropy→mnemonic; the master never persists in the sidecar (process-lifetime RAM only).
- App↔sidecar transport is a **Unix socket** (path chosen by the app, passed in fd-5, sidecar listens, app connects with a per-launch bearer token) — stdio is NOT wired back to the app by `spawnHelper`.
- Never commit to `main`. Work continues on branch `kohaku-shield-v1`. `docs/` is gitignored — `git add -f` the docs.
- Spec: `docs/superpowers/specs/2026-06-26-kohaku-shield-v1-design.md`.

---

## File structure

**New — `local-wallet-mac/privacy-helper/` (compiled to one binary):**
- `package.json`, `tsconfig.json`, `.gitignore` (`node_modules/`, `dist/`).
- `src/rpc.ts` — JSON-RPC over an HTTP server bound to a Unix socket (bearer-checked).
- `src/daemon-provider.ts` — `EthereumProvider` backed by the daemon's Unix-socket (or HTTP) JSON-RPC.
- `src/secret.ts` — read + parse the fd-5 payload.
- `src/pp.ts` — entropy→mnemonic, build `Host`, instantiate `PrivacyPoolsV1Protocol`, `balanceHexWei()` / `prepareShieldEth()`.
- `src/index.ts` — entry: read fd-5, serve RPC on the socket, ready on fd-3, exit on fd-4 EOF.
- `test/*.test.ts` — `node:test` (run with `bun test` or `node --test`).
- `build.mjs` is replaced by a `bun build --compile` script in `package.json`.

**Modified — Swift (`local-wallet-mac/wallet-macos/Sources/`):**
- `WalletMacOSApp/ShieldedSeedStore.swift` (NEW) — Keychain custody of 32-byte entropy.
- `WalletMacOSApp/PrivacyHelperSidecar.swift` (NEW) — spawn/lifecycle + JSON-RPC client, mirrors `WalletNodeDaemon.swift`.
- `WalletToolLayer/ToolIntent.swift:5` — add `shield` to `Tool`.
- `WalletToolLayer/ToolDefinitions.swift` — add `shield` `ToolDefinition` + include in `phase1`.
- `WalletMacOSApp/AppModel.swift` — `executeShield(amountETH:)`, `@Published shieldedBalanceDisplay`, `refreshShieldedBalance()`.
- `WalletMacOSApp/ChatDashboardView.swift:~2406` — add `.shield` to `executeIfSupported`; render shielded balance near line ~2232.
- `project.yml` — bundle `privacy-helper` binary as a `bin/` resource.

**Modified — daemon (`local-wallet-daemon`):**
- `crates/wallet-bundler/src/policy.rs` — confirm/raise `max_call_gas_limit` for ZK deposits (only if Task 11 rejects on gas).

---

## Task 1: Scaffold project + JSON-RPC-over-Unix-socket server

**Files:**
- Create: `privacy-helper/package.json`, `privacy-helper/tsconfig.json`, `privacy-helper/.gitignore`
- Create: `privacy-helper/src/rpc.ts`
- Test: `privacy-helper/test/rpc.test.ts`

**Interfaces:**
- Produces: `serveRpc(opts: { socketPath: string; token: string; handlers: Record<string, (params: any) => Promise<any>> }): Promise<import("node:http").Server>` — an HTTP server on the Unix socket; each POST is one JSON-RPC 2.0 request; requires `Authorization: Bearer <token>`.

- [ ] **Step 1: `package.json`**

```json
{
  "name": "privacy-helper",
  "private": true,
  "type": "module",
  "version": "0.0.0",
  "scripts": {
    "build": "bun build src/index.ts --compile --outfile dist/privacy-helper",
    "test": "bun test"
  },
  "dependencies": {
    "@kohaku-eth/privacy-pools": "*",
    "@kohaku-eth/plugins": "*",
    "@kohaku-eth/provider": "*",
    "@scure/bip39": "^1.3.0"
  },
  "devDependencies": { "typescript": "^5.5.0" }
}
```

- [ ] **Step 2: `tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2022", "module": "ESNext", "moduleResolution": "bundler",
    "strict": true, "esModuleInterop": true, "skipLibCheck": true, "noEmit": true
  },
  "include": ["src", "test"]
}
```

- [ ] **Step 3: `.gitignore`**

```
node_modules/
dist/
```

- [ ] **Step 4: Failing test**

```ts
// test/rpc.test.ts
import { test, after } from "node:test";
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

test("dispatches an authed request", async () => {
  const server = await serveRpc({ socketPath, token: "tok", handlers: { ping: async () => "pong" } });
  after(() => server.close());
  const r = await post({ jsonrpc: "2.0", id: 1, method: "ping" });
  assert.deepEqual(r.body, { jsonrpc: "2.0", id: 1, result: "pong" });
});

test("rejects a bad token with 401", async () => {
  const r = await post({ jsonrpc: "2.0", id: 2, method: "ping" }, "nope");
  assert.equal(r.status, 401);
});
```

- [ ] **Step 5: Run, verify fail**

Run: `cd local-wallet-mac/privacy-helper && bun install && bun test`
Expected: FAIL — `Cannot find module '../src/rpc.ts'`.

- [ ] **Step 6: Implement `src/rpc.ts`**

```ts
import http from "node:http";

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
    try { require("node:fs").unlinkSync(opts.socketPath); } catch { /* fresh */ }
    server.listen(opts.socketPath, () => resolve(server));
  });
}
```

- [ ] **Step 7: Run, verify pass**

Run: `bun test`
Expected: PASS (both cases).

- [ ] **Step 8: Commit**

```bash
git add -f privacy-helper/package.json privacy-helper/tsconfig.json privacy-helper/.gitignore privacy-helper/src/rpc.ts privacy-helper/test/rpc.test.ts
git commit -m "feat(privacy-helper): scaffold + JSON-RPC over Unix socket (bearer-checked)"
```

---

## Task 2: Daemon-backed `EthereumProvider`

**Files:**
- Create: `privacy-helper/src/daemon-provider.ts`
- Test: `privacy-helper/test/daemon-provider.test.ts`

**Interfaces:**
- Consumes: daemon `eth_*` JSON-RPC over a Unix socket with a `Bearer` token (`eth_chainId`, `eth_getCode`, `eth_call`, `eth_getLogs`, `eth_blockNumber`, `eth_getTransactionReceipt`, `eth_gasPrice`, `eth_estimateGas`, `eth_getBalance`, `eth_getTransactionCount`).
- Produces: `createDaemonProvider(conn: { socketPath?: string; url?: string; token: string }): EthereumProvider`. Supports a Unix socket (app/prod) **and** an HTTP base URL (standalone dev gate). Internal `rpc(method, params)`.

- [ ] **Step 1: Failing test (mock Unix-socket daemon)** — *(identical structure to the prior plan revision; keep both cases: `getChainId` → `eth_chainId` parses `0xaa36a7` → `11155111n`; `getCode` forwards `[addr, "latest"]` → `0x1234`.)*

```ts
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
```

- [ ] **Step 2: Run, verify fail** — Run: `bun test`. Expected: FAIL (module missing).

- [ ] **Step 3: Implement `src/daemon-provider.ts`**

```ts
import http from "node:http";
import type { EthereumProvider } from "@kohaku-eth/provider";

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
    getBalance: async (a) => toBig(await rpc("eth_getBalance", [a, "latest"])),
    getCode: async (a) => await rpc("eth_getCode", [a, "latest"]),
    getGasPrice: async () => toBig(await rpc("eth_gasPrice")),
    getTransactionCount: async (a, b) => Number(toBig(await rpc("eth_getTransactionCount", [a, b ?? "latest"]))),
    getTransactionReceipt: async (h) => (await rpc("eth_getTransactionReceipt", [h])) ?? null,
    getLogs: async (params) => await rpc("eth_getLogs", [params]),
    estimateGas: async (c) => toBig(await rpc("eth_estimateGas", [c])),
    call: async (c) => (await rpc("eth_call", [c, "latest"])) as `0x${string}` | undefined,
    request: async ({ method, params }) => await rpc(method, (params as unknown[]) ?? []),
    waitForTransaction: async (h) => { for (;;) { if (await rpc("eth_getTransactionReceipt", [h])) return; await new Promise((r) => setTimeout(r, 1500)); } },
  } as EthereumProvider;
}

function hostPort(url: string): { host: string; port: number } {
  const u = new URL(url);
  return { host: u.hostname, port: Number(u.port || 80) };
}
```

- [ ] **Step 4: Run, verify pass** — Run: `bun test`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -f privacy-helper/src/daemon-provider.ts privacy-helper/test/daemon-provider.test.ts
git commit -m "feat(privacy-helper): EthereumProvider over daemon socket/HTTP"
```

---

## Task 3: fd-5 secret payload reader

**Files:** Create `privacy-helper/src/secret.ts`; Test `privacy-helper/test/secret.test.ts`.

**Interfaces:**
- Consumes: one JSON object on fd-5 then EOF: `{ "entropyHex": "0x…32bytes", "sidecarSocketPath": "…", "daemon": { "socketPath": "…", "token": "…" } }`.
- Produces: `readSecretPayload(fd: number): Promise<{ entropyHex: string; sidecarSocketPath: string; daemon: { socketPath: string; token: string } }>`.

- [ ] **Step 1: Failing test**

```ts
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
```

- [ ] **Step 2: Run, verify fail** — `bun test` → FAIL (module missing).

- [ ] **Step 3: Implement `src/secret.ts`**

```ts
import fs from "node:fs";

export async function readSecretPayload(fd: number): Promise<{
  entropyHex: string; sidecarSocketPath: string; daemon: { socketPath: string; token: string };
}> {
  const chunks: Buffer[] = [];
  for await (const chunk of fs.createReadStream("", { fd, autoClose: true })) chunks.push(chunk as Buffer);
  const parsed = JSON.parse(Buffer.concat(chunks).toString("utf8").trim());
  if (typeof parsed.entropyHex !== "string" || !parsed.sidecarSocketPath || !parsed.daemon?.socketPath || !parsed.daemon?.token) {
    throw new Error("invalid fd-5 secret payload");
  }
  return parsed;
}
```

- [ ] **Step 4: Run, verify pass** — `bun test` → PASS.

- [ ] **Step 5: Commit**

```bash
git add -f privacy-helper/src/secret.ts privacy-helper/test/secret.test.ts
git commit -m "feat(privacy-helper): read entropy+socket+daemon-conn from fd-5"
```

---

## Task 4: PP host (entropy→mnemonic) + balance/prepareShield mappers

**Files:** Create `privacy-helper/src/pp.ts`; Test `privacy-helper/test/pp.test.ts`.

**Interfaces:**
- Consumes: `EthereumProvider` (T2); `MnemonicKeystore` from `@kohaku-eth/plugins`; `PrivacyPoolsV1Protocol`, `PrivacyPoolsV1_0xBow`, `E_ADDRESS` from `@kohaku-eth/privacy-pools`; `entropyToMnemonic` + english wordlist from `@scure/bip39`.
- Produces:
  - `mnemonicFromEntropyHex(hex: string): string` — `entropyToMnemonic(bytes, wordlist)`.
  - `pickEthBalanceHexWei(balances, eAddr): string` — approved native-ETH amount as **`0x`-prefixed hex** wei (to match Swift `WeiFormatter.ethDisplayString(fromHexWei:)`).
  - `mapShieldTx(op): { to: string; data: string; value: string }`.
  - `createPrivacyPools({ entropyHex, provider, storage, chainId }): { balanceHexWei(): Promise<string>; prepareShieldEth(amountWei: string): Promise<{ to; data; value }> }`.

- [ ] **Step 1: Failing test (pure helpers)**

```ts
// test/pp.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { pickEthBalanceHexWei, mapShieldTx, mnemonicFromEntropyHex } from "../src/pp.ts";

const E = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";

test("pickEthBalanceHexWei returns approved native balance as hex", () => {
  const balances = [
    { asset: { contract: E }, amount: 1000n },
    { asset: { contract: E }, amount: 7n, tag: "pending" },
  ];
  assert.equal(pickEthBalanceHexWei(balances as any, E), "0x3e8"); // 1000
});

test("mapShieldTx extracts to/data/value", () => {
  assert.deepEqual(mapShieldTx({ txns: [{ to: "0xpool", data: "0xabcd", value: 5n }] } as any), { to: "0xpool", data: "0xabcd", value: "5" });
});

test("mnemonicFromEntropyHex yields 24 words for 32-byte entropy", () => {
  const m = mnemonicFromEntropyHex("0x" + "00".repeat(32));
  assert.equal(m.split(" ").length, 24);
});
```

- [ ] **Step 2: Run, verify fail** — `bun test` → FAIL (module missing).

- [ ] **Step 3: Implement `src/pp.ts`**

```ts
import { MnemonicKeystore, type Host, type Storage } from "@kohaku-eth/plugins";
import { PrivacyPoolsV1Protocol, PrivacyPoolsV1_0xBow, E_ADDRESS } from "@kohaku-eth/privacy-pools";
import type { EthereumProvider } from "@kohaku-eth/provider";
import { entropyToMnemonic } from "@scure/bip39";
import { wordlist } from "@scure/bip39/wordlists/english.js";

export function mnemonicFromEntropyHex(hex: string): string {
  const clean = hex.startsWith("0x") ? hex.slice(2) : hex;
  return entropyToMnemonic(Uint8Array.from(Buffer.from(clean, "hex")), wordlist);
}

export function pickEthBalanceHexWei(balances: { asset: { contract: string }; amount: bigint; tag?: string }[], eAddr: string): string {
  const approved = balances.find((b) => b.asset.contract.toLowerCase() === eAddr.toLowerCase() && b.tag !== "pending");
  return "0x" + (approved?.amount ?? 0n).toString(16);
}

export function mapShieldTx(op: { txns: { to: string; data: string; value: bigint }[] }): { to: string; data: string; value: string } {
  const tx = op.txns[0];
  if (!tx) throw new Error("prepareShield returned no txns");
  return { to: tx.to, data: tx.data, value: (tx.value ?? 0n).toString() };
}

export function createPrivacyPools(opts: { entropyHex: string; provider: EthereumProvider; storage: Storage; chainId: 11155111 }) {
  const host: Host = {
    network: { fetch: (input, init) => fetch(input as any, init) },
    storage: opts.storage,
    keystore: new MnemonicKeystore(mnemonicFromEntropyHex(opts.entropyHex)),
    provider: opts.provider,
  };
  const { entrypoint } = PrivacyPoolsV1_0xBow[opts.chainId];
  const pp = new PrivacyPoolsV1Protocol(host, { entrypoint, accountIndex: 0 });
  const ethAsset = { __type: "erc20" as const, contract: E_ADDRESS };
  return {
    async balanceHexWei(): Promise<string> {
      return pickEthBalanceHexWei((await pp.balance([ethAsset])) as any, E_ADDRESS);
    },
    async prepareShieldEth(amountWei: string) {
      return mapShieldTx((await pp.prepareShield({ asset: ethAsset, amount: BigInt(amountWei) })) as any);
    },
  };
}
```

- [ ] **Step 4: Run, verify pass** — `bun test` → PASS (3 cases).

- [ ] **Step 5: Commit**

```bash
git add -f privacy-helper/src/pp.ts privacy-helper/test/pp.test.ts
git commit -m "feat(privacy-helper): entropy->mnemonic host + balance(hex)/prepareShield mappers"
```

---

## Task 5: Entrypoint, file storage, compiled binary + Sepolia gate

**Files:** Create `privacy-helper/src/index.ts`, `privacy-helper/src/file-storage.ts`, `privacy-helper/README.md`.

**Interfaces:**
- Consumes: T1–T4. RPC methods exposed to the app: `balance() → string (0x hex wei)`, `prepareShield({ amountWei }) → { to, data, value }`.
- Produces: a compiled binary `dist/privacy-helper`. fd contract: reads fd-5, listens on `sidecarSocketPath`, writes `"ready\n"` to fd-3, exits on fd-4 EOF.

- [ ] **Step 1: `src/file-storage.ts`** — *(unchanged from prior revision)*

```ts
import fs from "node:fs";
import type { Storage } from "@kohaku-eth/plugins";
export function createFileStorage(filePath: string): Storage {
  const read = (): Record<string, string> => { try { return JSON.parse(fs.readFileSync(filePath, "utf8")); } catch { return {}; } };
  return {
    _brand: "Storage",
    async get(k) { return read()[k] ?? null; },
    async set(k, v) { const all = read(); all[k] = v; fs.writeFileSync(filePath, JSON.stringify(all), { mode: 0o600 }); },
  };
}
```

- [ ] **Step 2: `src/index.ts`**

```ts
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { serveRpc } from "./rpc.ts";
import { createDaemonProvider } from "./daemon-provider.ts";
import { readSecretPayload } from "./secret.ts";
import { createPrivacyPools } from "./pp.ts";
import { createFileStorage } from "./file-storage.ts";

const READY_FD = 3, ALIVE_FD = 4, SECRET_FD = 5, CHAIN_ID = 11155111 as const;

async function main() {
  const { entropyHex, sidecarSocketPath, daemon } = await readSecretPayload(SECRET_FD);
  const provider = createDaemonProvider(daemon);
  const storageFile = path.join(process.env.HOME ?? os.tmpdir(), "Library/Application Support/LocalWallet/privacy-pools-sepolia.json");
  fs.mkdirSync(path.dirname(storageFile), { recursive: true });
  const pp = createPrivacyPools({ entropyHex, provider, storage: createFileStorage(storageFile), chainId: CHAIN_ID });

  await serveRpc({
    socketPath: sidecarSocketPath,
    token: daemon.token, // reuse the per-launch token for app↔sidecar auth too
    handlers: {
      balance: async () => pp.balanceHexWei(),
      prepareShield: async ({ amountWei }: { amountWei: string }) => pp.prepareShieldEth(amountWei),
    },
  });

  fs.writeSync(READY_FD, "ready\n");
  fs.createReadStream("", { fd: ALIVE_FD }).on("end", () => process.exit(0));
}
main().catch((e) => { fs.writeSync(2, `privacy-helper fatal: ${e?.message ?? e}\n`); process.exit(1); });
```

- [ ] **Step 3: Build the binary**

Run: `cd local-wallet-mac/privacy-helper && bun install && bun run build`
Expected: `dist/privacy-helper` exists and is executable (`file dist/privacy-helper` → Mach-O).

- [ ] **Step 4: Manual Sepolia gate (standalone)** — start a dev daemon (`cd ../local-wallet-daemon && cargo run -p wallet-node -- --http 127.0.0.1:0 --print-ready --debug`; note token+addr). Hand-write an fd-5 payload (throwaway 32-byte entropy, `daemon.url` = the http addr, a temp `sidecarSocketPath`), run `dist/privacy-helper` with that fd, then `curl --unix-socket <sidecarSocketPath> -H "Authorization: Bearer <token>" -d '{"jsonrpc":"2.0","id":1,"method":"balance"}' http://x/`. Confirm: `balance` → `"0x0"`; `prepareShield {"amountWei":"10000000000000000"}` → `{to,data,value:"10000000000000000"}`; kill the daemon → `balance` errors. Record commands in `README.md`.

- [ ] **Step 5: Commit**

```bash
git add -f privacy-helper/src/index.ts privacy-helper/src/file-storage.ts privacy-helper/README.md
git commit -m "feat(privacy-helper): entrypoint + file storage + compiled binary + Sepolia gate"
```

---

## Task 6: Shielded-entropy Keychain custody (Swift)

**Files:** Create `wallet-macos/Sources/WalletMacOSApp/ShieldedSeedStore.swift`; Test `wallet-macos/Tests/WalletMacOSAppTests/ShieldedSeedStoreTests.swift`.

**Interfaces:**
- Produces: `struct ShieldedSeedStore { func loadOrCreateEntropyHex(reason: String) throws -> String; func deleteEntropy() throws }`. Stores 32 random bytes (from `SecRandomCopyBytes`) as a Keychain generic-password (biometric + `ThisDeviceOnly`), returns `0x`-prefixed hex. Mirrors the `SecAccessControlCreateWithFlags` pattern in `KeyStore.swift:111-144` but `kSecClassGenericPassword` (the secret must be readable to feed the sidecar). **No BIP-39 in Swift** — the sidecar converts entropy→mnemonic.

- [ ] **Step 1: Failing unit test (access-control construction; Keychain round-trip is a signed-bundle gate)**

```swift
// Tests/WalletMacOSAppTests/ShieldedSeedStoreTests.swift
import XCTest
@testable import WalletMacOSApp

final class ShieldedSeedStoreTests: XCTestCase {
    func testAccessControlIsBiometricAndThisDeviceOnly() throws {
        var err: Unmanaged<CFError>?
        XCTAssertNotNil(ShieldedSeedStore.makeAccessControl(&err))
        XCTAssertNil(err)
    }
    func testEntropyHexShapeFromBytes() {
        let hex = ShieldedSeedStore.hexString(from: Data(repeating: 0xab, count: 32))
        XCTAssertEqual(hex, "0x" + String(repeating: "ab", count: 32))
    }
}
```

- [ ] **Step 2: Run, verify fail** — Run: `cd local-wallet-mac && ./scripts/build-ffi.sh && cd wallet-macos && swift test --filter ShieldedSeedStoreTests`. Expected: FAIL (type missing).

- [ ] **Step 3: Implement `ShieldedSeedStore.swift`**

```swift
import Foundation
import LocalAuthentication
import Security

struct ShieldedSeedStore {
    private let service = "com.localwallet.wallet-macos.shielded-seed"
    private let account = "privacy-pools-sepolia"  // testnet-tagged

    static func makeAccessControl(_ error: inout Unmanaged<CFError>?) -> SecAccessControl? {
        SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.biometryCurrentSet], &error)
    }

    static func hexString(from data: Data) -> String { "0x" + data.map { String(format: "%02x", $0) }.joined() }

    func loadOrCreateEntropyHex(reason: String) throws -> String {
        if let existing = try load(reason: reason) { return existing }
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        let hex = Self.hexString(from: bytes)
        try store(hex)
        return hex
    }

    private func load(reason: String) throws -> String? {
        let context = LAContext(); context.localizedReason = reason
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne, kSecUseAuthenticationContext as String: context,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let s = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return s
    }

    private func store(_ hex: String) throws {
        var acErr: Unmanaged<CFError>?
        guard let ac = Self.makeAccessControl(&acErr) else { throw acErr!.takeRetainedValue() as Error }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecValueData as String: Data(hex.utf8),
            kSecAttrAccessControl as String: ac,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    func deleteEntropy() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
```

- [ ] **Step 4: Manual Keychain round-trip gate** — run the app from Xcode (`LocalWalletApp`), trigger entropy creation, confirm Face/Touch ID on read + persistence across relaunch. (`swift test` can't: `OSStatus -34018` outside a signed bundle.)

- [ ] **Step 5: Run unit test, verify pass; commit**

Run: `cd wallet-macos && swift test --filter ShieldedSeedStoreTests` → PASS.

```bash
git add wallet-macos/Sources/WalletMacOSApp/ShieldedSeedStore.swift wallet-macos/Tests/WalletMacOSAppTests/ShieldedSeedStoreTests.swift
git commit -m "feat(app): shielded-entropy Keychain custody (biometric, device-only, testnet)"
```

---

## Task 7: Spawn the sidecar + JSON-RPC client (Swift)

**Files:** Create `wallet-macos/Sources/WalletMacOSApp/PrivacyHelperSidecar.swift`; modify `project.yml`; Test `wallet-macos/Tests/WalletMacOSAppTests/PrivacyHelperSidecarTests.swift`.

**Interfaces:**
- Consumes: `spawnHelper(execPath:readyWrite:aliveRead:secretRead:) throws -> pid_t` (SpawnHelper); the pipe/`setCloseOnExec`/`closeIfOpen`/`readLineWithTimeout(fd:timeout:)` helpers (`WalletNodeDaemon.swift:172-226, 436-529`); the running `WalletNodeDaemon` `ReadyEvent { token, socketPath }`; `ShieldedSeedStore` (T6).
- Produces: `final class PrivacyHelperSidecar { static func launch(entropyHex: String, daemonSocketPath: String, daemonToken: String) async throws -> PrivacyHelperSidecar; func balanceHexWei() async throws -> String; func prepareShield(amountWei: String) async throws -> (to: String, data: String, value: String) }`.

- [ ] **Step 1: Integration test (mirrors `SpawnHelperTests`; skips if the binary isn't built)**

```swift
// Tests/WalletMacOSAppTests/PrivacyHelperSidecarTests.swift
import XCTest
@testable import WalletMacOSApp

final class PrivacyHelperSidecarTests: XCTestCase {
    func testLaunchAndBalanceZero() async throws {
        try XCTSkipUnless(PrivacyHelperSidecar.resolveBinaryPath() != nil, "build privacy-helper first")
        let mock = try MockDaemonSocket.start { method in method == "eth_getLogs" ? [] : "0x0" } // empty chain
        defer { mock.stop() }
        let sidecar = try await PrivacyHelperSidecar.launch(
            entropyHex: "0x" + String(repeating: "11", count: 32),
            daemonSocketPath: mock.socketPath, daemonToken: "tok")
        let bal = try await sidecar.balanceHexWei()
        XCTAssertEqual(bal, "0x0")
    }
}
```

> `MockDaemonSocket` is a tiny test helper (a `Network.framework`/`socket` listener answering JSON-RPC) — add it under `Tests/WalletMacOSAppTests/Support/`. If a daemon mock already exists in the test target (grep `Mock` + `socket`), reuse it.

- [ ] **Step 2: Run, verify fail** — Run: `swift test --filter PrivacyHelperSidecarTests`. Expected: FAIL (type missing).

- [ ] **Step 3: Implement `PrivacyHelperSidecar.swift`**

Copy the spawn skeleton from `WalletNodeDaemon.launchBlocking` (`WalletNodeDaemon.swift:158-226`): three `pipe()` pairs, `setCloseOnExec` on all six ends, `spawnHelper(execPath: binaryPath, readyWrite: readyPipe[1], aliveRead: alivePipe[0], secretRead: secretPipe[0])`, close child ends in parent, write the fd-5 JSON payload, `readLineWithTimeout(fd: readyPipe[0], timeout: 8)` expecting `"ready"`. The app then connects to `sidecarSocketPath` (the app chose it) and calls JSON-RPC over it.

```swift
import Darwin
import Foundation
import SpawnHelper

final class PrivacyHelperSidecar: @unchecked Sendable {
    private let pid: pid_t
    private var aliveWriteFD: Int32
    private let socketPath: String
    private let token: String

    private init(pid: pid_t, aliveWriteFD: Int32, socketPath: String, token: String) {
        self.pid = pid; self.aliveWriteFD = aliveWriteFD; self.socketPath = socketPath; self.token = token
    }

    static func resolveBinaryPath() -> String? {
        if let p = ProcessInfo.processInfo.environment["LOCAL_WALLET_PRIVACY_HELPER_BIN"], FileManager.default.isExecutableFile(atPath: p) { return p }
        if let p = Bundle.main.url(forResource: "privacy-helper", withExtension: nil, subdirectory: "bin")?.path { return p }
        // dev: ../../privacy-helper/dist/privacy-helper relative to #filePath (mirror WalletNodeDaemon.sourceRootWalletNodePath)
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("privacy-helper/dist/privacy-helper").path
        return FileManager.default.isExecutableFile(atPath: dev) ? dev : nil
    }

    static func launch(entropyHex: String, daemonSocketPath: String, daemonToken: String) async throws -> PrivacyHelperSidecar {
        try await Task.detached(priority: .userInitiated) {
            try launchBlocking(entropyHex: entropyHex, daemonSocketPath: daemonSocketPath, daemonToken: daemonToken)
        }.value
    }

    private static func launchBlocking(entropyHex: String, daemonSocketPath: String, daemonToken: String) throws -> PrivacyHelperSidecar {
        guard let exec = resolveBinaryPath() else { throw AppError.localDaemonLaunchFailed("privacy-helper binary not found") }
        // app owns both the sidecar socket path and a per-launch token
        let socketPath = NSTemporaryDirectory() + "ph-\(UUID().uuidString).sock"
        let payload = try JSONSerialization.data(withJSONObject: [
            "entropyHex": entropyHex, "sidecarSocketPath": socketPath,
            "daemon": ["socketPath": daemonSocketPath, "token": daemonToken],
        ])
        // ... three pipes + setCloseOnExec + spawnHelper(exec, readyPipe[1], alivePipe[0], secretPipe[0]) ...
        // ... write `payload` to secretPipe[1]; close; readLineWithTimeout(fd: readyPipe[0], 8) == "ready" ...
        // (structure copied verbatim from WalletNodeDaemon.launchBlocking; helpers are private there —
        //  either reuse via @testable/internal access or lift the pipe helpers into a shared SpawnSupport file.)
        return PrivacyHelperSidecar(pid: /*pid*/0, aliveWriteFD: /*alivePipe[1]*/ -1, socketPath: socketPath, token: daemonToken)
    }

    private func rpc(_ method: String, _ params: [Any] = []) async throws -> Any {
        // POST {jsonrpc,id,method,params} over the Unix socket at socketPath with Authorization: Bearer token.
        // Mirror WalletNodeClient's unix-socket transport (Configuration(transport:.unixSocket, bearerToken:)).
        fatalError("mirror WalletNodeClient unix-socket POST")
    }
    func balanceHexWei() async throws -> String { try await rpc("balance") as! String }
    func prepareShield(amountWei: String) async throws -> (to: String, data: String, value: String) {
        let r = try await rpc("prepareShield", [["amountWei": amountWei]]) as! [String: String]
        return (r["to"]!, r["data"]!, r["value"]!)
    }
}
```

> The two `// ...` blocks and the `rpc` body must be filled by copying the cited, in-repo code (`WalletNodeDaemon.launchBlocking` for spawn; `WalletNodeClient`'s unix-socket transport for `rpc`). Recommendation: **lift the private pipe helpers** (`setCloseOnExec`, `closeIfOpen`, `readLineWithTimeout`, `writeSecretPayload`-style) into a shared `SpawnSupport.swift` so both `WalletNodeDaemon` and `PrivacyHelperSidecar` use them (DRY) — do this as the first sub-step. Verify by Step 1's test passing; do not ship `fatalError`.

- [ ] **Step 4: Bundle in `project.yml`** — add `privacy-helper/dist/privacy-helper` to `LocalWalletApp` resources under `bin/` (mirror the `wallet-node` resource entry). `xcodegen generate`.

- [ ] **Step 5: Run, verify pass; commit**

Run: `cd local-wallet-mac/privacy-helper && bun run build && cd ../wallet-macos && swift test --filter PrivacyHelperSidecarTests` → PASS.

```bash
git add wallet-macos/Sources/WalletMacOSApp/PrivacyHelperSidecar.swift wallet-macos/Tests/WalletMacOSAppTests project.yml
git commit -m "feat(app): spawn privacy-helper sidecar (single binary, fd-3/4/5, unix-socket RPC)"
```

---

## Task 8: `shield` tool intent → Kernel `execute` deposit UserOp

**Files:** Modify `ToolIntent.swift:5`, `ToolDefinitions.swift`, `AppModel.swift`, `ChatDashboardView.swift:~2406`. Test `Tests/WalletToolLayerTests/ShieldIntentTests.swift`.

**Interfaces:**
- Consumes: `PrivacyHelperSidecar.prepareShield` (T7); `EtherAmountParser.wei(fromETHString:) -> Data`; the transfer pipeline — `AppModel.executeNativeTransfer(recipient:amountETH:logContext:signingReason:) -> UserOperationSendResult` and its internal `executeTransfer`/`UserOperationBuilder` building `KernelExecutionRequest(target:value:callData:)` → `UserOperationSigning.signForSend(...)` → `WalletNodeClient.sendUserOperation(draft:signature:) -> String`.
- Produces: `ToolIntent.Tool.shield`; `ToolDefinitions.shield`; `AppModel.executeShield(amountETH:) async throws -> UserOperationSendResult`; a `.shield` branch in `ChatDashboardView.executeIfSupported`.

- [ ] **Step 1: Failing test (enum + definition)**

```swift
// Tests/WalletToolLayerTests/ShieldIntentTests.swift
import XCTest
@testable import WalletToolLayer
final class ShieldIntentTests: XCTestCase {
    func testShieldToolDecodes() { XCTAssertEqual(ToolIntent(tool: .shield, args: ["amount": "0.01"], source: .slash).tool, .shield) }
    func testShieldInPhase1() { XCTAssertTrue(ToolDefinitions.phase1.contains { $0.name == "shield" }) }
}
```

- [ ] **Step 2: Run, verify fail** — `cd wallet-macos && swift test --filter ShieldIntentTests` → FAIL.

- [ ] **Step 3: Add the enum case + definition**

`ToolIntent.swift:5`:
```swift
public enum Tool: String, Codable, Sendable { case transfer, swap, shield }
```
`ToolDefinitions.swift` (add + include in `phase1`):
```swift
public static let shield = ToolDefinition(
    name: "shield",
    description: """
    Deposit native ETH from the user's smart account into the Privacy Pool (shield).     Use when the user asks to shield, make private, or privately deposit ETH. Sepolia only.     If the amount is missing or ambiguous, ask one short clarifying question instead of calling the tool.
    """,
    parametersJSONSchema: #"""
    {"type":"object","properties":{"amount":{"type":"string","description":"ETH amount to shield as a decimal string, e.g. \"0.01\". Native ETH only."}},"required":["amount"]}
    """#
)
public static let phase1: [ToolDefinition] = [transfer, swap, shield]
```

- [ ] **Step 4: Run, verify pass** — `swift test --filter ShieldIntentTests` → PASS.

- [ ] **Step 5: Add `AppModel.executeShield` (mirror `executeNativeTransfer`)**

In `AppModel.swift`, next to `executeNativeTransfer` (line ~1685), add:
```swift
func executeShield(amountETH: String) async throws -> UserOperationSendResult {
    guard let sidecar = privacyHelper else { throw AppError.localDaemonLaunchFailed("privacy-helper not running") }
    let amountWei = try EtherAmountParser.wei(fromETHString: amountETH) // 32-byte BE Data (validation)
    let tx = try await sidecar.prepareShield(amountWei: decimalString(fromWeiData: amountWei))
    // Build a single Kernel execute(to: tx.to, value: tx.value, data: tx.data) request and run the
    // SAME build->sign->submit path executeNativeTransfer uses (executeTransfer), substituting this
    // KernelExecutionRequest for the native-transfer one (UserOperationBuilder.swift:336-345):
    let request = KernelExecutionRequest(
        target: tx.to,
        value: try EtherAmountParser.wei(fromDecimalWeiString: tx.value),
        callData: Data(hexString: tx.data)
    )
    let result = try await executeTransfer(
        requests: [request],
        logContext: "chat-shield",
        signingReason: "Authorize shielding \(amountETH) ETH on \(activeChain.name)"
    )
    refreshShieldedBalance()
    return result
}
```
> `executeTransfer(requests:logContext:signingReason:)` is the existing internal builder (`AppModel.swift:1851`); confirm its exact parameter label for the request array via `grep -n "func executeTransfer" AppModel.swift` and match it. If `EtherAmountParser` lacks a `fromDecimalWeiString` / `Data(hexString:)`, add the trivial helpers (the sidecar `value` is already wei as a decimal string; `data` is `0x` hex). These are pure — cover each with one assertion in `WalletToolLayerTests`.

- [ ] **Step 6: Wire the dispatcher branch**

In `ChatDashboardView.executeIfSupported` (`ChatDashboardView.swift:~2390`): widen the guard to include `.shield`, and add to the switch:
```swift
case .shield:
    let amount = intent.args["amount"] ?? ""
    let result = try await self.walletModel.executeShield(amountETH: amount)
    // surface result like the .transfer case does
```

- [ ] **Step 7: Build, commit**

Run: `cd wallet-macos && swift build`
```bash
git add wallet-macos/Sources/WalletToolLayer wallet-macos/Sources/WalletMacOSApp/AppModel.swift wallet-macos/Sources/WalletMacOSApp/ChatDashboardView.swift wallet-macos/Tests/WalletToolLayerTests/ShieldIntentTests.swift
git commit -m "feat(app): shield intent -> Kernel execute deposit via prepareShield"
```

---

## Task 9: Shielded-balance display (Swift UI)

**Files:** Modify `AppModel.swift`, `ChatDashboardView.swift:~2232`. Test `Tests/WalletMacOSAppTests/ShieldedBalanceTests.swift`.

**Interfaces:**
- Consumes: `PrivacyHelperSidecar.balanceHexWei` (T7); `WeiFormatter.ethDisplayString(fromHexWei:) -> String` (existing).
- Produces: `@Published private(set) var shieldedBalanceDisplay: String`; `func refreshShieldedBalance()`; a "Shielded" row in the dashboard.

- [ ] **Step 1: Failing test (formatting reuse + default)**

```swift
// Tests/WalletMacOSAppTests/ShieldedBalanceTests.swift
import XCTest
@testable import WalletMacOSApp
final class ShieldedBalanceTests: XCTestCase {
    func testFormatsHexWeiViaSharedFormatter() {
        XCTAssertEqual(WeiFormatter.ethDisplayString(fromHexWei: "0x2386f26fc10000"), "0.01 ETH") // 1e16 wei
    }
}
```

- [ ] **Step 2: Run, verify fail/pass** — `swift test --filter ShieldedBalanceTests`. (If it already passes, the formatter is confirmed; proceed — the value is to lock the format contract the UI relies on.)

- [ ] **Step 3: Add the AppModel state + refresh**

```swift
@Published private(set) var shieldedBalanceDisplay: String = "—"

func refreshShieldedBalance() {
    guard let sidecar = privacyHelper else { return }
    Task {
        do {
            let hexWei = try await sidecar.balanceHexWei()
            await MainActor.run { self.shieldedBalanceDisplay = WeiFormatter.ethDisplayString(fromHexWei: hexWei) }
        } catch { appendLog("shielded-balance refresh failed: \(error.localizedDescription)") }
    }
}
```
Call `refreshShieldedBalance()` after sidecar launch, after a successful shield (already wired in T8), and from the existing `refreshBalance()` (`AppModel.swift:392`) so the manual refresh button covers both.

- [ ] **Step 4: Add the UI row** — near `ChatDashboardView.swift:2232` where `kernelBalance` is shown, add a "Shielded" line bound to `walletModel.shieldedBalanceDisplay`, reusing the same row layout.

- [ ] **Step 5: Build, commit**

Run: `swift build`
```bash
git add wallet-macos/Sources/WalletMacOSApp/AppModel.swift wallet-macos/Sources/WalletMacOSApp/ChatDashboardView.swift wallet-macos/Tests/WalletMacOSAppTests/ShieldedBalanceTests.swift
git commit -m "feat(app): shielded balance row (hex wei via WeiFormatter), refresh after shield"
```

---

## Task 10: Daemon gas-cap check for ZK deposits

**Files:** Inspect/Modify `local-wallet-daemon/crates/wallet-bundler/src/policy.rs`.

- [ ] **Step 1:** `grep -n "max_call_gas_limit" local-wallet-daemon/crates/wallet-bundler/src/policy.rs` — record value + enforcement.
- [ ] **Step 2:** Only act if Task 11's shield UserOp is rejected on a gas-cap policy error. If it passes, record "cap sufficient" and skip 3-4.
- [ ] **Step 3 (if needed):** add a policy unit test for a deposit-sized `callGasLimit`, raise the cap, then `cd local-wallet-daemon && cargo test -p wallet-bundler && cargo fmt --check && cargo clippy --workspace -- -D warnings` → PASS/clean.
- [ ] **Step 4 (if changed):** `ETH_RPC_URL=<archive-rpc> WALLET_FORK_BLOCK_NUMBER=25001071 ./scripts/run-kernel-mainnet-fork-check.sh` → PASS (required for any policy change).
- [ ] **Step 5 (if changed):** commit; then bump the daemon rev pin in `local-wallet-mac` per CLAUDE.md if shipping.

---

## Task 11: End-to-end shield round-trip on Sepolia (acceptance)

- [ ] **Step 1:** Run the app on Sepolia from Xcode; confirm both daemon + sidecar spawn (sidecar `ready` in logs).
- [ ] **Step 2:** Provider routing — shielded balance shows `0`; kill the daemon → shielded refresh errors; restart.
- [ ] **Step 3:** `/shield 0.01`; approve Face/Touch ID.
- [ ] **Step 4:** Verify a `UserOperationEvent` lands; deposit observable at the Sepolia entrypoint `0x34A2068192b1297f2a7f85D7D8CdE66F8F0921cB`.
- [ ] **Step 5:** Shielded balance updates `0 → 0.01`.
- [ ] **Step 6:** Regression — `/transfer` and `/swap` still work with the sidecar running.
- [ ] **Step 7:** Record tx hash + screenshots in the PR; open the PR from `kohaku-shield-v1`.

---

## Self-review notes

- **Spec coverage:** sidecar (T1-5); provider/Helios unification (T2 + T5/T7 wiring); Keychain custody biometric+device-only (T6); fd-5 transport (T3/T7); shield intent → Kernel execute (T8); balance display (T9); daemon gas cap (T10); verification bullets (T5 routing, T11 e2e + regression). Recovery/rotation remain PR #2.
- **Decisions baked in:** sidecar = single `bun --compile` binary in `Resources/bin` (matches the `wallet-node` precedent; `spawnHelper` has no argv); entropy generated in Swift (`SecRandomCopyBytes`), sidecar does `entropyToMnemonic` (no Swift BIP-39); app↔sidecar over a Unix socket (stdio isn't wired back by `spawnHelper`); balance carried as hex wei to reuse `WeiFormatter`.
- **Remaining `fatalError` markers (Task 7 only):** the spawn body + `rpc` body, to be filled by copying the cited in-repo code; the plan recommends lifting the private pipe helpers into a shared `SpawnSupport.swift` first. These are the only non-shippable markers and are explicitly flagged.
- **Verify-before-completion:** every sidecar task has runnable `bun test`; Swift tasks have unit tests where possible and named manual gates (signed bundle, Sepolia) where not.
