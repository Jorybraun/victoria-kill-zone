import { describe, expect, it } from "vitest";

import { readDemoFixture, resolveRuntime } from "./runtime";

describe("spectator runtime selection", () => {
  it("uses a deterministic fixture when no backend is configured", () => {
    expect(resolveRuntime(undefined, new URLSearchParams("demo=ended"))).toEqual({
      kind: "demo",
      fixture: "ended",
    });
    expect(readDemoFixture(new URLSearchParams("demo=unknown"))).toBe("active");
  });

  it("accepts HTTPS and local development endpoints", () => {
    expect(
      resolveRuntime(
        "https://example.convex.cloud",
        new URLSearchParams(),
      ),
    ).toEqual({
      kind: "convex",
      deploymentUrl: "https://example.convex.cloud/",
    });
    expect(
      resolveRuntime("http://localhost:3210", new URLSearchParams()).kind,
    ).toBe("convex");
  });

  it("rejects malformed and insecure non-local endpoints", () => {
    expect(resolveRuntime("not-a-url", new URLSearchParams()).kind).toBe(
      "configuration-error",
    );
    expect(
      resolveRuntime("http://example.com", new URLSearchParams()).kind,
    ).toBe("configuration-error");
  });
});
