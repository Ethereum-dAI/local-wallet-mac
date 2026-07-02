import { type Host, type Storage } from "@kohaku-eth/plugins";
import { PrivacyPoolsV1Protocol, PrivacyPoolsV1_0xBow, E_ADDRESS } from "@kohaku-eth/privacy-pools";
import type { EthereumProvider } from "@kohaku-eth/provider";
import { entropyToMnemonic } from "@scure/bip39";
import { wordlist } from "@scure/bip39/wordlists/english.js";
import { AbiFunction } from "ox";
import { createSyncKeystore } from "./sync-keystore.ts";

export function mnemonicFromEntropyHex(hex: string): string {
  const clean = hex.startsWith("0x") ? hex.slice(2) : hex;
  return entropyToMnemonic(Uint8Array.from(Buffer.from(clean, "hex")), wordlist);
}

// How far back the first sync scans. The full pool history is ~2.7M blocks (~543
// getLogs round-trips) — far too slow and well past the app's RPC timeout. Instead we
// discover the pool by contract call (below) and scan only this recent window, which is
// where a freshly shielded deposit lives. Trade-off: deposits older than the window are
// not seen on first sync. Override with PRIVACY_SYNC_WINDOW_BLOCKS.
const SYNC_WINDOW_BLOCKS = BigInt(process.env.PRIVACY_SYNC_WINDOW_BLOCKS ?? "50000");

const assetConfigFn = AbiFunction.from(
  "function assetConfig(address) view returns (address pool, uint256 minimumDepositAmount, uint256 vettingFeeBPS, uint256 maxRelayFeeBPS)",
);
const scopeFn = AbiFunction.from("function SCOPE() view returns (uint256)");

const addrHex = (b: bigint) => "0x" + b.toString(16); // SDK serialize() form (unpadded)
const addrHexPadded = (b: bigint) => "0x" + b.toString(16).padStart(40, "0"); // valid call target
const hx = (b: bigint) => "0x" + b.toString(16);

// Privacy Pools normally discovers its pool(s) by scanning `PoolRegistered` events from
// the entrypoint's deployment block — the expensive part of a first sync. Instead we read
// the ETH pool directly (entrypoint.assetConfig(E) → pool address; pool.SCOPE()) and seed
// it into the SDK's redux-backed storage along with a recent `lastSyncedBlock`, so sync()
// only scans the recent window. Idempotent: skips once a pool is already stored. The
// serialized shape mirrors what the SDK itself persists (bigints as "0x"-hex).
async function seedRecentScanIfEmpty(
  provider: EthereumProvider,
  storage: Storage,
  chainId: number,
  entrypointAddress: bigint,
  deploymentBlock: bigint,
): Promise<void> {
  const key = `privacy-pool-state-${chainId}-${entrypointAddress}`;
  const existing = storage.get(key);
  if (existing) {
    try {
      if (JSON.parse(existing)?.pools?.poolsTuples?.length > 0) return; // pool already known
    } catch { /* corrupt — reseed below */ }
  }

  const cfgRet = (await provider.request({
    method: "eth_call",
    params: [{ to: addrHexPadded(entrypointAddress), data: AbiFunction.encodeData(assetConfigFn, [E_ADDRESS]) }, "latest"],
  })) as `0x${string}`;
  const poolAddr = BigInt((AbiFunction.decodeResult(assetConfigFn, cfgRet) as readonly unknown[])[0] as string);
  if (poolAddr === 0n) return; // no ETH pool configured — let the SDK fall back to a full scan

  const scopeRet = (await provider.request({
    method: "eth_call",
    params: [{ to: addrHexPadded(poolAddr), data: AbiFunction.encodeData(scopeFn, []) }, "latest"],
  })) as `0x${string}`;
  const scope = AbiFunction.decodeResult(scopeFn, scopeRet) as bigint;

  const head = await provider.getBlockNumber();
  const recentStart = head - SYNC_WINDOW_BLOCKS > deploymentBlock ? head - SYNC_WINDOW_BLOCKS : deploymentBlock;

  const poolKey = addrHex(poolAddr);
  const seed = {
    deposits: { depositsTuples: [] },
    entrypointDeposits: { entrypointDepositsTuples: [] },
    withdrawals: { withdrawalsTuples: [] },
    ragequits: { ragequitsTuples: [] },
    assets: { assetsTuples: [] },
    pools: {
      poolsTuples: [[poolKey, {
        address: poolKey,
        asset: addrHex(BigInt(E_ADDRESS)),
        registeredBlock: hx(recentStart),
        woundDownAtBlock: null,
        scope: hx(scope),
      }]],
    },
    poolsLeaves: { poolLeavesTuples: [] },
    entrypointInfo: { chainId: hx(BigInt(chainId)), entrypointAddress: addrHex(entrypointAddress), deploymentBlock: hx(deploymentBlock) },
    asp: { leaves: [], aspTreeRoot: "0", blockNumber: "0" },
    updateRootEvents: { lastUpdateRootEvent: null },
    sync: { lastSyncedBlock: hx(recentStart) },
  };
  storage.set(key, JSON.stringify(seed));
}

// pp.balance() returns, per asset, an approved entry (no tag) and a pending entry
// (tag === "pending", the unapproved amount). A freshly shielded deposit is unapproved
// until the ASP includes it, so it lands in `pending`. We surface both so the UI can
// show "approved" (withdrawable) separately from "pending" (just deposited, awaiting ASP).
export function splitEthBalanceHexWei(
  balances: { asset: { contract: string }; amount: bigint; tag?: string }[],
  eAddr: string,
): { approved: string; pending: string } {
  const sumWei = (pending: boolean): bigint =>
    balances
      .filter((b) => b.asset.contract.toLowerCase() === eAddr.toLowerCase() && (b.tag === "pending") === pending)
      .reduce((sum, b) => sum + (b.amount ?? 0n), 0n);
  return { approved: "0x" + sumWei(false).toString(16), pending: "0x" + sumWei(true).toString(16) };
}

export function mapShieldTx(op: { txns: { to: string; data: string; value: bigint }[] }): { to: string; data: string; value: string } {
  const tx = op.txns[0];
  if (!tx) throw new Error("prepareShield returned no txns");
  return { to: tx.to, data: tx.data, value: (tx.value ?? 0n).toString() };
}

export function createPrivacyPools(opts: { entropyHex: string; provider: EthereumProvider; storage: Storage; chainId: 11155111 }) {
  const host: Host = {
    // Bound the ASP/network fetch so a hung endpoint can't stall sync() forever.
    network: {
      fetch: (input, init) =>
        fetch(input as any, { ...init, signal: (init as any)?.signal ?? AbortSignal.timeout(10_000) }),
    },
    storage: opts.storage,
    keystore: createSyncKeystore(mnemonicFromEntropyHex(opts.entropyHex)),
    provider: opts.provider,
  };
  // PrivacyPoolsV1_0xBow[chainId].entrypoint has shape { entrypointAddress, deploymentBlock }
  // but IEntrypoint expects { address, deploymentBlock } — remap here.
  const raw = PrivacyPoolsV1_0xBow[opts.chainId].entrypoint;
  const entrypoint = { address: BigInt(raw.entrypointAddress), deploymentBlock: raw.deploymentBlock };
  const pp = new PrivacyPoolsV1Protocol(host, { entrypoint, accountIndex: 0 });
  const ethAsset = { __type: "erc20" as const, contract: E_ADDRESS as `0x${string}` };

  // Seed the recent-window scan state before the first sync. Runs once (idempotent);
  // the SDK reads storage lazily on the first sync, so seeding here takes effect.
  const ensureSeeded = () =>
    seedRecentScanIfEmpty(opts.provider, opts.storage, opts.chainId, entrypoint.address, BigInt(entrypoint.deploymentBlock));

  return {
    // sync() scans the chain (pool deposit logs) and updates local state; balance() only
    // reads that state. Without the sync a just-made deposit is invisible (balance 0x0).
    async balanceHexWei(): Promise<{ approved: string; pending: string; total: string }> {
      await ensureSeeded();
      await pp.sync();
      const split = splitEthBalanceHexWei((await pp.balance([ethAsset])) as any, E_ADDRESS);
      // `total` = the account's full balance in the pool (approved + pending). On testnet
      // the 0xBow ASP publishes no real approved set, so deposits stay pending; the UI
      // surfaces `total` as the shielded balance and annotates the pending portion.
      const total = "0x" + (BigInt(split.approved) + BigInt(split.pending)).toString(16);
      return { ...split, total };
    },
    async prepareShieldEth(amountWei: string) {
      // Sync first so the deposit index is derived from current on-chain state (avoids
      // reusing a depositIndex/precommitment across successive shields).
      await ensureSeeded();
      await pp.sync();
      return mapShieldTx((await pp.prepareShield({ asset: ethAsset, amount: BigInt(amountWei) })) as any);
    },
  };
}
