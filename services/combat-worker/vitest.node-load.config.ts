import {defineConfig} from "vitest/config";
import {LoadReporter} from "./benchmarks/load-reporter.js";

const duration = Number(process.env.VKZ_LOAD_MS ?? 30_000);
if (![30_000, 180_000].includes(duration)) throw new Error("VKZ_LOAD_MS must be 30000 or 180000");

// The clients execute in Node; the harness starts the real workerd subprocess.
export default defineConfig({define: {__VKZ_LOAD_MS__: String(duration)},
  test: {environment: "node", include: ["benchmarks/four-player.node-load.ts"],
    testTimeout: duration + 45_000, hookTimeout: 15_000, fileParallelism: false,
    reporters: ["default", new LoadReporter("last-node-load.json", "node-client-workerd-authority")]},
});
