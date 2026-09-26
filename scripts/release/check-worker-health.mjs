// Deploy-time combat Worker health gate. The Worker is deployed manually, so
// an unconfigured URL only warns; a configured one must match the manifest.
import { appendFile, writeFile } from "node:fs/promises";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const MANIFEST = JSON.parse(readFileSync(join(ROOT, "release-manifest.json"), "utf8"));
const LIMIT = 128;

class WorkerHealthError extends Error {}
const fail = (code) => { throw new WorkerHealthError(code); };

const text = (value) => (typeof value === "string" && value.length > 0 && value.length <= LIMIT
  && !/[\r\n\u0000-\u001f\u007f]/u.test(value) ? value : null);

// Returns the sanitized worker record on success; throws on any mismatch.
export function evaluateWorkerHealth(health, manifest) {
  const mismatches = [];
  if (health?.service !== "vkz-combat") mismatches.push("service");
  const remote = health?.manifest;
  if (remote === undefined || remote === null || typeof remote !== "object") {
    mismatches.push("manifest");
  } else {
    if (remote.protocolVersion !== manifest.protocolVersion) mismatches.push("protocolVersion");
    if (remote.convexMinProtocol > manifest.protocolVersion) mismatches.push("convexMinProtocol");
    if (!(manifest.iosMinProtocol <= remote.protocolVersion &&
          remote.protocolVersion <= manifest.iosMaxProtocol)) mismatches.push("iosProtocolRange");
    if (remote.doMigrationTag !== manifest.doMigrationTag) mismatches.push("doMigrationTag");
    if (remote.rulesSchemaHash !== manifest.rulesSchemaHash) mismatches.push("rulesSchemaHash");
  }
  if (mismatches.length > 0) throw new WorkerHealthError(`mismatch:${mismatches.join(",")}`);
  const worker = health.worker ?? {};
  return {
    versionId: text(worker.versionId),
    versionTag: text(worker.versionTag),
    workerVersionTag: text(remote.workerVersionTag) ?? text(worker.workerVersionTag),
    releaseSha: text(remote.releaseSha) ?? text(worker.releaseSha),
    protocolVersion: Number.isSafeInteger(remote.protocolVersion) ? remote.protocolVersion : null,
    doMigrationTag: text(remote.doMigrationTag) ?? text(worker.doMigrationTag),
  };
}

async function fetchHealth(workerUrl) {
  const response = await fetch(`${workerUrl}/health`, { redirect: "error", signal: AbortSignal.timeout(10000) });
  if (response.status !== 200) fail("health-http-failed");
  const reader = response.body?.getReader();
  if (!reader) fail("health-empty");
  let body = "", bytes = 0;
  const decoder = new TextDecoder();
  try {
    for (;;) {
      const chunk = await reader.read();
      if (chunk.done) break;
      bytes += chunk.value.length;
      if (bytes > 4096) fail("health-too-large");
      body += decoder.decode(chunk.value, { stream: true });
    }
    return JSON.parse(body + decoder.decode());
  } finally { await reader.cancel(); }
}

export async function main(environment = process.env) {
  const outputPath = environment.VKZ_WORKER_HEALTH_OUTPUT;
  const writeOutput = async (record) => {
    const serialized = JSON.stringify(record);
    if (outputPath) await writeFile(outputPath, `${serialized}\n`, { mode: 0o600 });
    if (environment.GITHUB_OUTPUT) await appendFile(environment.GITHUB_OUTPUT, `worker_version=${serialized}\n`, "utf8");
  };
  const workerUrl = environment.VKZ_COMBAT_WORKER_URL;
  if (workerUrl === undefined || workerUrl === "") {
    // A manually deployed Worker may be absent; that must not block Convex deploys.
    process.stdout.write("::warning::VKZ_COMBAT_WORKER_URL is not set; combat Worker health was not checked.\n");
    await writeOutput({ status: "not-configured" });
    return;
  }
  let origin;
  try {
    const url = new URL(workerUrl);
    if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash || url.pathname !== "/") fail("invalid-origin");
    origin = url.origin;
  } catch (error) {
    if (error instanceof WorkerHealthError) throw error;
    fail("invalid-origin");
  }
  const health = await fetchHealth(origin);
  const record = evaluateWorkerHealth(health, MANIFEST);
  await writeOutput(record);
  process.stdout.write(`Combat Worker health: PASS (${record.doMigrationTag}, protocol ${record.protocolVersion})\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    await main();
  } catch (error) {
    const reason = error instanceof WorkerHealthError ? error.message : "check-failed";
    process.stderr.write(`ERROR: combat Worker health check failed (${reason}).\n`);
    process.exitCode = 1;
  }
}
