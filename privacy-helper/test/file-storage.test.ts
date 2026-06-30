import { test, expect } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createFileStorage } from "../src/file-storage.ts";

test("get/set round-trip on a temp file path", async () => {
  const tmpPath = path.join(os.tmpdir(), `file-storage-test-${Date.now()}.json`);
  try {
    const storage = createFileStorage(tmpPath);
    await storage.set("hello", "world");
    const val = await storage.get("hello");
    expect(val).toBe("world");
  } finally {
    try { fs.unlinkSync(tmpPath); } catch { /* ignore */ }
  }
});

test("get of a missing key returns null", async () => {
  const tmpPath = path.join(os.tmpdir(), `file-storage-test-missing-${Date.now()}.json`);
  // Do NOT create the file — it should not exist
  try {
    const storage = createFileStorage(tmpPath);
    const val = await storage.get("nonexistent");
    expect(val).toBeNull();
  } finally {
    try { fs.unlinkSync(tmpPath); } catch { /* ignore */ }
  }
});
