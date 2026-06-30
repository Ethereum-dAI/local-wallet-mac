import { HDKey } from "@scure/bip32";
import { mnemonicToSeedSync } from "@scure/bip39";
import { Hex } from "ox";
import type { Keystore } from "@kohaku-eth/plugins";

// The Kohaku Keystore interface (and the reference MnemonicKeystore) type deriveAt as
// async (Promise<Hex>). But the privacy-pools SDK's deriveSecrets calls
// keystore.deriveAt(...) SYNCHRONOUSLY (no await) and feeds the result straight into
// BigInt() — so an async deriveAt yields BigInt(Promise) -> "Failed to parse String to
// BigInt". MnemonicKeystore's derivation is already fully synchronous internally
// (mnemonicToSeedSync + HDKey.derive + Hex.fromBytes), so we mirror it EXACTLY but
// expose deriveAt synchronously. `await keystore.deriveAt()` callers still work
// (await on a non-Promise returns the value). Same libs/versions as MnemonicKeystore,
// so derived keys are byte-identical.
export class SyncMnemonicKeystore {
  readonly _brand = "Keystore" as const;
  constructor(private readonly mnemonic: string) {}

  deriveAt(path: string): Hex.Hex {
    const seed = mnemonicToSeedSync(this.mnemonic);
    const root = HDKey.fromMasterSeed(seed);
    const child = root.derive(path);
    if (!child.privateKey) throw new Error(`Could not derive private key at path ${path}`);
    return Hex.fromBytes(child.privateKey);
  }
}

export function createSyncKeystore(mnemonic: string): Keystore {
  return new SyncMnemonicKeystore(mnemonic) as unknown as Keystore;
}
