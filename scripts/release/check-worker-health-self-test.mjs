import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { evaluateWorkerHealth } from "./check-worker-health.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const manifest = JSON.parse(readFileSync(join(ROOT, "release-manifest.json"), "utf8"));

const health = {
  service: "vkz-combat",
  projection: { configured: true },
  manifest: { ...manifest },
  worker: { versionId: "2c8c3a6a-1f0a-4e4f-9e0b-2b5f7d2a1c3d", versionTag: "tag-1",
    workerVersionTag: "vkz-combat-2026.09", releaseSha: manifest.releaseSha, doMigrationTag: manifest.doMigrationTag },
};

const record = evaluateWorkerHealth(health, manifest);
assert.equal(record.versionId, health.worker.versionId);
assert.equal(record.versionTag, "tag-1");
assert.equal(record.workerVersionTag, manifest.workerVersionTag);
assert.equal(record.releaseSha, manifest.releaseSha);
assert.equal(record.protocolVersion, manifest.protocolVersion);
assert.equal(record.doMigrationTag, manifest.doMigrationTag);
assert.equal(JSON.stringify(record).includes("https://"), false);

// Extra health keys (release, worker identity) do not trip the check.
evaluateWorkerHealth({ ...health, extra: 1, worker: null }, manifest);

for (const invalid of [
  null, {},
  { ...health, service: "other" },
  { ...health, manifest: undefined },
  { ...health, manifest: null },
  { ...health, projection: { configured: false } },
  { ...health, projection: undefined },
  { ...health, manifest: { ...manifest, protocolVersion: manifest.protocolVersion + 1 } },
  { ...health, manifest: { ...manifest, convexMinProtocol: manifest.protocolVersion + 1 } },
  { ...health, manifest: { ...manifest, doMigrationTag: "v2" } },
  { ...health, manifest: { ...manifest, rulesSchemaHash: "0".repeat(64) } },
]) {
  assert.throws(() => evaluateWorkerHealth(invalid, manifest), /mismatch/u);
}
// The local protocol must stay inside the manifest's iOS bounds.
for (const probe of [
  { ...manifest, protocolVersion: manifest.iosMinProtocol - 1 },
  { ...manifest, protocolVersion: manifest.iosMaxProtocol + 1 },
]) {
  assert.throws(() => evaluateWorkerHealth(
    { service: "vkz-combat", manifest: { ...health.manifest, protocolVersion: probe.protocolVersion }, worker: {} },
    probe), /mismatch/u);
}
// Unsafe values are sanitized to null, never echoed.
const dirty = evaluateWorkerHealth({
  service: "vkz-combat", projection: { configured: true }, manifest,
  worker: { versionId: "x".repeat(300), versionTag: "a\nb" },
}, manifest);
assert.equal(dirty.versionId, null);
assert.equal(dirty.versionTag, null);

process.stdout.write("Combat Worker health self-tests: PASS\n");
