import { env } from "cloudflare:workers";
import { abortAllDurableObjects, runInDurableObject } from "cloudflare:test";
import { afterEach, describe, expect, it } from "vitest";
import { DEFAULT_RULES, LIMITS, type AuthenticatedCommand, type CombatEvent, type CombatRules, type CombatSnapshot, type ProjectileState, type ServerEvent } from "@vkz/combat-protocol";
import { CombatSimulation } from "@vkz/combat-simulation";
import { RoomStore } from "../src/store.js";

afterEach(async () => { await abortAllDurableObjects(); });

function simulation(rules: CombatRules = structuredClone(DEFAULT_RULES), players = 2): CombatSimulation {
  return CombatSimulation.create({matchId: "ledger-fixture", authorityEpoch: 1, frameEpoch: 1, rules,
    players: ["host", "guest", "third", "fourth"].slice(0, players).map((playerId, index) => ({playerId, displayName: playerId, role: index === 0 ? "host" : "player"}))});
}
function wrapped(snapshot: CombatSnapshot, eventSequence: number, event: CombatEvent): ServerEvent {
  return {v: 1, matchId: snapshot.matchId, authorityEpoch: snapshot.authorityEpoch, frameEpoch: snapshot.frameEpoch,
    eventSequence, tick: snapshot.tick, matchTimeMs: snapshot.matchTimeMs, event};
}
function projectile(projectileId: string): ProjectileState {
  return {projectileId, shotId: `shot-${projectileId}`, shooterId: "host", spawnedAtMs: 0, position: [0, 0, 0], direction: [0, 0, -1], speed: 8,
    segmentStartedAtMs: 0, segmentOrigin: [0, 0, 0], timeScale: 1, radius: 0.015, expiresAtMs: 4000, distanceTravelled: 0};
}
function terminal(projectileId: string): CombatEvent {
  return {kind: "projectileTerminal", projectileId, shotId: `shot-${projectileId}`, shooterId: "host", reason: "bodyHit", atMs: 50,
    position: [0, 0, -0.4], targetPlayerId: "guest", zone: "torso", damage: 34};
}
function setup(storage: DurableObjectStorage, current: CombatSimulation): RoomStore {
  const store = new RoomStore(storage); store.initialize();
  store.create(current.snapshot(), current.checkpoint({includeTracking: false}), "ledger-bootstrap", 0);
  return store;
}

describe("full-match SQLite bullet ledger", () => {
  it("retains exact spawn, segment and terminal evidence after the reconnect ring is trimmed", async () => {
    const stub = env.COMBAT_ROOMS.getByName(crypto.randomUUID());
    await runInDurableObject(stub, (_instance, state) => {
      const current = simulation(), store = setup(state.storage, current);
      current.advance([]); const snapshot = current.snapshot();
      const shots = [wrapped(snapshot, 1, {kind: "projectileSpawn", projectile: projectile("p:1:0:1")}),
        wrapped(snapshot, 2, {kind: "projectileSegment", projectileId: "p:1:0:1", atMs: 25, position: [0, 0, -0.2], timeScale: 0.25}),
        wrapped(snapshot, 3, terminal("p:1:0:1"))];
      store.commit(snapshot, current.checkpoint({includeTracking: false}), shots, [], 3, 50);
      const filler = Array.from({length: LIMITS.eventHistory + 7}, (_, index) => wrapped(snapshot, index + 4,
        {kind: "phaseChanged", phase: "calibrating", reason: "ledger-retention-fixture"}));
      const endSequence = filler.at(-1)!.eventSequence;
      store.commit(snapshot, current.checkpoint({includeTracking: false}), filler, [], endSequence, 100);

      expect(store.earliestEvent()).toBeGreaterThan(3);
      expect(store.eventPage(0, endSequence, LIMITS.eventHistory)).toHaveLength(LIMITS.eventHistory);
      const rows = state.storage.sql.exec<{kind: string; payload: string}>("SELECT kind, payload FROM bullet_events WHERE projectile_id = ? ORDER BY sequence", "p:1:0:1").toArray();
      expect(rows.map(row => row.kind)).toEqual(["projectileSpawn", "projectileSegment", "projectileTerminal"]);
      expect(rows.map(row => JSON.parse(row.payload) as unknown)).toEqual(shots);
      expect(state.storage.sql.exec<{spawn_sequence: number; terminal_sequence: number; segments: number}>("SELECT spawn_sequence, terminal_sequence, segments FROM bullets").one())
        .toEqual({spawn_sequence: 1, terminal_sequence: 3, segments: 1});
      expect(state.storage.sql.exec<{shots: number}>("SELECT shots FROM bullet_totals").one().shots).toBe(1);
    });
  });

  it("counts a terminal-only hitscan exactly once without fabricating a spawn", async () => {
    const stub = env.COMBAT_ROOMS.getByName(crypto.randomUUID());
    await runInDurableObject(stub, (_instance, state) => {
      const rules = structuredClone(DEFAULT_RULES); rules.weapon.kind = "hitscan";
      const current = simulation(rules), store = setup(state.storage, current); current.advance([]);
      const snapshot = current.snapshot(), hit = wrapped(snapshot, 1, terminal("hitscan-1"));
      store.commit(snapshot, current.checkpoint({includeTracking: false}), [hit], [], 1, 50);
      expect(state.storage.sql.exec<{spawn_sequence: number | null; terminal_sequence: number; segments: number}>("SELECT spawn_sequence, terminal_sequence, segments FROM bullets").one())
        .toEqual({spawn_sequence: null, terminal_sequence: 1, segments: 0});
      expect(state.storage.sql.exec<{shots: number}>("SELECT shots FROM bullet_totals").one().shots).toBe(1);
      expect(state.storage.sql.exec<{payload: string}>("SELECT payload FROM bullet_events").toArray().map(row => JSON.parse(row.payload) as unknown)).toEqual([hit]);
    });
  });

  it("rolls back the whole checkpoint/event/ledger transaction after a duplicate terminal", async () => {
    const stub = env.COMBAT_ROOMS.getByName(crypto.randomUUID());
    await runInDurableObject(stub, (_instance, state) => {
      const current = simulation(), store = setup(state.storage, current); current.advance([]);
      const snapshot = current.snapshot();
      store.commit(snapshot, current.checkpoint({includeTracking: false}), [wrapped(snapshot, 1, {kind: "projectileSpawn", projectile: projectile("committed")}),
        wrapped(snapshot, 2, terminal("committed"))], [], 2, 50);
      const before = store.load(); current.advance([]);
      const next = current.snapshot(), result = wrapped(next, 5, {kind: "commandResult", commandId: "command-rejected-transaction", clientSequence: 1, playerId: "host", accepted: true, reason: null});
      const command: AuthenticatedCommand = {v: 1, commandId: "command-rejected-transaction", clientSequence: 1, playerId: "host", authorityEpoch: 1, frameEpoch: 1,
        sentAtMs: 50, command: {kind: "fire", shotId: "uncommitted", poseSequence: 1, origin: [0, 0, 0], direction: [0, 0, -1]}};
      expect(() => store.commit(next, current.checkpoint({includeTracking: false}), [wrapped(next, 3, {kind: "projectileSpawn", projectile: projectile("must-rollback")}),
        wrapped(next, 4, terminal("committed")), result], [{command, fingerprint: "fixture-fingerprint", result}], 5, 100)).toThrow("after terminal");

      expect(store.load()).toEqual(before); expect(store.sequence("host")).toBe(0);
      expect(store.findCommand("host", command.commandId, 1)).toBeNull();
      expect(state.storage.sql.exec<{projectile_id: string}>("SELECT projectile_id FROM bullets").toArray()).toEqual([{projectile_id: "committed"}]);
      expect(state.storage.sql.exec<{shots: number}>("SELECT shots FROM bullet_totals").one().shots).toBe(1);
      expect(store.eventPage(0, 5, 10).map(row => row.sequence)).toEqual([1, 2]);
      expect(state.storage.sql.exec<{sequence: number}>("SELECT sequence FROM bullet_events ORDER BY sequence").toArray()).toEqual([{sequence: 1}, {sequence: 2}]);
    });
  });

  it("rejects orphan finite-projectile segments and terminals atomically", async () => {
    const stub = env.COMBAT_ROOMS.getByName(crypto.randomUUID());
    await runInDurableObject(stub, (_instance, state) => {
      const current = simulation(), store = setup(state.storage, current), snapshot = current.snapshot(), before = store.load();
      const segment = wrapped(snapshot, 1, {kind: "projectileSegment", projectileId: "missing", atMs: 0, position: [0, 0, 0], timeScale: 0.25});
      expect(() => store.commit(snapshot, current.checkpoint(), [segment], [], 1, 1)).toThrow("no durable spawn");
      expect(() => store.commit(snapshot, current.checkpoint(), [wrapped(snapshot, 1, terminal("missing"))], [], 1, 1)).toThrow("no durable spawn");
      expect(store.load()).toEqual(before);
      expect(state.storage.sql.exec<{shots: number}>("SELECT shots FROM bullet_totals").one().shots).toBe(0);
    });
  });

  it.each([{players: 2, durationMs: 100, cooldownMs: 50, capacity: 6}, {players: 4, durationMs: 300, cooldownMs: 150, capacity: 12}])("bounds full-match shot accounting from $players players, duration and cadence", async ({players, durationMs, cooldownMs, capacity}) => {
    const stub = env.COMBAT_ROOMS.getByName(crypto.randomUUID());
    await runInDurableObject(stub, (_instance, state) => {
      const rules = structuredClone(DEFAULT_RULES); rules.durationMs = durationMs; rules.weapon.cooldownMs = cooldownMs;
      const current = simulation(rules, players), store = setup(state.storage, current), snapshot = current.snapshot();
      const events = Array.from({length: capacity}, (_, index) => wrapped(snapshot, index + 1, {kind: "projectileSpawn", projectile: projectile(`bounded-${index}`)}));
      store.commit(snapshot, current.checkpoint(), events, [], capacity, 0);
      expect(state.storage.sql.exec<{shots: number}>("SELECT shots FROM bullet_totals").one().shots).toBe(capacity);
      expect(() => store.commit(snapshot, current.checkpoint(), [wrapped(snapshot, capacity + 1,
        {kind: "projectileSpawn", projectile: projectile("over-limit")})], [], capacity + 1, 1)).toThrow("bullet bound");
      expect(store.load()?.event_sequence).toBe(capacity);
      expect(state.storage.sql.exec<{count: number}>("SELECT COUNT(*) AS count FROM bullets").one().count).toBe(capacity);
      expect(state.storage.sql.exec<{shots: number}>("SELECT shots FROM bullet_totals").one().shots).toBe(capacity);
    });
  });

  it("bounds per-projectile segment retention over the configured lifetime", async () => {
    const stub = env.COMBAT_ROOMS.getByName(crypto.randomUUID());
    await runInDurableObject(stub, (_instance, state) => {
      const rules = structuredClone(DEFAULT_RULES); rules.weapon.lifetimeMs = 50;
      const current = simulation(rules), store = setup(state.storage, current), snapshot = current.snapshot();
      const spawn = projectile("segment-bound"); spawn.expiresAtMs = 50;
      store.commit(snapshot, current.checkpoint(), [wrapped(snapshot, 1, {kind: "projectileSpawn", projectile: spawn})], [], 1, 0);
      // Two tick-boundary slots, each allowing the two-player field transitions.
      const segments = Array.from({length: 16}, (_, index) => wrapped(snapshot, index + 2, {kind: "projectileSegment", projectileId: spawn.projectileId,
        atMs: index + 1, position: [0, 0, -(index + 1) / 100], timeScale: index % 2 === 0 ? 0.25 : 1}));
      store.commit(snapshot, current.checkpoint(), segments, [], 17, 0);
      expect(() => store.commit(snapshot, current.checkpoint(), [wrapped(snapshot, 18, {kind: "projectileSegment", projectileId: spawn.projectileId,
        atMs: 20, position: [0, 0, -0.2], timeScale: 0.25})], [], 18, 1)).toThrow("segment bound");
      expect(state.storage.sql.exec<{segments: number}>("SELECT segments FROM bullets").one().segments).toBe(16);
      expect(store.load()?.event_sequence).toBe(17);
    });
  });

  it("retains legal alternating kills when respawn resets a longer weapon cooldown", async () => {
    const stub = env.COMBAT_ROOMS.getByName(crypto.randomUUID());
    await runInDurableObject(stub, (_instance, state) => {
      const rules = structuredClone(DEFAULT_RULES); rules.geometry = "phoneProxy"; rules.durationMs = 1000;
      rules.respawnMs = 100; rules.protectionMs = 0; rules.weapon.kind = "hitscan"; rules.weapon.cooldownMs = 5000;
      rules.weapon.damage = {head: 100, torso: 100, limbs: 100};
      const current = simulation(rules), store = setup(state.storage, current);
      current.setConnected("host", true); current.setConnected("guest", true);
      let sequence = 0, eventSequence = 0;
      const input = (playerId: string, command: AuthenticatedCommand["command"]): AuthenticatedCommand => ({v: 1,
        commandId: `life-${++sequence}`, clientSequence: sequence, playerId, authorityEpoch: 1, frameEpoch: 1,
        sentAtMs: current.snapshot().matchTimeMs + 50, command});
      const tick = (controls: AuthenticatedCommand[] = []): void => {
        const at = current.snapshot().matchTimeMs + 50;
        const poses = [input("host", {kind: "pose", observations: [], pose: {sequence: at / 50, capturedAtMs: at,
          position: [0, 0, 0], orientation: [0, 0, 0, 1], tracking: "normal"}}), input("guest", {kind: "pose", observations: [], pose: {sequence: at / 50,
          capturedAtMs: at, position: [0, 0, -1], orientation: [0, 1, 0, 0], tracking: "normal"}})];
        const events = current.advance([...poses, ...controls]), snapshot = current.snapshot();
        store.commit(snapshot, current.checkpoint({includeTracking: false}), events.map(event => wrapped(snapshot, ++eventSequence, event)), [], eventSequence, at);
      };
      tick(["host", "guest"].map(id => input(id, {kind: "frameReady", ready: true, residualMeters: 0, residualDegrees: 0, clockUncertaintyMs: 0})));
      tick([input("host", {kind: "start"})]);
      for (let shot = 0; shot < 6; shot++) {
        if (shot > 0) tick();
        const host = shot % 2 === 0;
        tick([input(host ? "host" : "guest", {kind: "fire", shotId: `respawn-shot-${shot}`, poseSequence: (current.snapshot().matchTimeMs + 50) / 50,
          origin: host ? [0, 0, 0] : [0, 0, -1], direction: host ? [0, 0, -1] : [0, 0, 1]})]);
      }
      // All six were accepted by the real engine; a cooldown-only bound allowed four.
      expect(state.storage.sql.exec<{shots: number}>("SELECT shots FROM bullet_totals").one().shots).toBe(6);
      expect(state.storage.sql.exec<{count: number}>("SELECT COUNT(*) AS count FROM bullets WHERE terminal_sequence IS NOT NULL").one().count).toBe(6);
      expect(current.snapshot().players.map(player => player.deaths)).toEqual([3, 3]);
    });
  });
});
