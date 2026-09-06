import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// Ephemeral per-run signing material, never a fixture or a deployed credential.
const testSigningKey = Array.from(crypto.getRandomValues(new Uint8Array(32)), (byte) => byte.toString(16).padStart(2, "0")).join("");

export default defineConfig({
  plugins: [cloudflareTest({
    wrangler: { configPath: "./wrangler.jsonc" },
    remoteBindings: false,
    miniflare: { bindings: { COMBAT_TICKET_SECRET: testSigningKey } },
  })],
  test: { include: ["tests/**/*.test.ts"], testTimeout: 10_000, hookTimeout: 10_000 },
});
