/**
 * @vitest-environment edge-runtime
 *
 * Fixture conformance for the `g2.v1` fire and read models.
 *
 * The lobby/countdown/running fixtures are asserted against stored authority in
 * `fixtures.g2.test.ts`; this file covers the remaining cases through the seams a
 * phone actually calls — `shots:debugFire`, `queries:matchSnapshot`, and
 * `queries:spectatorSnapshot` — so a projection change cannot pass by editing a
 * helper. Synthetic fixture ids and timestamps are compared for presence; every
 * gameplay value is compared exactly.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  COUNTDOWN_MS,
  HEARTBEAT_INTERVAL_MS,
  MATCH_DURATION_MS,
} from "../domain/contract.js";
import type { PlayerSession } from "../domain/contract.js";
import {
  caseIds,
  fixtureCase,
  loadG2Fixtures,
  scenarioSteps,
  type FixtureCase,
} from "./fixtures.js";
import { api, auth, testBackend } from "./harness.js";

const fixtures = loadG2Fixtures();

type Backend = ReturnType<typeof testBackend>;

/** Nested collections are compared entry by entry rather than deeply. */
const NESTED_FIELDS = new Set(["match", "players", "events"]);

/** Ids and wall-clock instants are synthetic in the fixtures. */
const SYNTHETIC_FIELDS = new Set([
  "id",
  "eventId",
  "code",
  "localPlayerId",
  "serverNow",
  "createdAt",
  "startsAt",
  "endsAt",
  "actorPlayerId",
  "targetPlayerId",
]);

function expectMatchesFixture(
  observed: Record<string, unknown>,
  expected: Record<string, unknown>,
  path: string,
): void {
  expect(Object.keys(observed).sort(), `${path} keys`).toEqual(Object.keys(expected).sort());

  for (const [key, value] of Object.entries(expected)) {
    if (SYNTHETIC_FIELDS.has(key) || NESTED_FIELDS.has(key)) {
      expect(observed[key], `${path}.${key}`).toBeDefined();
      continue;
    }

    expect(observed[key], `${path}.${key}`).toEqual(value);
  }
}

function payload(fixture: FixtureCase): Record<string, unknown> {
  return fixture.payload;
}

function record(value: unknown, path: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`${path} is not an object`);
  }

  return value as Record<string, unknown>;
}

function list(value: unknown, path: string): Record<string, unknown>[] {
  if (!Array.isArray(value)) {
    throw new Error(`${path} is not an array`);
  }

  return value.map((entry, index) => record(entry, `${path}[${index}]`));
}

async function runningDuel(t: Backend): Promise<{ host: PlayerSession; guest: PlayerSession }> {
  const host = await t.mutation(api.matches.create, {
    displayName: "HOST",
    arenaRadiusMeters: 30,
  });
  const guest = await t.mutation(api.matches.join, { displayName: "GUEST", code: host.code });
  await t.mutation(api.matches.setReady, { ...auth(host), isReady: true });
  await t.mutation(api.matches.setReady, { ...auth(guest), isReady: true });
  await t.mutation(api.matches.start, auth(host));

  vi.advanceTimersByTime(COUNTDOWN_MS);
  await t.finishInProgressScheduledFunctions();
  vi.advanceTimersByTime(900);

  return { host, guest };
}

/**
 * Play out `durationMs` the way two phones do: heartbeats keep presence truthful
 * while the guarded scheduled jobs run, so a duel that reaches `finished` still
 * shows two connected players the way the fixture does.
 */
async function playFor(
  t: Backend,
  sessions: readonly PlayerSession[],
  durationMs: number,
): Promise<void> {
  for (let elapsed = 0; elapsed < durationMs; elapsed += HEARTBEAT_INTERVAL_MS) {
    vi.advanceTimersByTime(Math.min(HEARTBEAT_INTERVAL_MS, durationMs - elapsed));
    await t.finishInProgressScheduledFunctions();
    for (const session of sessions) {
      await t.mutation(api.players.heartbeat, auth(session));
    }
  }

  await t.finishInProgressScheduledFunctions();
}

beforeEach(() => {
  vi.useFakeTimers();
});

afterEach(() => {
  vi.useRealTimers();
});

describe("g2.v1 debug fire results", () => {
  it("returns g2.debug-fire.accepted for the first press of a running duel", async () => {
    const t = testBackend();
    const { host } = await runningDuel(t);
    const fixture = fixtureCase(fixtures.mutationResults, "g2.debug-fire.accepted");

    const result = await t.mutation(api.shots.debugFire, {
      ...auth(host),
      clientShotId: String(payload(fixture).clientShotId),
    });

    expectMatchesFixture(
      result as unknown as Record<string, unknown>,
      payload(fixture),
      "g2.debug-fire.accepted",
    );
  });

  it("returns g2.debug-fire.rejected before the duel is running, without a ledger row", async () => {
    const t = testBackend();
    const fixture = fixtureCase(fixtures.mutationResults, "g2.debug-fire.rejected");
    const host = await t.mutation(api.matches.create, {
      displayName: "HOST",
      arenaRadiusMeters: 30,
    });
    await t.mutation(api.matches.join, { displayName: "GUEST", code: host.code });

    const result = await t.mutation(api.shots.debugFire, {
      ...auth(host),
      clientShotId: String(payload(fixture).clientShotId),
    });

    // A validly authenticated business rejection is a returned result, not a
    // throw, and reports the untouched authoritative ammunition and health.
    expectMatchesFixture(
      result as unknown as Record<string, unknown>,
      payload(fixture),
      "g2.debug-fire.rejected",
    );
    expect(await t.run((ctx) => ctx.db.query("shots").collect())).toEqual([]);
    expect(
      (await t.run((ctx) => ctx.db.query("events").collect())).map((event) => event.type),
    ).toEqual(["joined", "joined"]);
  });

  it("returns g2.debug-fire.replayed for the same key with no second effect", async () => {
    const t = testBackend();
    const { host } = await runningDuel(t);
    const accepted = fixtureCase(fixtures.mutationResults, "g2.debug-fire.accepted");
    const fixture = fixtureCase(fixtures.mutationResults, "g2.debug-fire.replayed");
    const shot = { ...auth(host), clientShotId: String(payload(accepted).clientShotId) };

    const first = await t.mutation(api.shots.debugFire, shot);
    const before = await t.run(async (ctx) => ({
      shots: (await ctx.db.query("shots").collect()).length,
      events: (await ctx.db.query("events").collect()).length,
      players: (await ctx.db.query("players").collect()).map((player) => [
        player.health,
        player.ammo,
      ]),
    }));

    vi.advanceTimersByTime(400);
    const replay = await t.mutation(api.shots.debugFire, shot);

    expectMatchesFixture(
      replay as unknown as Record<string, unknown>,
      payload(fixture),
      "g2.debug-fire.replayed",
    );
    expect(replay).toEqual({ ...first, replayed: true });
    expect(
      await t.run(async (ctx) => ({
        shots: (await ctx.db.query("shots").collect()).length,
        events: (await ctx.db.query("events").collect()).length,
        players: (await ctx.db.query("players").collect()).map((player) => [
          player.health,
          player.ammo,
        ]),
      })),
    ).toEqual(before);
  });

  it("covers every declared shots:debugFire fixture case", () => {
    expect(caseIds(fixtures.mutationResults, "shots:debugFire").sort()).toEqual([
      "g2.debug-fire.accepted",
      "g2.debug-fire.rejected",
      "g2.debug-fire.replayed",
    ]);
  });
});

describe("g2.v1 projected snapshots", () => {
  it("projects g2.snapshot.after-debug-hit through both registered queries", async () => {
    const t = testBackend();
    const { host, guest } = await runningDuel(t);
    const fixture = fixtureCase(fixtures.snapshots, "g2.snapshot.after-debug-hit");
    await t.mutation(api.shots.debugFire, { ...auth(host), clientShotId: "shot_g2_001" });
    vi.advanceTimersByTime(100);

    const expected = payload(fixture);
    const snapshot = await t.query(api.queries.matchSnapshot, auth(host));

    expectMatchesFixture(
      snapshot as unknown as Record<string, unknown>,
      expected,
      "g2.snapshot.after-debug-hit",
    );
    expect(snapshot.localPlayerId).toBe(host.playerId);
    expectMatchesFixture(
      record(snapshot.match, "match"),
      record(expected.match, "fixture.match"),
      "match",
    );
    list(expected.players, "fixture.players").forEach((player, index) => {
      expectMatchesFixture(
        record(snapshot.players[index], `players[${index}]`),
        player,
        `players[${index}]`,
      );
    });
    list(expected.events, "fixture.events").forEach((event, index) => {
      expectMatchesFixture(
        record(snapshot.events[index], `events[${index}]`),
        event,
        `events[${index}]`,
      );
    });

    // The public projection carries the same duel with no local player.
    const spectator = await t.query(api.queries.spectatorSnapshot, { code: host.code });
    expect(spectator).not.toBeNull();
    expect(spectator?.players.map((player) => player.health)).toEqual(
      list(expected.players, "fixture.players").map((player) => player.health),
    );
    expect(spectator?.events.map((event) => event.message)).toEqual(
      snapshot.events.map((event) => event.message),
    );
    const serialized = JSON.stringify([snapshot, spectator]);
    for (const secret of [host.sessionSecret, guest.sessionSecret, "sessionHash"]) {
      expect(serialized).not.toContain(secret);
    }
  });

  it("projects g2.snapshot.finished once the guarded finish lands", async () => {
    const t = testBackend();
    const { host, guest } = await runningDuel(t);
    const fixture = fixtureCase(fixtures.snapshots, "g2.snapshot.finished");
    await t.mutation(api.shots.debugFire, { ...auth(host), clientShotId: "shot_g2_001" });

    await playFor(t, [host, guest], MATCH_DURATION_MS);

    const expected = payload(fixture);
    const snapshot = await t.query(api.queries.matchSnapshot, auth(host));

    expect(snapshot.match.phase).toBe("finished");
    expectMatchesFixture(
      record(snapshot.match, "match"),
      record(expected.match, "fixture.match"),
      "match",
    );
    list(expected.players, "fixture.players").forEach((player, index) => {
      expectMatchesFixture(
        record(snapshot.players[index], `players[${index}]`),
        player,
        `players[${index}]`,
      );
    });
    // The fixture keeps a trimmed feed; the newest entry is still the hit.
    expectMatchesFixture(
      record(snapshot.events[0], "events[0]"),
      record(list(expected.events, "fixture.events")[0], "fixture.events[0]"),
      "events[0]",
    );
  });
});

describe("g2.v1 reconnect scenario", () => {
  it("reproduces g2.connection.stale-and-restored with id-stable, de-duplicable feeds", async () => {
    const t = testBackend();
    const fixture = fixtureCase(fixtures.connectionScenarios, "g2.connection.stale-and-restored");
    const steps = scenarioSteps(fixture);
    const snapshotIds = steps
      .filter((step) => step.event === "freshSnapshot")
      .map((step) => String(step.snapshotId));

    expect(snapshotIds).toEqual(["g2.snapshot.running", "g2.snapshot.after-debug-hit"]);

    const { host } = await runningDuel(t);
    const running = await t.query(api.queries.matchSnapshot, auth(host));
    expect(running.match.phase).toBe("running");

    // A transport drop is a client concern: the server keeps serving the same
    // authoritative snapshot, and the next fresh read carries the new hit.
    const before = running.events.map((event) => event.id);
    await t.mutation(api.shots.debugFire, { ...auth(host), clientShotId: "shot_g2_001" });
    const after = await t.query(api.queries.matchSnapshot, auth(host));

    expect(after.events.map((event) => event.id).slice(1)).toEqual(before);
    expect(new Set(after.events.map((event) => event.id)).size).toBe(after.events.length);
    // A re-read after reconnect is byte-identical, so a client de-duplicating by
    // id cannot double-count an event it already rendered.
    expect(await t.query(api.queries.matchSnapshot, auth(host))).toEqual(after);
  });
});

describe("g2.v1 enum discipline", () => {
  it("emits no phase or event type outside the frozen g2 enums", async () => {
    const t = testBackend();
    const { host } = await runningDuel(t);
    await t.mutation(api.shots.debugFire, { ...auth(host), clientShotId: "shot_g2_001" });
    vi.advanceTimersByTime(MATCH_DURATION_MS);
    await t.finishInProgressScheduledFunctions();

    const stored = await t.run(async (ctx) => ({
      phases: (await ctx.db.query("matches").collect()).map((match) => match.phase),
      types: (await ctx.db.query("events").collect()).map((event) => event.type),
    }));

    const phases = new Set(fixtures.enums.matchPhase ?? []);
    const types = new Set(fixtures.enums.eventType ?? []);
    for (const phase of stored.phases) {
      expect(phases, phase).toContain(phase);
    }
    for (const type of stored.types) {
      expect(types, type).toContain(type);
    }
    // No Phase 0 enum value may appear before the client decoders ship.
    for (const forbidden of ["shot", "eliminated", "respawned", "out_of_zone", "finished"]) {
      expect(stored.types).not.toContain(forbidden);
    }
  });
});
