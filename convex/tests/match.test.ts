import { describe, expect, it } from "vitest";
import { GAMEPLAY, normalizeArenaRadius, normalizeDisplayName } from "../domain/config.js";
import { matchCodeFromBytes, planCreateMatch, planJoinMatch, planStartMatch } from "../domain/match.js";
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
    expect(plan.match.startedAt).toBeNull();
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
    expect(normalizeDisplayName("x".repeat(80), "Host")).toHaveLength(GAMEPLAY.maxDisplayNameLength);
  });

  it("derives match codes deterministically from supplied random bytes", () => {
    const bytes = new Uint8Array([0, 1, 2, 3, 4, 5]);
    expect(matchCodeFromBytes(bytes)).toBe(matchCodeFromBytes(bytes));
    expect(matchCodeFromBytes(bytes)).toHaveLength(GAMEPLAY.matchCodeLength);
    expect(matchCodeFromBytes(bytes)).toMatch(/^[A-HJ-NP-Z2-9]{6}$/);
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
  const waiting = match({ status: "waiting", startedAt: null, endsAt: null });
  const players = [player("host"), player("guest")];

  it("starts a waiting duel for the host and stamps the server-owned window", () => {
    const plan = planStartMatch(waiting, players, "host", T0);

    expect(plan.ok).toBe(true);
    if (!plan.ok) {
      return;
    }

    expect(plan.value.matchPatch).toEqual({
      status: "active",
      startedAt: T0,
      endsAt: T0 + GAMEPLAY.matchDurationMs,
      updatedAt: T0,
    });
    expect(plan.value.playerResetPatch).toEqual({
      lifeState: "alive",
      health: GAMEPLAY.startingHealth,
      ammo: GAMEPLAY.magazineSize,
      lastShotAt: null,
      respawnAt: null,
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
      planStartMatch(waiting, [player("host"), player("guest", { connected: false })], "host", T0),
    ).toEqual({ ok: false, reason: "opponent_missing" });
  });

  it("rejects starting a duel twice", () => {
    expect(planStartMatch(match({ status: "active" }), players, "host", T0)).toEqual({
      ok: false,
      reason: "match_already_started",
    });
    expect(planStartMatch(match({ status: "ended" }), players, "host", T0)).toEqual({
      ok: false,
      reason: "match_already_started",
    });
  });
});
