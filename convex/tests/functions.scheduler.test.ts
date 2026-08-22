/**
 * @vitest-environment edge-runtime
 *
 * Scheduled-transition coverage: Convex subscriptions rerun on writes, not on
 * wall-clock time, so the countdown boundary must produce a database write.
 * These tests run the real scheduled functions through the mock backend and
 * assert the stored phase changes with no client mutation and no manual patch.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { COUNTDOWN_MS, MATCH_DURATION_MS } from "../domain/contract.js";
import { api, testBackend } from "./harness.js";

type Backend = ReturnType<typeof testBackend>;

function auth(session: { matchId: string; playerId: string; sessionSecret: string }) {
  return {
    matchId: session.matchId,
    playerId: session.playerId,
    sessionSecret: session.sessionSecret,
  };
}

/** Drives the registered lobby mutations up to a started countdown. */
async function startedMatch(t: Backend) {
  const host = await t.mutation(api.matches.create, {
    displayName: "Host",
    arenaRadiusMeters: 30,
  });
  const guest = await t.mutation(api.matches.join, { displayName: "Guest", code: host.code });
  await t.mutation(api.matches.setReady, { ...auth(host), isReady: true });
  await t.mutation(api.matches.setReady, { ...auth(guest), isReady: true });
  await t.mutation(api.matches.start, auth(host));
  return { host, guest };
}

function storedMatch(t: Backend, matchId: string) {
  return t.run(async (ctx) => {
    const id = ctx.db.normalizeId("matches", matchId);
    return id === null ? null : await ctx.db.get(id);
  });
}

describe("scheduled phase transitions", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("schedules both server-owned boundaries when the countdown starts", async () => {
    const t = testBackend();
    const { host } = await startedMatch(t);

    const scheduled = await t.run((ctx) => ctx.db.system.query("_scheduled_functions").collect());
    expect(scheduled.map((job) => job.name).sort()).toEqual([
      "matches:advanceToFinished",
      "matches:advanceToRunning",
    ]);

    const match = await storedMatch(t, host.matchId);
    expect(scheduled.map((job) => job.scheduledTime).sort()).toEqual([
      match?.startsAt,
      match?.endsAt,
    ]);
  });

  it("persists running at startsAt without a client mutation", async () => {
    const t = testBackend();
    const { host } = await startedMatch(t);

    expect((await storedMatch(t, host.matchId))?.phase).toBe("countdown");

    vi.advanceTimersByTime(COUNTDOWN_MS);
    await t.finishInProgressScheduledFunctions();

    expect((await storedMatch(t, host.matchId))?.phase).toBe("running");
  });

  it("persists finished at endsAt", async () => {
    const t = testBackend();
    const { host } = await startedMatch(t);

    vi.advanceTimersByTime(COUNTDOWN_MS + MATCH_DURATION_MS);
    await t.finishInProgressScheduledFunctions();

    expect((await storedMatch(t, host.matchId))?.phase).toBe("finished");
  });

  it("writes nothing when it runs before its boundary", async () => {
    const t = testBackend();
    const { host } = await startedMatch(t);

    await t.mutation(api.internal.advanceToRunning, { matchId: host.matchId });

    expect((await storedMatch(t, host.matchId))?.phase).toBe("countdown");
  });

  it("is idempotent and never regresses a terminal match", async () => {
    const t = testBackend();
    const { host } = await startedMatch(t);

    vi.advanceTimersByTime(COUNTDOWN_MS + MATCH_DURATION_MS);
    await t.finishInProgressScheduledFunctions();

    await t.mutation(api.internal.advanceToFinished, { matchId: host.matchId });
    await t.mutation(api.internal.advanceToRunning, { matchId: host.matchId });

    expect((await storedMatch(t, host.matchId))?.phase).toBe("finished");
  });
});
