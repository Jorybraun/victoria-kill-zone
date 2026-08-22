/**
 * @vitest-environment edge-runtime
 *
 * Function-level coverage: these tests call the registered Convex functions
 * through the mock backend, so they exercise argument validators, database
 * writes, indexes, and session isolation rather than pure domain logic alone.
 */
import { describe, expect, it } from "vitest";
import { COUNTDOWN_MS, INITIAL_AMMO, INITIAL_HEALTH } from "../domain/contract.js";
import { api, testBackend } from "./harness.js";

function auth(session: { matchId: string; playerId: string; sessionSecret: string }) {
  return {
    matchId: session.matchId,
    playerId: session.playerId,
    sessionSecret: session.sessionSecret,
  };
}

async function openLobby(t: ReturnType<typeof testBackend>) {
  const host = await t.mutation(api.matches.create, {
    displayName: "Host",
    arenaRadiusMeters: 30,
  });
  const guest = await t.mutation(api.matches.join, {
    displayName: "Guest",
    code: host.code,
  });
  return { host, guest };
}

describe("matches:create", () => {
  it("persists a lobby, a host row, and only a session digest", async () => {
    const t = testBackend();
    const host = await t.mutation(api.matches.create, {
      displayName: "  Host   Player ",
      arenaRadiusMeters: 30,
    });

    expect(host.code).toMatch(/^[A-Z0-9]{6}$/);
    expect(host.sessionSecret.length).toBeGreaterThan(0);

    const stored = await t.run(async (ctx) => {
      const match = await ctx.db.get(ctx.db.normalizeId("matches", host.matchId)!);
      const players = await ctx.db.query("players").collect();
      return { match, players };
    });

    expect(stored.match?.phase).toBe("lobby");
    expect(stored.players).toHaveLength(1);
    expect(stored.players[0]).toMatchObject({
      displayName: "Host Player",
      role: "host",
      ready: false,
      connected: true,
      health: INITIAL_HEALTH,
      ammo: INITIAL_AMMO,
    });
    expect(JSON.stringify(stored.players[0])).not.toContain(host.sessionSecret);
  });

  it("rejects a blank display name through the validator path", async () => {
    const t = testBackend();
    await expect(
      t.mutation(api.matches.create, { displayName: "   ", arenaRadiusMeters: 30 }),
    ).rejects.toThrow(/INVALID_DISPLAY_NAME/);
  });
});

describe("matches:join", () => {
  it("seats the guest and records a joined event", async () => {
    const t = testBackend();
    const { host, guest } = await openLobby(t);

    expect(guest.matchId).toBe(host.matchId);
    expect(guest.sessionSecret).not.toBe(host.sessionSecret);

    const events = await t.run((ctx) => ctx.db.query("events").collect());
    expect(events.map((event) => event.type)).toEqual(["joined", "joined"]);
  });

  it("rejects a malformed code before touching the index", async () => {
    const t = testBackend();
    await expect(t.mutation(api.matches.join, { displayName: "Guest", code: "AB" })).rejects.toThrow(
      /INVALID_CODE/,
    );
  });

  it("rejects an unknown but well-formed code", async () => {
    const t = testBackend();
    await expect(
      t.mutation(api.matches.join, { displayName: "Guest", code: "ZZZZZZ" }),
    ).rejects.toThrow(/MATCH_NOT_FOUND/);
  });

  it("rejects a third player", async () => {
    const t = testBackend();
    const { host } = await openLobby(t);
    await expect(
      t.mutation(api.matches.join, { displayName: "Third", code: host.code }),
    ).rejects.toThrow(/MATCH_FULL/);
  });
});

describe("matches:setReady", () => {
  it("only mutates the calling player", async () => {
    const t = testBackend();
    const { host, guest } = await openLobby(t);

    await t.mutation(api.matches.setReady, { ...auth(host), isReady: true });

    const players = await t.run((ctx) => ctx.db.query("players").collect());
    const readiness = new Map(players.map((player) => [player._id as string, player.ready]));
    expect(readiness.get(host.playerId)).toBe(true);
    expect(readiness.get(guest.playerId)).toBe(false);
  });

  it("rejects a session secret belonging to another player", async () => {
    const t = testBackend();
    const { host, guest } = await openLobby(t);

    await expect(
      t.mutation(api.matches.setReady, {
        matchId: host.matchId,
        playerId: guest.playerId,
        sessionSecret: host.sessionSecret,
        isReady: true,
      }),
    ).rejects.toThrow(/INVALID_SESSION/);
  });

  it("is idempotent and writes one event per transition", async () => {
    const t = testBackend();
    const { host } = await openLobby(t);

    await t.mutation(api.matches.setReady, { ...auth(host), isReady: true });
    await t.mutation(api.matches.setReady, { ...auth(host), isReady: true });

    const events = await t.run((ctx) => ctx.db.query("events").collect());
    expect(events.filter((event) => event.type === "ready")).toHaveLength(1);
  });
});

describe("matches:start", () => {
  it("is host only", async () => {
    const t = testBackend();
    const { host, guest } = await openLobby(t);
    await t.mutation(api.matches.setReady, { ...auth(host), isReady: true });
    await t.mutation(api.matches.setReady, { ...auth(guest), isReady: true });

    await expect(t.mutation(api.matches.start, auth(guest))).rejects.toThrow(/HOST_ONLY/);
  });

  it("requires both players ready", async () => {
    const t = testBackend();
    const { host } = await openLobby(t);
    await t.mutation(api.matches.setReady, { ...auth(host), isReady: true });

    await expect(t.mutation(api.matches.start, auth(host))).rejects.toThrow(/PLAYERS_NOT_READY/);
  });

  it("writes a server-owned countdown window", async () => {
    const t = testBackend();
    const { host, guest } = await openLobby(t);
    await t.mutation(api.matches.setReady, { ...auth(host), isReady: true });
    await t.mutation(api.matches.setReady, { ...auth(guest), isReady: true });

    const before = Date.now();
    await t.mutation(api.matches.start, auth(host));

    const match = await t.run(async (ctx) => {
      const id = ctx.db.normalizeId("matches", host.matchId);
      return id === null ? null : await ctx.db.get(id);
    });

    expect(match?.phase).toBe("countdown");
    expect(match?.startsAt ?? 0).toBeGreaterThanOrEqual(before + COUNTDOWN_MS);
    expect(match?.endsAt ?? 0).toBe((match?.startsAt ?? 0) + (match?.durationMs ?? 0));
  });

  it("cannot be started twice", async () => {
    const t = testBackend();
    const { host, guest } = await openLobby(t);
    await t.mutation(api.matches.setReady, { ...auth(host), isReady: true });
    await t.mutation(api.matches.setReady, { ...auth(guest), isReady: true });
    await t.mutation(api.matches.start, auth(host));

    await expect(t.mutation(api.matches.start, auth(host))).rejects.toThrow(/MATCH_ALREADY_STARTED/);
  });
});
