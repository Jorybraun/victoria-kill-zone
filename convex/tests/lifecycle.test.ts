import { describe, expect, it } from "vitest";
import { COUNTDOWN_MS, MATCH_DURATION_MS } from "../domain/contract.js";
import { countdownRemainingMs, isJoinable, isTerminal, resolvePhase } from "../domain/lifecycle.js";

const T0 = 1_760_000_000_000;

describe("resolvePhase", () => {
  it("keeps a lobby in the lobby", () => {
    expect(resolvePhase({ phase: "lobby" }, T0)).toBe("lobby");
  });

  it("holds countdown until the server start time", () => {
    const match = { phase: "countdown", startsAt: T0 + COUNTDOWN_MS, endsAt: T0 + 1_000_000 } as const;

    expect(resolvePhase(match, T0)).toBe("countdown");
    expect(resolvePhase(match, T0 + COUNTDOWN_MS - 1)).toBe("countdown");
  });

  it("becomes running at the start time without a write", () => {
    const match = { phase: "countdown", startsAt: T0 + COUNTDOWN_MS, endsAt: T0 + 1_000_000 } as const;

    expect(resolvePhase(match, T0 + COUNTDOWN_MS)).toBe("running");
  });

  it("becomes finished at the end time", () => {
    const startsAt = T0 + COUNTDOWN_MS;
    const match = { phase: "running", startsAt, endsAt: startsAt + MATCH_DURATION_MS } as const;

    expect(resolvePhase(match, startsAt + MATCH_DURATION_MS - 1)).toBe("running");
    expect(resolvePhase(match, startsAt + MATCH_DURATION_MS)).toBe("finished");
  });

  it("never leaves a terminal phase", () => {
    expect(resolvePhase({ phase: "finished", endsAt: T0 - 1 }, T0)).toBe("finished");
    expect(resolvePhase({ phase: "cancelled", endsAt: T0 - 1 }, T0)).toBe("cancelled");
  });
});

describe("phase predicates", () => {
  it("treats only finished and cancelled as terminal", () => {
    expect(isTerminal("finished")).toBe(true);
    expect(isTerminal("cancelled")).toBe(true);
    expect(isTerminal("lobby")).toBe(false);
    expect(isTerminal("countdown")).toBe(false);
    expect(isTerminal("running")).toBe(false);
  });

  it("allows joining only during the lobby", () => {
    expect(isJoinable("lobby")).toBe(true);
    for (const phase of ["countdown", "running", "finished", "cancelled"] as const) {
      expect(isJoinable(phase)).toBe(false);
    }
  });
});

describe("countdownRemainingMs", () => {
  it("counts down from the authoritative start time", () => {
    const match = { phase: "countdown", startsAt: T0 + COUNTDOWN_MS } as const;

    expect(countdownRemainingMs(match, T0)).toBe(COUNTDOWN_MS);
    expect(countdownRemainingMs(match, T0 + 1_000)).toBe(COUNTDOWN_MS - 1_000);
  });

  it("is zero once the duel is running or still in the lobby", () => {
    const match = { phase: "countdown", startsAt: T0 + COUNTDOWN_MS } as const;

    expect(countdownRemainingMs(match, T0 + COUNTDOWN_MS)).toBe(0);
    expect(countdownRemainingMs({ phase: "lobby" }, T0)).toBe(0);
  });
});
