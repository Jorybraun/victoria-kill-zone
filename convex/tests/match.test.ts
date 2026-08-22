import { describe, expect, it } from "vitest";
import {
  ARENA_RADIUS_DEFAULT_METERS,
  ARENA_RADIUS_MAX_METERS,
  ARENA_RADIUS_MIN_METERS,
  COUNTDOWN_MS,
  DISPLAY_NAME_MAX_SCALARS,
  INITIAL_AMMO,
  INITIAL_HEALTH,
  MATCH_CODE_LENGTH,
  MATCH_DURATION_MS,
  PRESENCE_TIMEOUT_MS,
} from "../domain/contract.js";
import {
  displayNameLength,
  isValidDisplayName,
  isFiniteArenaRadius,
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

const host: LobbyPlayer = { id: "p1", role: "host", ready: true, connected: true, lastSeenAt: T0 };
const guest: LobbyPlayer = { id: "p2", role: "guest", ready: true, connected: true, lastSeenAt: T0 };

function create(displayName = "Vic", radius = 30) {
  return planCreateMatch({ displayName, arenaRadiusMeters: radius, code: "ABC123", now: T0 });
}

describe("display names", () => {
  it("trims only the surrounding whitespace and preserves everything inside", () => {
    expect(normalizeDisplayName("  Vic   Braun  ")).toBe("Vic   Braun");
    expect(normalizeDisplayName("\u00a0 Vic\u2003Braun \u2028")).toBe("Vic\u2003Braun");
  });

  it("counts Unicode scalars, not UTF-16 code units", () => {
    // Twenty scalars that occupy forty code units: a truncating implementation
    // would both accept this name and cut it in half through a surrogate pair.
    const twentyEmoji = "\u{1f5fd}".repeat(DISPLAY_NAME_MAX_SCALARS);

    expect(twentyEmoji.length).toBe(DISPLAY_NAME_MAX_SCALARS * 2);
    expect(displayNameLength(twentyEmoji)).toBe(DISPLAY_NAME_MAX_SCALARS);
    expect(isValidDisplayName(twentyEmoji)).toBe(true);
    expect(isValidDisplayName(`\u{1f5fd}${twentyEmoji}`)).toBe(false);
  });

  it("accepts one through twenty scalars and rejects anything else", () => {
    expect(isValidDisplayName("V")).toBe(true);
    expect(isValidDisplayName("V".repeat(DISPLAY_NAME_MAX_SCALARS))).toBe(true);
    expect(isValidDisplayName("V".repeat(DISPLAY_NAME_MAX_SCALARS + 1))).toBe(false);
    expect(isValidDisplayName("")).toBe(false);
    expect(isValidDisplayName("   ")).toBe(false);
  });
});

describe("duel codes", () => {
  it("uppercases and drops only typed separators, without truncating", () => {
    expect(normalizeMatchCode("abc-123")).toBe("ABC123");
    expect(normalizeMatchCode(" ab c-12 3 ")).toBe("ABC123");
    expect(normalizeMatchCode("abc1237")).toBe("ABC1237");
    expect(isValidMatchCode("abc123")).toBe(true);
    expect(isValidMatchCode("a-b c-1 2 3")).toBe(true);
  });

  it("rejects wrong lengths and characters that are not separators", () => {
    expect(isValidMatchCode("abc12")).toBe(false);
    expect(isValidMatchCode("abc1237")).toBe(false);
    expect(isValidMatchCode("")).toBe(false);
    // Dropping unknown punctuation would silently resolve a different duel.
    expect(isValidMatchCode("a.b/c*123")).toBe(false);
    expect(isValidMatchCode("ABC12\u00e9")).toBe(false);
  });

  it("rejects a scalar that Unicode uppercasing would launder into ASCII", () => {
    // ſ uppercases to S, ı to I, and ß to SS: folding first would let a
    // forbidden scalar become a valid code, or even a valid length.
    expect("ſbc123".toUpperCase()).toBe("SBC123");
    expect("ßab12".toUpperCase()).toBe("SSAB12");
    expect(isValidMatchCode("ſbc123")).toBe(false);
    expect(isValidMatchCode("ıbc123")).toBe(false);
    expect(isValidMatchCode("ßab12")).toBe(false);
  });

  it("accepts the ambiguous glyphs a human may type but never generates them", () => {
    expect(isValidMatchCode("O0I1AB")).toBe(true);
    expect(matchCodeFromBytes(Uint8Array.from([7, 8, 9, 10, 11, 12]))).not.toMatch(/[01IO]/);
  });
});

describe("arena radius", () => {
  it("rounds and clamps to the playable range", () => {
    expect(normalizeArenaRadius(5)).toEqual({ ok: true, value: ARENA_RADIUS_MIN_METERS });
    expect(normalizeArenaRadius(500)).toEqual({ ok: true, value: ARENA_RADIUS_MAX_METERS });
    expect(normalizeArenaRadius(30.4)).toEqual({ ok: true, value: 30 });
    expect(normalizeArenaRadius(30.5)).toEqual({ ok: true, value: 31 });
  });

  it("rejects a non-finite radius instead of defaulting it", () => {
    expect(isFiniteArenaRadius(ARENA_RADIUS_DEFAULT_METERS)).toBe(true);
    for (const meters of [Number.NaN, Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY]) {
      expect(isFiniteArenaRadius(meters)).toBe(false);
      // A defaulted radius would silently invent a geofence the caller never
      // asked for, so the rejection carries the stable code instead.
      expect(normalizeArenaRadius(meters)).toEqual({ ok: false, code: "INVALID_ARENA_RADIUS" });
      expect(create("Vic", meters)).toEqual({ ok: false, code: "INVALID_ARENA_RADIUS" });
    }
  });
});

describe("code generation", () => {
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

  it("keeps the callsign exactly as typed, minus surrounding whitespace", () => {
    const plan = create("  Vic   Braun  ");

    expect(plan.ok).toBe(true);
    if (!plan.ok) return;
    expect(plan.value.host.displayName).toBe("Vic   Braun");
    expect(plan.value.host.lastSeenAt).toBe(T0);
  });

  it("rejects an empty callsign", () => {
    expect(create("   ")).toEqual({ ok: false, code: "INVALID_DISPLAY_NAME" });
  });

  it("rejects an overlong callsign instead of truncating it", () => {
    expect(create("V".repeat(DISPLAY_NAME_MAX_SCALARS + 1))).toEqual({
      ok: false,
      code: "INVALID_DISPLAY_NAME",
    });
  });
});

describe("planJoinMatch", () => {
  it("adds the guest to a lobby holding one player", () => {
    const plan = planJoinMatch({ displayName: "Jory", code: "ABC123", phase: "lobby", players: [host], now: T0 });

    expect(plan.ok).toBe(true);
    if (!plan.ok) return;
    expect(plan.value.guest).toMatchObject({ role: "guest", ready: false, health: INITIAL_HEALTH });
    expect(plan.value.message).toBe("Jory JOINED");
  });

  it("rejects a malformed duel code", () => {
    expect(
      planJoinMatch({ displayName: "Jory", code: "AB", phase: "lobby", players: [host], now: T0 }),
    ).toEqual({ ok: false, code: "INVALID_CODE" });
  });

  it("rejects a third player", () => {
    const plan = planJoinMatch({
      displayName: "Third",
      code: "ABC123",
      phase: "lobby",
      players: [host, guest],
      now: T0,
    });

    expect(plan).toEqual({ ok: false, code: "MATCH_FULL" });
  });

  it("rejects joining after the duel leaves the lobby", () => {
    for (const phase of ["countdown", "running", "finished", "cancelled"] as const) {
      expect(planJoinMatch({ displayName: "Late", code: "ABC123", phase, players: [host], now: T0 })).toEqual({
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
      value: { ready: true, message: "Vic READY" },
    });
    expect(planSetReady({ phase: "lobby", displayName: "Vic", isReady: false })).toEqual({
      ok: true,
      value: { ready: false, message: "Vic NOT READY" },
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
      now: T0,
      ...overrides,
    });
  }

  it("starts a server-timed countdown and leaves the end time to activation", () => {
    expect(start()).toEqual({
      ok: true,
      value: { phase: "countdown", startsAt: T0 + COUNTDOWN_MS },
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

  it("requires presence to be fresh, not merely flagged connected", () => {
    const stale = { ...guest, lastSeenAt: T0 - PRESENCE_TIMEOUT_MS };

    expect(start({ players: [host, stale] })).toEqual({
      ok: false,
      code: "PLAYERS_NOT_CONNECTED",
    });
    expect(start({ players: [host, { ...stale, lastSeenAt: T0 - PRESENCE_TIMEOUT_MS + 1 }] }).ok).toBe(
      true,
    );
  });

  it("rejects a second start", () => {
    for (const phase of ["countdown", "running", "finished", "cancelled"] as const) {
      expect(start({ phase })).toEqual({ ok: false, code: "MATCH_ALREADY_STARTED" });
    }
  });
});
