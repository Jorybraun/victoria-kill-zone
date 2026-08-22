import { describe, expect, it } from "vitest";
import {
  ARENA_RADIUS_MAX_METERS,
  ARENA_RADIUS_MIN_METERS,
  COUNTDOWN_MS,
  INITIAL_AMMO,
  INITIAL_HEALTH,
  MATCH_CODE_LENGTH,
  MATCH_DURATION_MS,
} from "../domain/contract.js";
import {
  isValidMatchCode,
  matchCodeFromBytes,
  normalizeArenaRadius,
  normalizeDisplayName,
  normalizeMatchCode,
  planCreateMatch,
  planJoinMatch,
  planSetReady,
  planStartMatch,
  type LobbyPlayer,
} from "../domain/match.js";

const T0 = 1_760_000_000_000;

const host: LobbyPlayer = { id: "p1", role: "host", ready: true, connected: true };
const guest: LobbyPlayer = { id: "p2", role: "guest", ready: true, connected: true };

function create(displayName = "Vic", radius = 30) {
  return planCreateMatch({ displayName, arenaRadiusMeters: radius, code: "ABC123", now: T0 });
}

describe("normalization", () => {
  it("trims and collapses a callsign", () => {
    expect(normalizeDisplayName("  Vic   Braun  ")).toBe("Vic Braun");
  });

  it("uppercases a code and drops separators", () => {
    expect(normalizeMatchCode("abc-123")).toBe("ABC123");
    expect(isValidMatchCode("abc123")).toBe(true);
    expect(isValidMatchCode("abc12")).toBe(false);
  });

  it("clamps the arena radius", () => {
    expect(normalizeArenaRadius(5)).toBe(ARENA_RADIUS_MIN_METERS);
    expect(normalizeArenaRadius(500)).toBe(ARENA_RADIUS_MAX_METERS);
    expect(normalizeArenaRadius(Number.NaN)).toBe(ARENA_RADIUS_MIN_METERS);
  });

  it("derives a fixed-length code from random bytes deterministically", () => {
    const bytes = Uint8Array.from([0, 1, 2, 3, 4, 5]);

    expect(matchCodeFromBytes(bytes)).toHaveLength(MATCH_CODE_LENGTH);
    expect(matchCodeFromBytes(bytes)).toBe(matchCodeFromBytes(bytes));
    expect(isValidMatchCode(matchCodeFromBytes(bytes))).toBe(true);
  });
});

describe("planCreateMatch", () => {
  it("opens a lobby with server-owned health, ammo, and duration", () => {
    const plan = create();

    expect(plan.ok).toBe(true);
    if (!plan.ok) return;
    expect(plan.value.match).toMatchObject({
      code: "ABC123",
      phase: "lobby",
      durationMs: MATCH_DURATION_MS,
      arenaRadiusMeters: 30,
    });
    expect(plan.value.host).toMatchObject({
      role: "host",
      ready: false,
      connected: true,
      health: INITIAL_HEALTH,
      ammo: INITIAL_AMMO,
    });
  });

  it("rejects an empty callsign", () => {
    const plan = create("   ");

    expect(plan).toEqual({ ok: false, code: "INVALID_DISPLAY_NAME" });
  });
});

describe("planJoinMatch", () => {
  it("adds the guest to a lobby holding one player", () => {
    const plan = planJoinMatch({ displayName: "Jory", phase: "lobby", players: [host], now: T0 });

    expect(plan.ok).toBe(true);
    if (!plan.ok) return;
    expect(plan.value.guest).toMatchObject({ role: "guest", ready: false, health: INITIAL_HEALTH });
    expect(plan.value.message).toBe("Jory JOINED");
  });

  it("rejects a third player", () => {
    const plan = planJoinMatch({
      displayName: "Third",
      phase: "lobby",
      players: [host, guest],
      now: T0,
    });

    expect(plan).toEqual({ ok: false, code: "MATCH_FULL" });
  });

  it("rejects joining after the duel leaves the lobby", () => {
    for (const phase of ["countdown", "running", "finished", "cancelled"] as const) {
      expect(planJoinMatch({ displayName: "Late", phase, players: [host], now: T0 })).toEqual({
        ok: false,
        code: "MATCH_ALREADY_STARTED",
      });
    }
  });
});

describe("planSetReady", () => {
  it("records readiness in the lobby", () => {
    expect(planSetReady({ phase: "lobby", displayName: "Vic", isReady: true })).toEqual({
      ok: true,
      value: { ready: true, message: "Vic IS READY" },
    });
    expect(planSetReady({ phase: "lobby", displayName: "Vic", isReady: false })).toEqual({
      ok: true,
      value: { ready: false, message: "Vic IS NOT READY" },
    });
  });

  it("rejects readiness changes once the duel has left the lobby", () => {
    expect(planSetReady({ phase: "running", displayName: "Vic", isReady: true })).toEqual({
      ok: false,
      code: "MATCH_ALREADY_STARTED",
    });
  });
});

describe("planStartMatch", () => {
  function start(overrides: Partial<Parameters<typeof planStartMatch>[0]> = {}) {
    return planStartMatch({
      phase: "lobby",
      actorRole: "host",
      players: [host, guest],
      durationMs: MATCH_DURATION_MS,
      now: T0,
      ...overrides,
    });
  }

  it("starts a server-timed countdown", () => {
    const plan = start();

    expect(plan).toEqual({
      ok: true,
      value: {
        phase: "countdown",
        startsAt: T0 + COUNTDOWN_MS,
        endsAt: T0 + COUNTDOWN_MS + MATCH_DURATION_MS,
        message: "DUEL STARTED",
      },
    });
  });

  it("is host only", () => {
    expect(start({ actorRole: "guest" })).toEqual({ ok: false, code: "HOST_ONLY" });
  });

  it("requires two players", () => {
    expect(start({ players: [host] })).toEqual({ ok: false, code: "PLAYERS_NOT_READY" });
  });

  it("requires both players to be ready", () => {
    expect(start({ players: [host, { ...guest, ready: false }] })).toEqual({
      ok: false,
      code: "PLAYERS_NOT_READY",
    });
  });

  it("requires both players to be connected", () => {
    expect(start({ players: [host, { ...guest, connected: false }] })).toEqual({
      ok: false,
      code: "PLAYERS_NOT_CONNECTED",
    });
  });

  it("rejects a second start", () => {
    for (const phase of ["countdown", "running", "finished", "cancelled"] as const) {
      expect(start({ phase })).toEqual({ ok: false, code: "MATCH_ALREADY_STARTED" });
    }
  });
});
