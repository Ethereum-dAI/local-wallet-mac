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
