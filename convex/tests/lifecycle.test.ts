import { describe, expect, it } from "vitest";
import { COUNTDOWN_MS, MATCH_DURATION_MS } from "../domain/contract.js";
import {
  countdownRemainingMs,
  isJoinable,
  isTerminal,
  resolvePhase,
  scheduledTransition,
} from "../domain/lifecycle.js";

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

describe("scheduledTransition", () => {
  const startsAt = T0 + COUNTDOWN_MS;
  const endsAt = startsAt + MATCH_DURATION_MS;
  const countdown = { phase: "countdown", startsAt, endsAt } as const;

  it("writes running only once the start time has arrived", () => {
    expect(scheduledTransition(countdown, "running", startsAt - 1)).toBeNull();
    expect(scheduledTransition(countdown, "running", startsAt)).toBe("running");
  });

  it("writes finished only once the end time has arrived", () => {
    const running = { ...countdown, phase: "running" } as const;

    expect(scheduledTransition(running, "finished", endsAt - 1)).toBeNull();
    expect(scheduledTransition(running, "finished", endsAt)).toBe("finished");
  });

  it("is a no-op when the record already says the target", () => {
    expect(scheduledTransition({ ...countdown, phase: "running" }, "running", endsAt - 1)).toBeNull();
  });

  it("never reopens a terminal match", () => {
    expect(scheduledTransition({ ...countdown, phase: "finished" }, "running", startsAt)).toBeNull();
    expect(scheduledTransition({ ...countdown, phase: "cancelled" }, "finished", endsAt)).toBeNull();
  });

  it("still lands finished when the running transition never ran", () => {
    expect(scheduledTransition(countdown, "finished", endsAt)).toBe("finished");
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
