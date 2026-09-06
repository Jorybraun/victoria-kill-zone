import { mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { join, relative, resolve } from "node:path";
import type { Reporter, TestCase } from "vitest/node";

/** Runs in Node, so workerd console forwarding cannot silently drop evidence. */
export class LoadReporter implements Reporter {
  private readonly results: unknown[] = [];
  private readonly source = sourceManifest();
  onTestCaseResult(test: TestCase): void {
    const annotation = test.annotations().find(item => item.type === "vkz-load");
    this.results.push({name: test.name, state: test.result().state,
      result: annotation ? JSON.parse(annotation.message) as unknown : null});
    mkdirSync("reports", {recursive: true});
    writeFileSync("reports/last-load.json", JSON.stringify({
      generatedAt: new Date().toISOString(), ...this.source,
      environment: "local-workerd-synthetic", node: process.version, results: this.results,
    }, null, 2) + "\n");
    process.stdout.write(`Load evidence: reports/last-load.json (${test.result().state})\n`);
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
  for (const file of ["pnpm-lock.yaml", "services/combat-worker/package.json", "services/combat-worker/tsconfig.json", "services/combat-worker/vitest.config.ts", "services/combat-worker/vitest.load.config.ts", "services/combat-worker/wrangler.jsonc", "services/combat-worker/tests/helpers.ts"]) files.push(join(root, file));
  return {sourceHead: execFileSync("git", ["rev-parse", "HEAD"], {encoding: "utf8"}).trim(),
    sourceFilesSha256: Object.fromEntries(files.sort().map(path => [relative(root, path), createHash("sha256").update(readFileSync(path)).digest("hex")]))};
}
