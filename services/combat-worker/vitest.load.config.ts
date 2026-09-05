import { defineConfig } from "vitest/config";
import config from "./vitest.config.js";
import { LoadReporter } from "./benchmarks/load-reporter.js";

const duration = Number(process.env.VKZ_LOAD_MS ?? 30_000);
if (![30_000, 180_000].includes(duration)) throw new Error("VKZ_LOAD_MS must be 30000 or 180000");

// Object spread intentionally replaces include; mergeConfig concatenates arrays
// and accidentally runs every ordinary test as part of the measured workload.
export default defineConfig({...config, define: {__VKZ_LOAD_MS__: String(duration)},
  test: {...config.test, include: ["benchmarks/**/*.load.ts"], testTimeout: duration + 30_000,
    hookTimeout: 10_000, fileParallelism: false, reporters: ["default", new LoadReporter()]},
});
