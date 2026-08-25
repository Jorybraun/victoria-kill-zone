import { describe, expect, it } from "vitest";
import {
  GAMEPLAY,
  isValidDisplayName,
  normalizeArenaRadius,
  normalizeDisplayName,
  normalizeMatchCode,
} from "../domain/config.js";
import {
  matchCodeFromBytes,
  planActivateMatch,
  planCreateMatch,
  planJoinMatch,
  planStartMatch,
} from "../domain/match.js";
import { match, player, T0 } from "./factories.js";

const createInput = {
  displayName: "Victoria",
  centerLatitude: 48.4284,
  centerLongitude: -123.3656,
  now: T0,
};

describe("createMatch planning", () => {
  it("opens the duel in setup with server-owned health, ammo, and duration", () => {
    const plan = planCreateMatch(createInput, "AB12CD");

    expect(plan.match.status).toBe("setup");
    expect(plan.match.code).toBe("AB12CD");
    expect(plan.match.maxPlayers).toBe(GAMEPLAY.maxPlayers);
    expect(plan.match.durationMs).toBe(GAMEPLAY.matchDurationMs);
    expect(plan.match.startsAt).toBeNull();
    expect(plan.match.endsAt).toBeNull();
    expect(plan.host).toMatchObject({
      role: "host",
      lifeState: "alive",
      health: GAMEPLAY.startingHealth,
      ammo: GAMEPLAY.magazineSize,
      kills: 0,
      deaths: 0,
    });
  });

  it("clamps the host-selected arena radius and normalizes display names", () => {
    expect(normalizeArenaRadius(undefined)).toBe(GAMEPLAY.defaultArenaRadiusMeters);
    expect(normalizeArenaRadius(5)).toBe(GAMEPLAY.minArenaRadiusMeters);
    expect(normalizeArenaRadius(400)).toBe(GAMEPLAY.maxArenaRadiusMeters);
    expect(normalizeArenaRadius(42.4)).toBe(42);
    expect(normalizeDisplayName("   ", "Host")).toBe("Host");
    expect(normalizeDisplayName("x".repeat(80), "Host")).toBe("Host");
    expect(isValidDisplayName("x".repeat(20))).toBe(true);
    expect(isValidDisplayName("x".repeat(21))).toBe(false);
    expect(normalizeMatchCode(" ab-12 cd ")).toBe("AB12CD");
    expect(normalizeMatchCode("bad")).toBeNull();
  });

  it("derives match codes deterministically from supplied random bytes", () => {
    const bytes = new Uint8Array([0, 1, 2, 3, 4, 5]);
    expect(matchCodeFromBytes(bytes)).toBe(matchCodeFromBytes(bytes));
    expect(matchCodeFromBytes(bytes)).toHaveLength(GAMEPLAY.matchCodeLength);
    expect(matchCodeFromBytes(bytes)).toMatch(/^[A-HJ-NP-Z2-9]{6}$/);
  });

  it("starts players uncertain in an arena-centered match, inside in a legacy one", () => {
    // Compatibility: existing iOS clients create matches without arenaCenter;
    // those matches must behave exactly as before the geofence slice.
    const legacy = planCreateMatch(createInput, "AB12CD");
    expect(legacy.match.arenaCenterAt).toBeNull();
    expect(legacy.host.arenaState).toBe("inside");

    const geofenced = planCreateMatch({ ...createInput, hasArenaCenter: true }, "AB12CD");
    expect(geofenced.match.arenaCenterAt).toBe(T0);
    expect(geofenced.host).toMatchObject({
      arenaState: "uncertain",
      latitude: null,
      longitude: null,
      locationAccuracyMeters: null,
      locationAt: null,
      outsideStreak: 0,
    });

    const guest = planJoinMatch({ status: "setup" }, 1, {
      displayName: "Rival",
      hasArenaCenter: true,
      now: T0,
    });
    expect(guest.ok && guest.value.guest.arenaState).toBe("uncertain");
  });
});

describe("joinMatch planning", () => {
  it("moves a duel from setup to waiting when the guest joins", () => {
    const plan = planJoinMatch({ status: "setup" }, 1, { displayName: "Rival", now: T0 });

    expect(plan.ok).toBe(true);
    if (!plan.ok) {
      return;
    }

    expect(plan.value.matchPatch).toEqual({ status: "waiting", updatedAt: T0 });
    expect(plan.value.guest).toMatchObject({
      role: "guest",
      displayName: "Rival",
      health: GAMEPLAY.startingHealth,
      ammo: GAMEPLAY.magazineSize,
    });
  });

  it("rejects a third player in a two-player duel", () => {
    expect(planJoinMatch({ status: "setup" }, 2, { displayName: "Third", now: T0 })).toEqual({
      ok: false,
      reason: "match_full",
    });
  });

  it("rejects joining a duel that already started or ended", () => {
    expect(planJoinMatch({ status: "active" }, 1, { displayName: "Late", now: T0 })).toEqual({
      ok: false,
      reason: "match_already_started",
    });
    expect(planJoinMatch({ status: "ended" }, 1, { displayName: "Late", now: T0 })).toEqual({
      ok: false,
      reason: "match_already_started",
    });
  });
});

describe("startMatch planning", () => {
  const waiting = match({ status: "waiting", phase: "lobby", startsAt: null, endsAt: null });
  const players = [player("host", { ready: true }), player("guest", { ready: true })];

  it("starts a waiting duel for the host and stamps the countdown", () => {
    const plan = planStartMatch(waiting, players, "host", T0);

    expect(plan.ok).toBe(true);
    if (!plan.ok) {
      return;
    }

    expect(plan.value.matchPatch).toEqual({
      status: "waiting",
      phase: "countdown",
      startsAt: T0 + GAMEPLAY.countdownMs,
      endsAt: null,
      updatedAt: T0,
    });
  });

  it("rejects a start requested by the guest", () => {
    expect(planStartMatch(waiting, players, "guest", T0)).toEqual({ ok: false, reason: "not_host" });
  });

  it("rejects a start without two connected players", () => {
    expect(planStartMatch(waiting, [player("host")], "host", T0)).toEqual({
      ok: false,
      reason: "opponent_missing",
    });
    expect(
      planStartMatch(
        waiting,
        [player("host", { ready: true }), player("guest", { ready: true, connected: false })],
        "host",
        T0,
      ),
    ).toEqual({ ok: false, reason: "players_not_connected" });
  });

  it("rejects a start until both players are ready", () => {
    expect(planStartMatch(waiting, [player("host"), player("guest")], "host", T0)).toEqual({
      ok: false,
      reason: "players_not_ready",
    });
  });

  it("rejects starting a duel twice", () => {
    expect(planStartMatch(match({ status: "active", phase: "running" }), players, "host", T0)).toEqual({
      ok: false,
      reason: "match_already_started",
    });
    expect(planStartMatch(match({ status: "ended", phase: "finished" }), players, "host", T0)).toEqual({
      ok: false,
      reason: "match_already_started",
    });
  });

  it("activates only the matching countdown at or after startsAt", () => {
    const startsAt = T0 + GAMEPLAY.countdownMs;
    const countdown = match({ status: "waiting", phase: "countdown", startsAt, endsAt: null });
    expect(planActivateMatch(countdown, startsAt, startsAt - 1)).toBeNull();
    expect(planActivateMatch(countdown, startsAt + 1, startsAt)).toBeNull();
    expect(planActivateMatch(countdown, startsAt, startsAt)).toMatchObject({
      matchPatch: { status: "active", phase: "running", endsAt: startsAt + GAMEPLAY.matchDurationMs },
    });
  });
});
