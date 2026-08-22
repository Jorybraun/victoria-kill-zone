/**
 * @vitest-environment edge-runtime
 *
 * Function-level coverage: these tests call the registered Convex functions
 * through the mock backend, so they exercise argument validators, database
 * writes, indexes, and session isolation rather than pure domain logic alone.
 */
import { describe, expect, it } from "vitest";
import {
  COUNTDOWN_MS,
  DISPLAY_NAME_MAX_SCALARS,
  INITIAL_AMMO,
  INITIAL_HEALTH,
  PRESENCE_TIMEOUT_MS,
} from "../domain/contract.js";
import { hashSecret } from "../domain/session.js";
import { api, testBackend } from "./harness.js";

function auth(session: {
  matchId: string;
  playerId: string;
  sessionSecret: string;
}) {
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
    // ADR 0002: a server-issued 256-bit secret, returned exactly once.
    expect(host.sessionSecret).toMatch(/^[0-9a-f]{64}$/);

    const stored = await t.run(async (ctx) => {
      const match = await ctx.db.get(
        ctx.db.normalizeId("matches", host.matchId)!,
      );
      const players = await ctx.db.query("players").collect();
      return { match, players };
    });

    expect(stored.match?.phase).toBe("lobby");
    expect(stored.players).toHaveLength(1);
    expect(stored.players[0]).toMatchObject({
      displayName: "Host   Player",
      role: "host",
      ready: false,
      connected: true,
      health: INITIAL_HEALTH,
      ammo: INITIAL_AMMO,
    });

    // Only the digest is stored, and it is bound to this player's own secret.
    expect(stored.players[0]?.sessionHash).toBe(hashSecret(host.sessionSecret));
    expect(JSON.stringify(stored.players[0])).not.toContain(host.sessionSecret);
  });

  it("initializes server-owned presence and arms its expiry", async () => {
    const t = testBackend();
    const before = Date.now();
    await t.mutation(api.matches.create, { displayName: "Host", arenaRadiusMeters: 30 });

    const stored = await t.run(async (ctx) => ({
      players: await ctx.db.query("players").collect(),
      jobs: await ctx.db.system.query("_scheduled_functions").collect(),
    }));

    expect(stored.players[0]?.lastSeenAt ?? 0).toBeGreaterThanOrEqual(before);
    expect(stored.jobs.map((job) => job.name)).toEqual(["players:expirePresence"]);
    expect(stored.jobs[0]?.scheduledTime).toBe(
      (stored.players[0]?.lastSeenAt ?? 0) + PRESENCE_TIMEOUT_MS,
    );
  });

  it("issues a unique 256-bit secret per player and stores only its digest", async () => {
    const t = testBackend();
    const { host, guest } = await openLobby(t);

    expect(host.sessionSecret).toMatch(/^[0-9a-f]{64}$/);
    expect(guest.sessionSecret).toMatch(/^[0-9a-f]{64}$/);
    expect(host.sessionSecret).not.toBe(guest.sessionSecret);

    const players = await t.run((ctx) => ctx.db.query("players").collect());
    const digests = players.map((player) => player.sessionHash);

    expect(new Set(digests).size).toBe(2);
    expect(digests).toContain(hashSecret(host.sessionSecret));
    expect(digests).toContain(hashSecret(guest.sessionSecret));
    for (const digest of digests) {
      expect(digest).not.toBe(host.sessionSecret);
      expect(digest).not.toBe(guest.sessionSecret);
    }
  });

  it("rejects a non-finite radius instead of coercing it to a playable arena", async () => {
    const t = testBackend();

    for (const arenaRadiusMeters of [
      Number.NaN,
      Number.POSITIVE_INFINITY,
      Number.NEGATIVE_INFINITY,
    ]) {
      await expect(
        t.mutation(api.matches.create, { displayName: "Host", arenaRadiusMeters }),
      ).rejects.toThrow(/finite/);
    }

    expect(await t.run((ctx) => ctx.db.query("matches").collect())).toEqual([]);
  });

  it("rejects a blank or overlong display name through the validator path", async () => {
    const t = testBackend();
    await expect(
      t.mutation(api.matches.create, {
        displayName: "   ",
        arenaRadiusMeters: 30,
      }),
    ).rejects.toThrow(/INVALID_DISPLAY_NAME/);
    await expect(
      t.mutation(api.matches.create, {
        displayName: "V".repeat(DISPLAY_NAME_MAX_SCALARS + 1),
        arenaRadiusMeters: 30,
      }),
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
    await expect(
      t.mutation(api.matches.join, { displayName: "Guest", code: "AB" }),
    ).rejects.toThrow(/INVALID_CODE/);
    await expect(
      t.mutation(api.matches.join, { displayName: "Guest", code: "!!-.." }),
    ).rejects.toThrow(/INVALID_CODE/);
  });

  it("rejects an overlong code instead of truncating it to a real duel", async () => {
    const t = testBackend();
    const { host } = await openLobby(t);

    await expect(
      t.mutation(api.matches.join, {
        displayName: "Third",
        code: `${host.code}7`,
      }),
    ).rejects.toThrow(/INVALID_CODE/);

    // Punctuation is separator noise, so a well-formed code still resolves.
    await expect(
      t.mutation(api.matches.join, {
        displayName: "Third",
        code: host.code.replace(/^(.)/, "$1-"),
      }),
    ).rejects.toThrow(/MATCH_FULL/);
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
    const readiness = new Map(
      players.map((player) => [player._id as string, player.ready]),
    );
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

  it("rejects a malformed secret, the stored digest, and an unrelated match", async () => {
    const t = testBackend();
    const { host } = await openLobby(t);
    const other = await t.mutation(api.matches.create, {
      displayName: "Other",
      arenaRadiusMeters: 30,
    });

    for (const sessionSecret of ["", "not-hex", hashSecret(host.sessionSecret)]) {
      await expect(
        t.mutation(api.matches.setReady, { ...auth(host), sessionSecret, isReady: true }),
      ).rejects.toThrow(/INVALID_SESSION/);
    }

    await expect(
      t.mutation(api.matches.setReady, {
        ...auth(host),
        matchId: other.matchId,
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

    await expect(t.mutation(api.matches.start, auth(guest))).rejects.toThrow(
      /HOST_ONLY/,
    );
  });

  it("requires both players ready", async () => {
    const t = testBackend();
    const { host } = await openLobby(t);
    await t.mutation(api.matches.setReady, { ...auth(host), isReady: true });

    await expect(t.mutation(api.matches.start, auth(host))).rejects.toThrow(
      /PLAYERS_NOT_READY/,
    );
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
    // The end time belongs to activation, so the countdown must not carry one.
    expect(match?.endsAt).toBeUndefined();
  });

  it("rejects a start when a player's presence has gone stale", async () => {
    const t = testBackend();
    const { host, guest } = await openLobby(t);
    await t.mutation(api.matches.setReady, { ...auth(host), isReady: true });
    await t.mutation(api.matches.setReady, { ...auth(guest), isReady: true });

    // The stored flag still says connected: freshness is the defensive check.
    await t.run(async (ctx) => {
      const id = ctx.db.normalizeId("players", guest.playerId);
      if (id !== null) {
        await ctx.db.patch(id, { lastSeenAt: Date.now() - PRESENCE_TIMEOUT_MS });
      }
    });

    await expect(t.mutation(api.matches.start, auth(host))).rejects.toThrow(
      /PLAYERS_NOT_CONNECTED/,
    );

    await t.mutation(api.players.heartbeat, auth(guest));
    await expect(t.mutation(api.matches.start, auth(host))).resolves.toBeNull();
  });

  it("cannot be started twice", async () => {
    const t = testBackend();
    const { host, guest } = await openLobby(t);
    await t.mutation(api.matches.setReady, { ...auth(host), isReady: true });
    await t.mutation(api.matches.setReady, { ...auth(guest), isReady: true });
    await t.mutation(api.matches.start, auth(host));

    await expect(t.mutation(api.matches.start, auth(host))).rejects.toThrow(
      /MATCH_ALREADY_STARTED/,
    );
  });
});
