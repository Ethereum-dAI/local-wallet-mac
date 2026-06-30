import fs from "node:fs";
import type { Storage } from "@kohaku-eth/plugins";

// The Kohaku `Storage` interface types get/set as async (Promise<…>), and Kohaku's
// own MemoryStorage is async too — BUT the privacy-pools SDK's `getChainStore`
// (dist/index.js) calls `storage.get(...)` SYNCHRONOUSLY (no await) and immediately
// `JSON.parse()`s the result. An async get returns a Promise there, which JSON.parse
// coerces to "[object Object]" and throws ("Unexpected identifier object"). That bug
// would hit MemoryStorage too. So we implement get/set SYNCHRONOUSLY (returning the
// raw value): the SDK's sync caller gets a string, and any `await storage.get()`
// caller still works (await on a non-Promise returns the value). Values are stored
// verbatim (the SDK hands us already-stringified JSON), matching MemoryStorage.
export function createFileStorage(filePath: string): Storage {
  const read = (): Record<string, string> => {
    try {
      return JSON.parse(fs.readFileSync(filePath, "utf8"));
    } catch {
      return {};
    }
  };
  return {
    _brand: "Storage",
    get(key: string): string | null {
      return read()[key] ?? null;
    },
    set(key: string, value: string): void {
      const all = read();
      all[key] = value;
      fs.writeFileSync(filePath, JSON.stringify(all), { mode: 0o600 });
    },
  } as unknown as Storage;
}
