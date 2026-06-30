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
    // Bound the ASP/network fetch so a hung endpoint can't stall sync() forever.
    network: {
      fetch: (input, init) =>
        fetch(input as any, { ...init, signal: (init as any)?.signal ?? AbortSignal.timeout(10_000) }),
    },
    storage: opts.storage,
    keystore: new MnemonicKeystore(mnemonicFromEntropyHex(opts.entropyHex)),
    provider: opts.provider,
  };
  // PrivacyPoolsV1_0xBow[chainId].entrypoint has shape { entrypointAddress, deploymentBlock }
  // but IEntrypoint expects { address, deploymentBlock } — remap here.
  const raw = PrivacyPoolsV1_0xBow[opts.chainId].entrypoint;
  const entrypoint = { address: BigInt(raw.entrypointAddress), deploymentBlock: raw.deploymentBlock };
  const pp = new PrivacyPoolsV1Protocol(host, { entrypoint, accountIndex: 0 });
  const ethAsset = { __type: "erc20" as const, contract: E_ADDRESS as `0x${string}` };
  return {
    async balanceHexWei(): Promise<string> {
      return pickEthBalanceHexWei((await pp.balance([ethAsset])) as any, E_ADDRESS);
    },
    async prepareShieldEth(amountWei: string) {
      return mapShieldTx((await pp.prepareShield({ asset: ethAsset, amount: BigInt(amountWei) })) as any);
    },
  };
}
