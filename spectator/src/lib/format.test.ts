import { describe, expect, it } from "vitest";

import { clamp, formatCountdown, formatPhase } from "./format";

describe("G2 spectator formatting", () => {
  it("ceil-rounds the authoritative countdown without going negative", () => {
    expect(formatCountdown(3_000)).toBe("3");
    expect(formatCountdown(1)).toBe("1");
    expect(formatCountdown(-500)).toBe("0");
  });

  it("formats every canonical phase as visible text", () => {
    expect(formatPhase("lobby")).toBe("LOBBY");
    expect(formatPhase("countdown")).toBe("COUNTDOWN");
    expect(formatPhase("running")).toBe("RUNNING");
    expect(formatPhase("finished")).toBe("FINISHED");
    expect(formatPhase("cancelled")).toBe("CANCELLED");
  });

  it("clamps health to its supported bounds", () => {
    expect(clamp(-2, 0, 100)).toBe(0);
    expect(clamp(140, 0, 100)).toBe(100);
  });
});
