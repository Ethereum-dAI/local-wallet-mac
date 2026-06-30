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
