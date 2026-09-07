import { mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { join, relative, resolve } from "node:path";
import type { Reporter, TestCase } from "vitest/node";

/** Runs in Node, so workerd console forwarding cannot silently drop evidence. */
export class LoadReporter implements Reporter {
  private readonly results: unknown[] = [];
  private readonly source = sourceManifest();
  constructor(private readonly filename = "last-load.json", private readonly environment = "local-workerd-synthetic") {}
  onTestCaseResult(test: TestCase): void {
    const annotation = test.annotations().find(item => item.type === "vkz-load");
    const trace = test.annotations().find(item => item.type === "vkz-runtime-trace");
    const outcome = test.result();
    this.results.push({name: test.name, state: outcome.state,
      failures: (outcome.errors ?? []).slice(0, 8).map(error => ({name: error.name, message: error.message.slice(0, 2000)})),
      result: annotation ? JSON.parse(annotation.message) as unknown : null,
      ...(trace ? {diagnostics: JSON.parse(trace.message) as unknown} : {})});
    mkdirSync("reports", {recursive: true});
    writeFileSync(join("reports", this.filename), JSON.stringify({
      generatedAt: new Date().toISOString(), ...this.source,
      environment: this.environment, node: process.version, results: this.results,
    }, null, 2) + "\n");
    process.stdout.write(`Load evidence: reports/${this.filename} (${test.result().state})\n`);
  }
}

/** Hash only reviewed source/configuration paths; never collect environment files. */
function sourceManifest(): {sourceHead: string; sourceFilesSha256: Record<string, string>} {
  const root = resolve("../..");
  const files: string[] = [];
  const walk = (directory: string): void => {
    for (const entry of readdirSync(directory, {withFileTypes: true})) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) walk(path);
      else if (entry.isFile()) files.push(path);
    }
  };
  for (const directory of ["services/combat-worker/src", "services/combat-worker/benchmarks", "packages/combat-protocol/src", "packages/combat-simulation/src"]) walk(join(root, directory));
  for (const file of ["pnpm-lock.yaml", "services/combat-worker/package.json", "services/combat-worker/tsconfig.json", "services/combat-worker/vitest.config.ts", "services/combat-worker/vitest.load.config.ts", "services/combat-worker/vitest.node-load.config.ts", "services/combat-worker/wrangler.jsonc", "services/combat-worker/tests/helpers.ts", "services/combat-worker/tests/catch-up-input.test.ts",
    "ios/VictoriaKillZone/VictoriaKillZone/Services/Realtime/CombatClock.swift",
    "ios/VictoriaKillZone/VictoriaKillZone/Services/Realtime/RealtimeCombatSession.swift"]) files.push(join(root, file));
  return {sourceHead: execFileSync("git", ["rev-parse", "HEAD"], {encoding: "utf8"}).trim(),
    sourceFilesSha256: Object.fromEntries(files.sort().map(path => [relative(root, path), createHash("sha256").update(readFileSync(path)).digest("hex")]))};
}
