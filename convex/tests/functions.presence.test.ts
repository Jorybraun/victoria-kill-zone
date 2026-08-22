/**
 * @vitest-environment edge-runtime
 *
 * Presence coverage through the registered functions: `connected` must be a
 * server-owned fact that decays on its own, so these tests run the real expiry
 * job and assert the database deltas rather than a projected value.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { HEARTBEAT_INTERVAL_MS, PRESENCE_TIMEOUT_MS } from "../domain/contract.js";
import { api, testBackend } from "./harness.js";

type Backend = ReturnType<typeof testBackend>;

function auth(session: { matchId: string; playerId: string; sessionSecret: string }) {
  return {
    matchId: session.matchId,
    playerId: session.playerId,
    sessionSecret: session.sessionSecret,
  };
}

async function openLobby(t: Backend) {
  const host = await t.mutation(api.matches.create, {
    displayName: "Host",
    arenaRadiusMeters: 30,
  });
  const guest = await t.mutation(api.matches.join, { displayName: "Guest", code: host.code });
  return { host, guest };
}

function storedPlayer(t: Backend, playerId: string) {
  return t.run(async (ctx) => {
    const id = ctx.db.normalizeId("players", playerId);
    return id === null ? null : await ctx.db.get(id);
  });
}

function scheduledJobs(t: Backend) {
  return t.run((ctx) => ctx.db.system.query("_scheduled_functions").collect());
}

describe("players:heartbeat", () => {
  it("renews presence and rearms expiry without touching gameplay state", async () => {
    const t = testBackend();
    const { host } = await openLobby(t);
    const initial = await storedPlayer(t, host.playerId);

    await t.mutation(api.players.heartbeat, auth(host));
    const renewed = await storedPlayer(t, host.playerId);

    expect(renewed?.lastSeenAt ?? 0).toBeGreaterThanOrEqual(initial?.lastSeenAt ?? 0);
    expect(renewed?.connected).toBe(true);
    expect(renewed).toMatchObject({
      health: initial?.health,
      ammo: initial?.ammo,
      ready: initial?.ready,
      displayName: initial?.displayName,
    });

    const armed = (await scheduledJobs(t)).filter(
      (job) => job.name === "players:expirePresence",
    );
    expect(armed.map((job) => job.scheduledTime)).toContain(
      (renewed?.lastSeenAt ?? 0) + PRESENCE_TIMEOUT_MS,
    );
  });

  it("requires the caller's own session", async () => {
    const t = testBackend();
    const { host, guest } = await openLobby(t);

    await expect(
      t.mutation(api.players.heartbeat, {
        ...auth(guest),
        sessionSecret: host.sessionSecret,
      }),
    ).rejects.toThrow(/INVALID_SESSION/);
  });

  it("restores a player the expiry job really disconnected", async () => {
    vi.useFakeTimers();
    try {
      const t = testBackend();
      const { host } = await openLobby(t);
      const initial = await storedPlayer(t, host.playerId);

      // Past the boundary and through the real scheduled job, so the player is
      // genuinely disconnected before the heartbeat has anything to restore.
      vi.advanceTimersByTime(PRESENCE_TIMEOUT_MS);
      await t.finishInProgressScheduledFunctions();

      const expired = await storedPlayer(t, host.playerId);
      expect(expired?.connected).toBe(false);
      expect(expired?.lastSeenAt).toBe(initial?.lastSeenAt);

      await t.mutation(api.players.heartbeat, auth(host));
      const restored = await storedPlayer(t, host.playerId);

      expect(restored?.connected).toBe(true);
      expect(restored?.lastSeenAt ?? 0).toBeGreaterThan(initial?.lastSeenAt ?? 0);
      expect(Date.now() - (restored?.lastSeenAt ?? 0)).toBeLessThan(PRESENCE_TIMEOUT_MS);
      expect(restored?.health).toBe(initial?.health);
      expect(restored?.ammo).toBe(initial?.ammo);

      // The restored presence decays again on its own schedule.
      vi.advanceTimersByTime(PRESENCE_TIMEOUT_MS);
      await t.finishInProgressScheduledFunctions();
      expect((await storedPlayer(t, host.playerId))?.connected).toBe(false);
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("internal.players:expirePresence", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("clears connected on its own with no client call", async () => {
    const t = testBackend();
    const { host, guest } = await openLobby(t);

    expect((await storedPlayer(t, host.playerId))?.connected).toBe(true);

    vi.advanceTimersByTime(PRESENCE_TIMEOUT_MS);
    await t.finishInProgressScheduledFunctions();

    expect((await storedPlayer(t, host.playerId))?.connected).toBe(false);
    expect((await storedPlayer(t, guest.playerId))?.connected).toBe(false);
  });

  it("is superseded by a heartbeat taken before the boundary", async () => {
    const t = testBackend();
    const { host } = await openLobby(t);

    vi.advanceTimersByTime(HEARTBEAT_INTERVAL_MS);
    await t.mutation(api.players.heartbeat, auth(host));

    vi.advanceTimersByTime(PRESENCE_TIMEOUT_MS - HEARTBEAT_INTERVAL_MS);
    await t.finishInProgressScheduledFunctions();

    expect((await storedPlayer(t, host.playerId))?.connected).toBe(true);

    vi.advanceTimersByTime(HEARTBEAT_INTERVAL_MS);
    await t.finishInProgressScheduledFunctions();

    expect((await storedPlayer(t, host.playerId))?.connected).toBe(false);
  });

  it("writes nothing when it runs early or twice", async () => {
    const t = testBackend();
    const { host } = await openLobby(t);
    const lastSeenAt = (await storedPlayer(t, host.playerId))?.lastSeenAt ?? 0;

    await t.mutation(api.internal.expirePresence, {
      playerId: host.playerId,
      expectedLastSeenAt: lastSeenAt,
    });
    expect((await storedPlayer(t, host.playerId))?.connected).toBe(true);

    vi.advanceTimersByTime(PRESENCE_TIMEOUT_MS);
    await t.finishInProgressScheduledFunctions();
    await t.mutation(api.internal.expirePresence, {
      playerId: host.playerId,
      expectedLastSeenAt: lastSeenAt,
    });

    const player = await storedPlayer(t, host.playerId);
    expect(player?.connected).toBe(false);
    expect(player?.lastSeenAt).toBe(lastSeenAt);
  });
});
