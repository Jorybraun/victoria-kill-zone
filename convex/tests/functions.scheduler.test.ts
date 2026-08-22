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

/** Activation only issues the end time when it runs, so the clock moves twice. */
async function runDuel(t: Backend) {
  vi.advanceTimersByTime(COUNTDOWN_MS);
  await t.finishInProgressScheduledFunctions();
  vi.advanceTimersByTime(MATCH_DURATION_MS);
  await t.finishInProgressScheduledFunctions();
}

async function scheduledNames(t: Backend, name: string) {
  const jobs = await t.run((ctx) => ctx.db.system.query("_scheduled_functions").collect());
  return jobs.filter((job) => job.name === name);
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

  it("schedules the countdown boundary for the countdown it started", async () => {
    const t = testBackend();
    const { host } = await startedMatch(t);
    const match = await storedMatch(t, host.matchId);

    const activation = (
      await t.run((ctx) => ctx.db.system.query("_scheduled_functions").collect())
    ).filter((job) => job.name === "matches:activate");

    expect(activation).toHaveLength(1);
    expect(activation[0]?.scheduledTime).toBe(match?.startsAt);
    expect(activation[0]?.args[0]).toMatchObject({ expectedStartsAt: match?.startsAt });
  });

  it("persists running and its end time at startsAt, with no client mutation", async () => {
    const t = testBackend();
    const { host } = await startedMatch(t);
    const countdown = await storedMatch(t, host.matchId);

    expect(countdown?.phase).toBe("countdown");
    expect(countdown?.endsAt).toBeUndefined();

    vi.advanceTimersByTime(COUNTDOWN_MS);
    await t.finishInProgressScheduledFunctions();

    const running = await storedMatch(t, host.matchId);
    expect(running?.phase).toBe("running");
    expect(running?.endsAt).toBe((running?.startsAt ?? 0) + MATCH_DURATION_MS);

    const events = await t.run((ctx) => ctx.db.query("events").collect());
    expect(events.filter((event) => event.type === "started")).toHaveLength(1);
  });

  it("gives a late activation a full duel measured from when it ran", async () => {
    const t = testBackend();
    const { host } = await startedMatch(t);
    const startsAt = (await storedMatch(t, host.matchId))?.startsAt ?? 0;
    const lateBy = 7_000;

    // A backlogged job must not hand the players a duel that is already partly
    // over, so `endsAt` is measured from the activation, not from `startsAt`.
    vi.advanceTimersByTime(COUNTDOWN_MS + lateBy);
    const activatedAt = Date.now();
    await t.mutation(api.internal.activate, {
      matchId: host.matchId,
      expectedStartsAt: startsAt,
    });

    const running = await storedMatch(t, host.matchId);
    expect(running?.phase).toBe("running");
    expect(running?.endsAt).toBe(activatedAt + MATCH_DURATION_MS);
    expect(running?.endsAt).toBe(startsAt + lateBy + MATCH_DURATION_MS);
    expect(running?.startsAt).toBe(startsAt);

    const events = await t.run((ctx) => ctx.db.query("events").collect());
    expect(events.filter((event) => event.type === "started")).toHaveLength(1);

    const finish = await scheduledNames(t, "matches:finish");
    expect(finish).toHaveLength(1);
    expect(finish[0]?.scheduledTime).toBe(running?.endsAt);
    expect(finish[0]?.args[0]).toMatchObject({
      matchId: host.matchId,
      expectedEndsAt: running?.endsAt,
    });

    // And it still finishes on that boundary rather than the original one.
    vi.advanceTimersByTime(MATCH_DURATION_MS);
    await t.finishInProgressScheduledFunctions();
    expect((await storedMatch(t, host.matchId))?.phase).toBe("finished");
  });

  it("schedules the finish only once the duel is running", async () => {
    const t = testBackend();
    const { host } = await startedMatch(t);

    expect(await scheduledNames(t, "matches:finish")).toHaveLength(0);

    vi.advanceTimersByTime(COUNTDOWN_MS);
    await t.finishInProgressScheduledFunctions();

    const running = await storedMatch(t, host.matchId);
    const finish = await scheduledNames(t, "matches:finish");
    expect(finish).toHaveLength(1);
    expect(finish[0]?.scheduledTime).toBe(running?.endsAt);
    expect(finish[0]?.args[0]).toMatchObject({ expectedEndsAt: running?.endsAt });
  });

  it("persists finished at endsAt", async () => {
    const t = testBackend();
    const { host } = await startedMatch(t);

    await runDuel(t);

    expect((await storedMatch(t, host.matchId))?.phase).toBe("finished");
  });

  it("writes nothing when a job runs before its boundary", async () => {
    const t = testBackend();
    const { host } = await startedMatch(t);
    const startsAt = (await storedMatch(t, host.matchId))?.startsAt ?? 0;

    await t.mutation(api.internal.activate, {
      matchId: host.matchId,
      expectedStartsAt: startsAt,
    });

    const match = await storedMatch(t, host.matchId);
    expect(match?.phase).toBe("countdown");
    expect(match?.endsAt).toBeUndefined();
  });

  it("writes nothing for a job carrying a superseded timestamp", async () => {
    const t = testBackend();
    const { host } = await startedMatch(t);
    const startsAt = (await storedMatch(t, host.matchId))?.startsAt ?? 0;

    vi.advanceTimersByTime(COUNTDOWN_MS);
    await t.mutation(api.internal.activate, {
      matchId: host.matchId,
      expectedStartsAt: startsAt - 1_000,
    });

    expect((await storedMatch(t, host.matchId))?.phase).toBe("countdown");

    await t.finishInProgressScheduledFunctions();
    const running = await storedMatch(t, host.matchId);

    await t.mutation(api.internal.finish, {
      matchId: host.matchId,
      expectedEndsAt: (running?.endsAt ?? 0) - 1_000,
    });

    expect((await storedMatch(t, host.matchId))?.phase).toBe("running");
  });

  it("is idempotent and never regresses a terminal match", async () => {
    const t = testBackend();
    const { host } = await startedMatch(t);

    await runDuel(t);

    const finished = await storedMatch(t, host.matchId);
    await t.mutation(api.internal.finish, {
      matchId: host.matchId,
      expectedEndsAt: finished?.endsAt ?? 0,
    });
    await t.mutation(api.internal.activate, {
      matchId: host.matchId,
      expectedStartsAt: finished?.startsAt ?? 0,
    });

    const match = await storedMatch(t, host.matchId);
    expect(match?.phase).toBe("finished");
    expect(match?.endsAt).toBe(finished?.endsAt);

    const events = await t.run((ctx) => ctx.db.query("events").collect());
    expect(events.filter((event) => event.type === "started")).toHaveLength(1);
  });
});
