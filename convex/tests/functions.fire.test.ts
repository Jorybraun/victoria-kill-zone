/**
 * @vitest-environment edge-runtime
 *
 * Function-level coverage for the debug fire path and both snapshot queries:
 * registered names, validators, database effects, session isolation, and
 * exactly-once behavior for a repeated `clientShotId`.
 */
import { describe, expect, it } from "vitest";
import { DEBUG_TORSO_DAMAGE, INITIAL_AMMO, INITIAL_HEALTH } from "../domain/contract.js";
import type { PlayerSession } from "../domain/contract.js";
import { api, auth, testBackend } from "./harness.js";

type Backend = ReturnType<typeof testBackend>;

const SHOT_ID = "3f0c9a2e-shot-1";

async function runningDuel(t: Backend): Promise<{ host: PlayerSession; guest: PlayerSession }> {
  const host = await t.mutation(api.matches.create, { displayName: "VIC", arenaRadiusMeters: 30 });
  const guest = await t.mutation(api.matches.join, { displayName: "JORY", code: host.code });
  await t.mutation(api.matches.setReady, { ...auth(host), isReady: true });
  await t.mutation(api.matches.setReady, { ...auth(guest), isReady: true });
  await t.mutation(api.matches.start, auth(host));

  // The countdown is server timed, so the duel only becomes `running` once the
  // stored window opens.
  await t.run(async (ctx) => {
    const id = ctx.db.normalizeId("matches", host.matchId);
    if (id !== null) {
      await ctx.db.patch(id, { startsAt: Date.now() - 1 });
    }
  });

  return { host, guest };
}

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
      hits: (await ctx.db.query("events").collect()).filter((event) => event.type === "hit"),
      players: await ctx.db.query("players").collect(),
    }));

    expect(stored.shots).toHaveLength(1);
    expect(stored.hits).toHaveLength(1);
    const players = new Map(stored.players.map((player) => [player._id as string, player]));
    expect(players.get(host.playerId)?.ammo).toBe(INITIAL_AMMO - 1);
    expect(players.get(guest.playerId)?.health).toBe(INITIAL_HEALTH - DEBUG_TORSO_DAMAGE);
  });

  it("replays a repeated clientShotId after intervening activity without a second effect", async () => {
    const t = testBackend();
    const { host } = await runningDuel(t);

    const first = await t.mutation(api.shots.debugFire, { ...auth(host), clientShotId: SHOT_ID });
    await t.mutation(api.shots.debugFire, { ...auth(host), clientShotId: "other-shot" });
    const replay = await t.mutation(api.shots.debugFire, { ...auth(host), clientShotId: SHOT_ID });

    expect(replay).toEqual({ ...first, replayed: true });

    const stored = await t.run(async (ctx) => ({
      shots: await ctx.db.query("shots").collect(),
      hits: (await ctx.db.query("events").collect()).filter((event) => event.type === "hit"),
    }));

    expect(stored.shots.filter((shot) => shot.clientShotId === SHOT_ID)).toHaveLength(1);
    expect(stored.hits).toHaveLength(2);
  });

  it("is registered under the matches alias with identical authority", async () => {
    const t = testBackend();
    const { host } = await runningDuel(t);

    const viaMatches = await t.mutation(api.matches.debugFire, {
      ...auth(host),
      clientShotId: SHOT_ID,
    });
    const viaShots = await t.mutation(api.shots.debugFire, { ...auth(host), clientShotId: SHOT_ID });

    expect(viaMatches.accepted).toBe(true);
    expect(viaShots).toEqual({ ...viaMatches, replayed: true });
    expect(await t.run((ctx) => ctx.db.query("shots").collect())).toHaveLength(1);
  });

  it("rejects the guest, a foreign secret, and a duel that is not running", async () => {
    const t = testBackend();
    const { host, guest } = await runningDuel(t);

    const guestShot = await t.mutation(api.shots.debugFire, {
      ...auth(guest),
      clientShotId: "guest-shot",
    });
    expect(guestShot).toMatchObject({ accepted: false, rejectReason: "HOST_ONLY" });

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
    await t.mutation(api.matches.join, { displayName: "GUEST", code: lobbyHost.code });
    const early = await t.mutation(api.shots.debugFire, {
      ...auth(lobbyHost),
      clientShotId: "early-shot",
    });
    expect(early).toMatchObject({ accepted: false, rejectReason: "MATCH_NOT_RUNNING" });

    expect(await t.run((ctx) => ctx.db.query("shots").collect())).toHaveLength(0);
  });
});

describe("queries:matchSnapshot", () => {
  it("requires the caller's own session and marks the local player", async () => {
    const t = testBackend();
    const { host, guest } = await runningDuel(t);
    await t.mutation(api.shots.debugFire, { ...auth(host), clientShotId: SHOT_ID });

    const snapshot = await t.query(api.queries.matchSnapshot, auth(guest));

    expect(snapshot.localPlayerId).toBe(guest.playerId);
    expect(snapshot.match.phase).toBe("running");
    expect(snapshot.players.map((player) => player.role)).toEqual(["host", "guest"]);
    expect(snapshot.events[0]?.type).toBe("hit");
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

describe("queries:spectatorSnapshot", () => {
  it("is public, sanitized, and null for an unknown code", async () => {
    const t = testBackend();
    const { host, guest } = await runningDuel(t);
    await t.mutation(api.shots.debugFire, { ...auth(host), clientShotId: SHOT_ID });

    const snapshot = await t.query(api.queries.spectatorSnapshot, { code: host.code });
    expect(snapshot).not.toBeNull();
    if (snapshot === null) return;

    expect(Object.keys(snapshot).sort()).toEqual(["events", "match", "players", "serverNow"]);
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

    expect(await t.query(api.queries.spectatorSnapshot, { code: "ZZZZZZ" })).toBeNull();
  });
});
