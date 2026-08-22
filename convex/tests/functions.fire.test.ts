/**
 * @vitest-environment edge-runtime
 *
 * Function-level coverage for the debug fire path and both snapshot queries:
 * registered names, validators, database effects, session isolation, and
 * exactly-once behavior for a repeated `clientShotId`.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  COUNTDOWN_MS,
  DEBUG_TORSO_DAMAGE,
  INITIAL_AMMO,
  INITIAL_HEALTH,
  MATCH_DURATION_MS,
  PRESENCE_TIMEOUT_MS,
} from "../domain/contract.js";
import type { PlayerSession } from "../domain/contract.js";
import { api, auth, testBackend } from "./harness.js";

type Backend = ReturnType<typeof testBackend>;

const SHOT_ID = "3f0c9a2e-shot-1";

async function storedMatch(t: Backend, matchId: string) {
  return await t.run(async (ctx) => {
    const id = ctx.db.normalizeId("matches", matchId);
    return id === null ? null : await ctx.db.get(id);
  });
}

async function storedPlayer(t: Backend, playerId: string) {
  return await t.run(async (ctx) => {
    const id = ctx.db.normalizeId("players", playerId);
    return id === null ? null : await ctx.db.get(id);
  });
}

async function runningDuel(
  t: Backend,
): Promise<{ host: PlayerSession; guest: PlayerSession }> {
  const host = await t.mutation(api.matches.create, {
    displayName: "VIC",
    arenaRadiusMeters: 30,
  });
  const guest = await t.mutation(api.matches.join, {
    displayName: "JORY",
    code: host.code,
  });
  await t.mutation(api.matches.setReady, { ...auth(host), isReady: true });
  await t.mutation(api.matches.setReady, { ...auth(guest), isReady: true });
  await t.mutation(api.matches.start, auth(host));

  // The countdown is server timed and server persisted: the duel becomes
  // `running` when the scheduled transition writes it, not when a client asks.
  vi.advanceTimersByTime(COUNTDOWN_MS);
  await t.finishInProgressScheduledFunctions();
  // Presses in these tests are strictly later than the `started` event, so the
  // feed order under test is the timestamp order rather than the id tiebreak.
  vi.advanceTimersByTime(1_000);

  return { host, guest };
}

beforeEach(() => {
  vi.useFakeTimers();
});

afterEach(() => {
  vi.useRealTimers();
});

describe("shots:debugFire", () => {
  it("applies server-owned damage and writes exactly one shot and one hit event", async () => {
    const t = testBackend();
    const { host, guest } = await runningDuel(t);

    const result = await t.mutation(api.shots.debugFire, {
      ...auth(host),
      clientShotId: SHOT_ID,
    });

    expect(result).toMatchObject({
      accepted: true,
      outcome: "hit",
      replayed: false,
      damage: DEBUG_TORSO_DAMAGE,
      shooterAmmo: INITIAL_AMMO - 1,
      targetHealth: INITIAL_HEALTH - DEBUG_TORSO_DAMAGE,
    });
    expect(result.eventId).toBeDefined();

    const stored = await t.run(async (ctx) => ({
      shots: await ctx.db.query("shots").collect(),
      hits: (await ctx.db.query("events").collect()).filter(
        (event) => event.type === "hit",
      ),
      players: await ctx.db.query("players").collect(),
    }));

    expect(stored.shots).toHaveLength(1);
    expect(stored.hits).toHaveLength(1);
    const players = new Map(
      stored.players.map((player) => [player._id as string, player]),
    );
    expect(players.get(host.playerId)?.ammo).toBe(INITIAL_AMMO - 1);
    expect(players.get(guest.playerId)?.health).toBe(
      INITIAL_HEALTH - DEBUG_TORSO_DAMAGE,
    );
  });

  it("replays a repeated clientShotId after intervening activity without a second effect", async () => {
    const t = testBackend();
    const { host } = await runningDuel(t);

    const first = await t.mutation(api.shots.debugFire, {
      ...auth(host),
      clientShotId: SHOT_ID,
    });
    await t.mutation(api.shots.debugFire, {
      ...auth(host),
      clientShotId: "other-shot",
    });
    const replay = await t.mutation(api.shots.debugFire, {
      ...auth(host),
      clientShotId: SHOT_ID,
    });

    expect(replay).toEqual({ ...first, replayed: true });

    const stored = await t.run(async (ctx) => ({
      shots: await ctx.db.query("shots").collect(),
      hits: (await ctx.db.query("events").collect()).filter(
        (event) => event.type === "hit",
      ),
    }));

    expect(
      stored.shots.filter((shot) => shot.clientShotId === SHOT_ID),
    ).toHaveLength(1);
    expect(stored.hits).toHaveLength(2);
  });

  it("rejects the guest, a foreign secret, and a duel that is not running", async () => {
    const t = testBackend();
    const { host, guest } = await runningDuel(t);

    const guestShot = await t.mutation(api.shots.debugFire, {
      ...auth(guest),
      clientShotId: "guest-shot",
    });
    expect(guestShot).toMatchObject({
      accepted: false,
      rejectReason: "HOST_ONLY",
    });

    await expect(
      t.mutation(api.shots.debugFire, {
        matchId: host.matchId,
        playerId: host.playerId,
        sessionSecret: guest.sessionSecret,
        clientShotId: "forged-shot",
      }),
    ).rejects.toThrow(/INVALID_SESSION/);

    const lobbyHost = await t.mutation(api.matches.create, {
      displayName: "LOBBY",
      arenaRadiusMeters: 30,
    });
    await t.mutation(api.matches.join, {
      displayName: "GUEST",
      code: lobbyHost.code,
    });
    const early = await t.mutation(api.shots.debugFire, {
      ...auth(lobbyHost),
      clientShotId: "early-shot",
    });
    expect(early).toMatchObject({
      accepted: false,
      rejectReason: "MATCH_NOT_RUNNING",
    });

    expect(await t.run((ctx) => ctx.db.query("shots").collect())).toHaveLength(
      0,
    );
  });
});

describe("queries:matchSnapshot", () => {
  it("requires the caller's own session and marks the local player", async () => {
    const t = testBackend();
    const { host, guest } = await runningDuel(t);
    await t.mutation(api.shots.debugFire, {
      ...auth(host),
      clientShotId: SHOT_ID,
    });

    const snapshot = await t.query(api.queries.matchSnapshot, auth(guest));

    expect(snapshot.localPlayerId).toBe(guest.playerId);
    expect(snapshot.match.phase).toBe("running");
    expect(snapshot.players.map((player) => player.role)).toEqual([
      "host",
      "guest",
    ]);
    expect(snapshot.events[0]?.type).toBe("hit");
    expect(snapshot.events.map((event) => event.createdAt)).toEqual(
      [...snapshot.events].map((event) => event.createdAt).sort((a, b) => b - a),
    );
    expect(JSON.stringify(snapshot)).not.toContain(host.sessionSecret);
    expect(JSON.stringify(snapshot)).not.toContain(guest.sessionSecret);

    await expect(
      t.query(api.queries.matchSnapshot, {
        matchId: guest.matchId,
        playerId: guest.playerId,
        sessionSecret: host.sessionSecret,
      }),
    ).rejects.toThrow(/INVALID_SESSION/);
  });
});

describe("shots:debugFire and authoritative time", () => {
  it("never advances the phase: a countdown press rejects and leaves no end time", async () => {
    const t = testBackend();
    const host = await t.mutation(api.matches.create, {
      displayName: "VIC",
      arenaRadiusMeters: 30,
    });
    const guest = await t.mutation(api.matches.join, {
      displayName: "JORY",
      code: host.code,
    });
    await t.mutation(api.matches.setReady, { ...auth(host), isReady: true });
    await t.mutation(api.matches.setReady, { ...auth(guest), isReady: true });
    await t.mutation(api.matches.start, auth(host));

    // Server time is past the countdown boundary while the guarded activation
    // has not run yet: the press must not promote the duel on its behalf.
    vi.setSystemTime(Date.now() + COUNTDOWN_MS + 1);
    const press = await t.mutation(api.shots.debugFire, {
      ...auth(host),
      clientShotId: "countdown-shot",
    });

    expect(press).toMatchObject({
      accepted: false,
      rejectReason: "MATCH_NOT_RUNNING",
      targetHealth: INITIAL_HEALTH,
      shooterAmmo: INITIAL_AMMO,
    });

    const stored = await storedMatch(t, host.matchId);
    expect(stored?.phase).toBe("countdown");
    expect(stored?.endsAt).toBeUndefined();
    expect(await t.run((ctx) => ctx.db.query("shots").collect())).toHaveLength(0);
  });

  it("rejects a press once the end time has passed without retiring the match itself", async () => {
    const t = testBackend();
    const { host } = await runningDuel(t);
    const endsAt = (await storedMatch(t, host.matchId))?.endsAt ?? 0;

    vi.setSystemTime(endsAt);
    const press = await t.mutation(api.shots.debugFire, {
      ...auth(host),
      clientShotId: "expired-shot",
    });

    expect(press).toMatchObject({
      accepted: false,
      rejectReason: "MATCH_NOT_RUNNING",
    });
    // Only the guarded finish job may write `finished`.
    expect((await storedMatch(t, host.matchId))?.phase).toBe("running");
    expect(await t.run((ctx) => ctx.db.query("shots").collect())).toHaveLength(0);
  });

  it("rejects a stale shooter both before and after the expiry job lands", async () => {
    const t = testBackend();
    const { host } = await runningDuel(t);

    // `connected` is still set here: only heartbeat freshness has lapsed.
    vi.advanceTimersByTime(PRESENCE_TIMEOUT_MS);
    expect((await storedPlayer(t, host.playerId))?.connected).toBe(true);
    expect(
      await t.mutation(api.shots.debugFire, {
        ...auth(host),
        clientShotId: "stale-shot",
      }),
    ).toMatchObject({ accepted: false, rejectReason: "CONNECTION_STALE" });

    await t.finishInProgressScheduledFunctions();
    expect((await storedPlayer(t, host.playerId))?.connected).toBe(false);
    expect(
      await t.mutation(api.shots.debugFire, {
        ...auth(host),
        clientShotId: "expired-presence-shot",
      }),
    ).toMatchObject({ accepted: false, rejectReason: "CONNECTION_STALE" });

    expect(await t.run((ctx) => ctx.db.query("shots").collect())).toHaveLength(0);
  });

  it("omits endsAt during the countdown and exposes the activation-derived one when running", async () => {
    const t = testBackend();
    const host = await t.mutation(api.matches.create, {
      displayName: "VIC",
      arenaRadiusMeters: 30,
    });
    const guest = await t.mutation(api.matches.join, {
      displayName: "JORY",
      code: host.code,
    });
    await t.mutation(api.matches.setReady, { ...auth(host), isReady: true });
    await t.mutation(api.matches.setReady, { ...auth(guest), isReady: true });
    await t.mutation(api.matches.start, auth(host));

    const countdown = await t.query(api.queries.matchSnapshot, auth(host));
    expect(countdown.match.phase).toBe("countdown");
    expect("endsAt" in countdown.match).toBe(false);
    expect(countdown.match.startsAt).toBeDefined();

    vi.advanceTimersByTime(COUNTDOWN_MS);
    await t.finishInProgressScheduledFunctions();
    const activatedAt = Date.now();

    const running = await t.query(api.queries.matchSnapshot, auth(host));
    const spectator = await t.query(api.queries.spectatorSnapshot, {
      code: host.code,
    });
    expect(running.match.endsAt).toBe(activatedAt + MATCH_DURATION_MS);
    expect(spectator?.match.endsAt).toBe(running.match.endsAt);
  });
});

describe("event feed ordering", () => {
  it("orders equal-timestamp events by ascending id in both projections", async () => {
    const t = testBackend();
    const { host } = await runningDuel(t);

    // Two presses inside the same server millisecond: `createdAt` cannot
    // separate them, so the id tiebreak is the only total order available.
    await t.mutation(api.shots.debugFire, { ...auth(host), clientShotId: "tie-1" });
    await t.mutation(api.shots.debugFire, { ...auth(host), clientShotId: "tie-2" });

    const stored = await t.run((ctx) => ctx.db.query("events").collect());
    const tied = stored.filter((event) => event.createdAt === Date.now());
    expect(tied).toHaveLength(2);
    const expected = tied
      .map((event) => event._id as string)
      .sort((left, right) => (left < right ? -1 : left > right ? 1 : 0));

    const privateSnapshot = await t.query(api.queries.matchSnapshot, auth(host));
    const publicSnapshot = await t.query(api.queries.spectatorSnapshot, {
      code: host.code,
    });

    for (const events of [privateSnapshot.events, publicSnapshot?.events ?? []]) {
      expect(
        events
          .filter((event) => event.createdAt === Date.now())
          .map((event) => event.id),
      ).toEqual(expected);
      expect(events.map((event) => event.createdAt)).toEqual(
        [...events].map((event) => event.createdAt).sort((a, b) => b - a),
      );
    }
  });
});

describe("queries:spectatorSnapshot", () => {
  it("is public, sanitized, and null for an unknown code", async () => {
    const t = testBackend();
    const { host, guest } = await runningDuel(t);
    await t.mutation(api.shots.debugFire, {
      ...auth(host),
      clientShotId: SHOT_ID,
    });

    const snapshot = await t.query(api.queries.spectatorSnapshot, {
      code: host.code,
    });
    expect(snapshot).not.toBeNull();
    if (snapshot === null) return;

    expect(Object.keys(snapshot).sort()).toEqual([
      "events",
      "match",
      "players",
      "serverNow",
    ]);
    expect("localPlayerId" in snapshot).toBe(false);
    expect(snapshot.players.map((player) => player.health)).toEqual([
      INITIAL_HEALTH,
      INITIAL_HEALTH - DEBUG_TORSO_DAMAGE,
    ]);

    const serialized = JSON.stringify(snapshot);
    expect(serialized).not.toContain(host.sessionSecret);
    expect(serialized).not.toContain(guest.sessionSecret);
    expect(serialized).not.toContain("sessionHash");
    expect(serialized).not.toContain("arenaRadiusMeters");

    expect(
      await t.query(api.queries.spectatorSnapshot, { code: "ZZZZZZ" }),
    ).toBeNull();
  });

  it("returns null for short, overlong, and punctuation-only codes", async () => {
    const t = testBackend();
    const { host } = await runningDuel(t);

    expect(
      await t.query(api.queries.spectatorSnapshot, {
        code: host.code.slice(0, 5),
      }),
    ).toBeNull();
    // An overlong code must not truncate onto the live duel.
    expect(
      await t.query(api.queries.spectatorSnapshot, { code: `${host.code}7` }),
    ).toBeNull();
    expect(
      await t.query(api.queries.spectatorSnapshot, { code: "!!-.." }),
    ).toBeNull();

    const punctuated = await t.query(api.queries.spectatorSnapshot, {
      code: host.code.replace(/^(.)/, "$1-"),
    });
    expect(punctuated?.match.code).toBe(host.code);
  });
});

describe("scheduled countdown boundary", () => {
  it("moves both registered snapshots to running with no client mutation or manual patch", async () => {
    const t = testBackend();
    const host = await t.mutation(api.matches.create, {
      displayName: "VIC",
      arenaRadiusMeters: 30,
    });
    const guest = await t.mutation(api.matches.join, {
      displayName: "JORY",
      code: host.code,
    });
    await t.mutation(api.matches.setReady, { ...auth(host), isReady: true });
    await t.mutation(api.matches.setReady, { ...auth(guest), isReady: true });
    await t.mutation(api.matches.start, auth(host));

    expect(
      (await t.query(api.queries.matchSnapshot, auth(host))).match.phase,
    ).toBe("countdown");
    expect(
      (await t.query(api.queries.spectatorSnapshot, { code: host.code }))?.match
        .phase,
    ).toBe("countdown");

    vi.advanceTimersByTime(COUNTDOWN_MS);
    await t.finishInProgressScheduledFunctions();

    // The stored phase is what makes subscriptions rerun; the queries only read it.
    const stored = await t.run(async (ctx) => {
      const id = ctx.db.normalizeId("matches", host.matchId);
      return id === null ? null : await ctx.db.get(id);
    });
    expect(stored?.phase).toBe("running");
    expect(
      (await t.query(api.queries.matchSnapshot, auth(host))).match.phase,
    ).toBe("running");
    expect(
      (await t.query(api.queries.spectatorSnapshot, { code: host.code }))?.match
        .phase,
    ).toBe("running");
  });
});
