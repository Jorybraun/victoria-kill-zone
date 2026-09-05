import { describe, expect, it } from "vitest";
import { TickCadence } from "../src/cadence.js";

describe("authoritative tick cadence", () => {
  it("does not accumulate logical clock drift under repeated late callbacks", () => {
    const cadence = new TickCadence(0);
    let now = 0, matchTimeMs = 0;
    for (let tick = 0; tick < 100; tick += 1) {
      now += cadence.delay(now) + 15;
      expect(cadence.stalled(now)).toBe(false);
      matchTimeMs += 50;
      cadence.committedTick();
      expect(cadence.interpolate(matchTimeMs, now)).toBe(now);
    }
    expect(matchTimeMs).toBe(5000);
    expect(now).toBe(5015);
  });

  it("bounds catch-up and resets downtime without advancing match time", () => {
    const cadence = new TickCadence(1000);
    expect(cadence.stalled(1200)).toBe(false);
    expect(cadence.delay(1200)).toBe(1);
    expect(cadence.interpolate(500, 1200)).toBe(550);
    expect(cadence.stalled(1251)).toBe(true);
    cadence.reset(20_000);
    expect(cadence.interpolate(500, 20_000)).toBe(500);
    expect(cadence.delay(20_000)).toBe(50);
  });
});
