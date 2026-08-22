import { describe, expect, it } from "vitest";
import { COUNTDOWN_MS, MATCH_DURATION_MS } from "../domain/contract.js";
import {
  countdownRemainingMs,
  isJoinable,
  isTerminal,
  planActivation,
  resolvePhase,
  shouldFinish,
} from "../domain/lifecycle.js";

const T0 = 1_760_000_000_000;

describe("resolvePhase", () => {
  it("keeps a lobby in the lobby", () => {
    expect(resolvePhase({ phase: "lobby" }, T0)).toBe("lobby");
  });

  it("holds countdown until the server start time", () => {
    const match = { phase: "countdown", startsAt: T0 + COUNTDOWN_MS } as const;

    expect(resolvePhase(match, T0)).toBe("countdown");
    expect(resolvePhase(match, T0 + COUNTDOWN_MS - 1)).toBe("countdown");
  });

  it("never resolves running on read, because only activation may issue endsAt", () => {
    const match = { phase: "countdown", startsAt: T0 + COUNTDOWN_MS } as const;

    expect(resolvePhase(match, T0 + COUNTDOWN_MS)).toBe("countdown");
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

describe("planActivation", () => {
  const startsAt = T0 + COUNTDOWN_MS;
  const countdown = { phase: "countdown", startsAt, durationMs: MATCH_DURATION_MS } as const;

  it("issues the end time from the activation itself", () => {
    expect(planActivation(countdown, startsAt, startsAt)).toEqual({
      phase: "running",
      endsAt: startsAt + MATCH_DURATION_MS,
      message: "DUEL STARTED",
    });
  });

  it("gives a delayed job a full-length duel", () => {
    const late = startsAt + 900;

    expect(planActivation(countdown, startsAt, late)?.endsAt).toBe(late + MATCH_DURATION_MS);
  });

  it("writes nothing before its own boundary", () => {
    expect(planActivation(countdown, startsAt, startsAt - 1)).toBeNull();
  });

  it("writes nothing for a superseded countdown or an already running duel", () => {
    expect(planActivation(countdown, startsAt - 1_000, startsAt)).toBeNull();
    expect(planActivation({ ...countdown, phase: "running" }, startsAt, startsAt)).toBeNull();
  });

  it("never reopens a terminal match", () => {
    expect(planActivation({ ...countdown, phase: "finished" }, startsAt, startsAt)).toBeNull();
    expect(planActivation({ ...countdown, phase: "cancelled" }, startsAt, startsAt)).toBeNull();
  });
});

describe("shouldFinish", () => {
  const startsAt = T0 + COUNTDOWN_MS;
  const endsAt = startsAt + MATCH_DURATION_MS;
  const running = { phase: "running", startsAt, endsAt } as const;

  it("finishes only once its own end time has arrived", () => {
    expect(shouldFinish(running, endsAt, endsAt - 1)).toBe(false);
    expect(shouldFinish(running, endsAt, endsAt)).toBe(true);
  });

  it("ignores a job scheduled for a different end time", () => {
    expect(shouldFinish(running, endsAt - 1_000, endsAt)).toBe(false);
  });

  it("is idempotent and never regresses a terminal match", () => {
    expect(shouldFinish({ ...running, phase: "finished" }, endsAt, endsAt)).toBe(false);
    expect(shouldFinish({ ...running, phase: "cancelled" }, endsAt, endsAt)).toBe(false);
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
