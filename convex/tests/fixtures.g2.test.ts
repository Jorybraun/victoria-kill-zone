/**
 * @vitest-environment edge-runtime
 *
 * Fixture conformance for the frozen `g2.v1` contract.
 *
 * The fixtures are what iOS and the spectator decode, so the checks here drive
 * the registered Convex functions into each fixture state and compare the stored
 * authority against the fixture payload: the enums the backend may emit, the
 * fields every projection must be able to supply, and the credential material a
 * projection must never carry.
 */
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ErrorCode, EventType, MatchPhase, PlayerRole } from "../domain/contract.js";
import { COUNTDOWN_MS, MATCH_DURATION_MS } from "../domain/contract.js";
import { caseIds, fixtureCase, loadG2Fixtures, type FixtureCase } from "./fixtures.js";
import { api, testBackend } from "./harness.js";

const fixtures = loadG2Fixtures();

type Backend = ReturnType<typeof testBackend>;

/** Exhaustive by construction: a new union case fails to compile until listed. */
function unionCases<T extends string>(members: Record<T, true>): string[] {
  return Object.keys(members).sort();
}

function auth(session: { matchId: string; playerId: string; sessionSecret: string }) {
  return {
    matchId: session.matchId,
    playerId: session.playerId,
    sessionSecret: session.sessionSecret,
  };
}

function payloadRecord(fixture: FixtureCase, key: string): Record<string, unknown> {
  const value = fixture.payload[key];
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`fixture ${fixture.id} has no ${key} object`);
  }

  return value as Record<string, unknown>;
}

function payloadList(fixture: FixtureCase, key: string): Record<string, unknown>[] {
  const value = fixture.payload[key];
  if (!Array.isArray(value)) {
    throw new Error(`fixture ${fixture.id} has no ${key} array`);
  }

  return value as Record<string, unknown>[];
}

interface Observed {
  readonly match: Record<string, unknown>;
  readonly players: Record<string, unknown>[];
  readonly eventTypes: string[];
  readonly eventMessages: string[];
  readonly eventKeys: string[];
}

async function observe(t: Backend, matchId: string): Promise<Observed> {
  return await t.run(async (ctx) => {
    const id = ctx.db.normalizeId("matches", matchId);
    if (id === null) {
      throw new Error("match not found");
    }

    const match = await ctx.db.get(id);
    const players = await ctx.db
      .query("players")
      .withIndex("by_match", (q) => q.eq("matchId", id))
      .collect();
    const events = await ctx.db
      .query("events")
      .withIndex("by_match", (q) => q.eq("matchId", id))
      .collect();

    return {
      match: match as unknown as Record<string, unknown>,
      players: players
        .sort((left, right) => left.joinedAt - right.joinedAt)
        .map((player) => player as unknown as Record<string, unknown>),
      eventTypes: events.map((event) => event.type),
      eventMessages: events.map((event) => event.message),
      eventKeys: [...new Set(events.flatMap((event) => Object.keys(event)))],
    };
  });
}

/**
 * Every fixture field must be answerable from stored authority.
 *
 * Ids and timestamps are synthetic in the fixtures, so identity fields are
 * checked for presence and the rest for exact equality: those are the values a
 * client renders, and a silent drift in health, ammo, or duration would be a
 * gameplay bug rather than a formatting one.
 */
const IDENTITY_FIELDS = new Set(["id", "code", "displayName", "startsAt", "endsAt"]);

function expectMatchesFixtureMatch(
  observed: Record<string, unknown>,
  fixture: Record<string, unknown>,
): void {
  for (const [key, value] of Object.entries(fixture)) {
    if (key === "id") {
      expect(observed._id).toBeDefined();
      continue;
    }

    if (IDENTITY_FIELDS.has(key)) {
      expect(observed[key], key).toBeDefined();
      continue;
    }

    expect(observed[key], key).toEqual(value);
  }

  // The countdown carries no end time: only activation may issue one.
  expect("endsAt" in fixture).toBe(observed.endsAt !== undefined);
}

function expectMatchesFixturePlayers(
  observed: Record<string, unknown>[],
  fixture: Record<string, unknown>[],
): void {
  expect(observed).toHaveLength(fixture.length);
  fixture.forEach((expected, index) => {
    const actual = observed[index] ?? {};
    for (const [key, value] of Object.entries(expected)) {
      if (IDENTITY_FIELDS.has(key)) {
        expect(key === "id" ? actual._id : actual[key], key).toBeDefined();
        continue;
      }

      expect(actual[key], `${String(expected.role)}.${key}`).toEqual(value);
    }
  });
}

async function lobbyOnePlayer(t: Backend) {
  return await t.mutation(api.matches.create, { displayName: "HOST", arenaRadiusMeters: 30 });
}

async function lobbyTwoReady(t: Backend) {
  const host = await lobbyOnePlayer(t);
  const guest = await t.mutation(api.matches.join, { displayName: "GUEST", code: host.code });
  await t.mutation(api.matches.setReady, { ...auth(host), isReady: true });
  await t.mutation(api.matches.setReady, { ...auth(guest), isReady: true });
  return { host, guest };
}

describe("g2.v1 enums", () => {
  it("declares exactly the phases, roles, and event types the backend may emit", () => {
    expect(fixtures.enums.matchPhase).toEqual([
      "lobby",
      "countdown",
      "running",
      "finished",
      "cancelled",
    ]);
    expect([...(fixtures.enums.matchPhase ?? [])].sort()).toEqual(
      unionCases<MatchPhase>({
        lobby: true,
        countdown: true,
        running: true,
        finished: true,
        cancelled: true,
      }),
    );
    expect([...(fixtures.enums.playerRole ?? [])].sort()).toEqual(
      unionCases<PlayerRole>({ host: true, guest: true }),
    );
    expect([...(fixtures.enums.eventType ?? [])].sort()).toEqual(
      unionCases<EventType>({ joined: true, ready: true, started: true, hit: true }),
    );
  });

  it("declares exactly the stable error codes the backend may throw", () => {
    expect([...(fixtures.enums.errorCode ?? [])].sort()).toEqual(
      unionCases<ErrorCode>({
        INVALID_DISPLAY_NAME: true,
        INVALID_CODE: true,
        INVALID_ARENA_RADIUS: true,
        MATCH_NOT_FOUND: true,
        MATCH_FULL: true,
        MATCH_ALREADY_STARTED: true,
        INVALID_SESSION: true,
        PLAYERS_NOT_READY: true,
        PLAYERS_NOT_CONNECTED: true,
        HOST_ONLY: true,
        MATCH_NOT_RUNNING: true,
        CONNECTION_STALE: true,
      }),
    );
  });

  it("throws g2.error.invalid-arena-radius exactly as the fixture declares it", async () => {
    const t = testBackend();
    const fixture = fixtureCase(fixtures.errors, "g2.error.invalid-arena-radius");

    await expect(
      t.mutation(api.matches.create, { displayName: "HOST", arenaRadiusMeters: Number.NaN }),
    ).rejects.toMatchObject({ data: fixture.payload });

    expect(await t.run((ctx) => ctx.db.query("matches").collect())).toEqual([]);
  });

  it("declares every error as a bare stable code, with no raw message", () => {
    const declared = new Set(fixtures.enums.errorCode ?? []);
    const errors = caseIds(fixtures.errors, "error:ConvexError");

    expect(errors.length).toBe(declared.size);
    for (const id of errors) {
      const payload = fixtureCase(fixtures.errors, id).payload;
      expect(Object.keys(payload)).toEqual(["code"]);
      expect(declared).toContain(payload.code);
    }
  });
});

describe("g2.v1 lobby states", () => {
  it("matches g2.snapshot.lobby-one-player", async () => {
    const t = testBackend();
    const host = await lobbyOnePlayer(t);
    const fixture = fixtureCase(fixtures.snapshots, "g2.snapshot.lobby-one-player");
    const observed = await observe(t, host.matchId);

    expectMatchesFixtureMatch(observed.match, payloadRecord(fixture, "match"));
    expectMatchesFixturePlayers(observed.players, payloadList(fixture, "players"));
    expect(observed.eventTypes).toEqual(["joined"]);
  });

  it("matches g2.snapshot.lobby-two-ready", async () => {
    const t = testBackend();
    const { host } = await lobbyTwoReady(t);
    const fixture = fixtureCase(fixtures.snapshots, "g2.snapshot.lobby-two-ready");
    const observed = await observe(t, host.matchId);

    expectMatchesFixtureMatch(observed.match, payloadRecord(fixture, "match"));
    expectMatchesFixturePlayers(observed.players, payloadList(fixture, "players"));
    expect(observed.eventTypes).toEqual(["joined", "joined", "ready", "ready"]);
    // The fixtures render event copy from the display name, so the exact strings
    // a client shows are part of the contract.
    expect(observed.eventMessages.sort()).toEqual(
      payloadList(fixture, "events")
        .map((event) => String(event.message))
        .sort(),
    );
  });

  it("stores every event field the fixtures project, and nothing extra", async () => {
    const t = testBackend();
    const { host } = await lobbyTwoReady(t);
    const observed = await observe(t, host.matchId);
    const projectable = new Set([
      "_id",
      "_creationTime",
      "matchId",
      "type",
      "message",
      "actorPlayerId",
      "targetPlayerId",
      "zone",
      "damage",
      "createdAt",
    ]);

    for (const key of observed.eventKeys) {
      expect(projectable, key).toContain(key);
    }
  });
});

describe("g2.v1 countdown and running states", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it("matches g2.snapshot.countdown, which carries a start time but no end time", async () => {
    const t = testBackend();
    const { host } = await lobbyTwoReady(t);
    await t.mutation(api.matches.start, auth(host));

    const fixture = fixtureCase(fixtures.snapshots, "g2.snapshot.countdown");
    const observed = await observe(t, host.matchId);

    expectMatchesFixtureMatch(observed.match, payloadRecord(fixture, "match"));
    expectMatchesFixturePlayers(observed.players, payloadList(fixture, "players"));
    expect(observed.match.endsAt).toBeUndefined();
  });

  it("matches g2.snapshot.running once the guarded activation lands", async () => {
    vi.useFakeTimers();
    const t = testBackend();
    const { host } = await lobbyTwoReady(t);
    await t.mutation(api.matches.start, auth(host));

    vi.advanceTimersByTime(COUNTDOWN_MS);
    await t.finishInProgressScheduledFunctions();

    const fixture = fixtureCase(fixtures.snapshots, "g2.snapshot.running");
    const observed = await observe(t, host.matchId);

    expectMatchesFixtureMatch(observed.match, payloadRecord(fixture, "match"));
    expectMatchesFixturePlayers(observed.players, payloadList(fixture, "players"));
    expect(observed.eventTypes.at(-1)).toBe("started");
    expect(observed.eventMessages.at(-1)).toBe(
      payloadList(fixture, "events").find((event) => event.type === "started")?.message,
    );
  });

  it("keeps the fixture's countdown and duration windows", () => {
    const countdownCase = fixtureCase(fixtures.snapshots, "g2.snapshot.countdown");
    const countdown = payloadRecord(countdownCase, "match");
    const running = payloadRecord(fixtureCase(fixtures.snapshots, "g2.snapshot.running"), "match");

    expect(running.durationMs).toBe(MATCH_DURATION_MS);
    expect((running.endsAt as number) - (running.startsAt as number)).toBe(MATCH_DURATION_MS);
    expect(
      (countdown.startsAt as number) - (countdownCase.payload.serverNow as number),
    ).toBeLessThanOrEqual(COUNTDOWN_MS);
  });
});

describe("g2.v1 projection privacy", () => {
  it("declares no credential or device material in any fixture payload", () => {
    const forbidden = ["sessionSecret", "sessionHash", "deviceId", "secret", "hash"];
    const serialized = JSON.stringify([
      ...fixtures.snapshots,
      ...fixtures.mutationResults,
      ...fixtures.errors,
    ]);

    for (const field of forbidden) {
      expect(serialized).not.toContain(field);
    }
  });

  it("keeps the stored session digest out of every fixture-projected field", async () => {
    const t = testBackend();
    const { host } = await lobbyTwoReady(t);
    const fixture = payloadList(
      fixtureCase(fixtures.snapshots, "g2.snapshot.lobby-two-ready"),
      "players",
    );
    const observed = await observe(t, host.matchId);
    const projectedKeys = new Set(Object.keys(fixture[0] ?? {}));

    expect(projectedKeys.has("sessionHash")).toBe(false);
    for (const player of observed.players) {
      expect(typeof player.sessionHash).toBe("string");
      expect(JSON.stringify([...projectedKeys])).not.toContain("session");
      expect(host.sessionSecret).not.toBe(player.sessionHash);
    }
  });
});
