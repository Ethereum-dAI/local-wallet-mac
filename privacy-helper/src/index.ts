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
