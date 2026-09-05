import {describe, expect, it} from "vitest";
import {DEFAULT_RULES, type CombatEvent, type ProjectileState} from "@vkz/combat-protocol";
import {CombatSimulation, parseCheckpoint} from "../src/index.js";
import {Fixture, LEFT, rules, sphere} from "./fixtures.js";

const terminals = (events: CombatEvent[]) => events.filter(e => e.kind === "projectileTerminal");
const results = (events: CombatEvent[]) => events.filter(e => e.kind === "commandResult");
const fast = (speed = 40) => rules({weapon: {...DEFAULT_RULES.weapon, speed, cooldownMs: 50, magazine: 100}});

describe("authoritative fixed-step simulation", () => {
  it("starts only with host authorization and complete spatial coverage for 2–4 players", () => {
    for (const count of [2, 3, 4]) {
      const f = new Fixture(rules(), count);
      expect(results(f.tick([f.envelope("b", {kind: "start"})])).at(-1)?.reason).toBe("notHost");
      expect(results(f.tick([f.envelope("a", {kind: "start"})])).at(-1)?.reason).toBe("notReady");
      f.ready(); expect(f.simulation.snapshot().players).toHaveLength(count);
    }
    expect(() => new Fixture(rules(), 1)).toThrow("configuration");
  });
  it("spawns finite bullets at admission time and spends ammo even for a miss", () => {
    const f = new Fixture(fast()).ready();
    f.body.b = [sphere([3, 1, 0])]; // move the body gradually to avoid teleport rejection
    f.body.b = [sphere([3, 0.7, 0])]; f.tick();
    f.body.b = [sphere([3, 1, 0])];
    const fire = f.tick([f.fire()]);
    expect(terminals(fire)).toHaveLength(0); expect(f.player("a").ammo).toBe(99);
    expect(f.simulation.snapshot().projectiles[0]?.position).toEqual([0, 0, 0]);
    expect(terminals(f.tick())).toHaveLength(0);
    expect(f.simulation.snapshot().projectiles[0]?.position[0]).toBeCloseTo(2);
  });
  it("detects a moving body crossing a bullet between ticks", () => {
    const f = new Fixture(fast()); f.phone.b = [1, 0.4, 0]; f.body.b = [sphere([1, 0.4, 0])]; f.ready();
    f.tick([f.fire()]); f.body.b = [sphere([1, -0.4, 0])];
    const hit = terminals(f.tick())[0];
    expect(hit?.reason).toBe("bodyHit"); expect(hit?.atMs).toBeGreaterThan(150); expect(hit?.atMs).toBeLessThan(200);
    expect(f.player().health).toBe(66);
  });
  it("lets a player dodge before the projectile arrives", () => {
    const f = new Fixture(fast()); f.phone.b = [1.5, 0, 0]; f.body.b = [sphere([1.5, 0, 0])]; f.ready();
    f.tick([f.fire()]); f.body.b = [sphere([1.5, 0.8, 0])];
    expect(terminals(f.tick())).toHaveLength(0); expect(f.player().health).toBe(100);
  });
  it("resolves hitscan nearest contact immediately, independent of roster name", () => {
    const f = new Fixture(rules({weapon: {...DEFAULT_RULES.weapon, kind: "hitscan", speed: 0}}), 3);
    f.phone.b = [6, 0, 0]; f.body.b = [sphere([6, 0, 0])]; f.phone.c = [3, 0, 0]; f.body.c = [sphere([3, 0, 0])]; f.ready();
    const events = f.tick([f.fire()]);
    expect(terminals(events)[0]?.targetPlayerId).toBe("c"); expect(f.player("c").health).toBe(66); expect(f.player("b").health).toBe(100);
    expect(f.simulation.snapshot().projectiles).toHaveLength(0);
  });
  it("rewinds hitscan geometry but never retroactively flies a finite bullet", () => {
    const f = new Fixture(rules({weapon: {...DEFAULT_RULES.weapon, kind: "hitscan", speed: 0}})).ready();
    const old = f.now;
    f.body.b = [sphere([3, 0.8, 0])];
    expect(terminals(f.tick([f.fire("a", "rewind", old)]))[0]?.reason).toBe("bodyHit");
    const finite = new Fixture(fast()).ready();
    const events = finite.tick([finite.fire("a", "finite", finite.now - 50)]);
    expect(terminals(events)).toHaveLength(0); expect(finite.simulation.snapshot().projectiles[0]?.spawnedAtMs).toBe(finite.now);
  });
  it("enforces fire cadence, input age, pose binding and camera aim", () => {
    const f = new Fixture().ready(); f.tick([f.fire()]);
    expect(results(f.tick([f.fire()])).at(-1)?.reason).toBe("cooldown");
    const wrong = f.fire(); if (wrong.command.kind === "fire") wrong.command.direction = [0, 1, 0];
    expect(results(f.tick([wrong])).at(-1)?.reason).toBe("invalidRay");
    const stale = f.fire("a", "late", 0); expect(results(f.tick([stale])).find(r => r.commandId === stale.commandId)?.reason).toBe("tooLate");
    const future = f.fire("a", "future", f.now + 500); expect(results(f.tick([future])).find(r => r.commandId === future.commandId)?.reason).toBe("futureInput");
  });
  it("reload completes on the shared clock and blocks firing during reload", () => {
    const f = new Fixture(rules({weapon: {...DEFAULT_RULES.weapon, reloadMs: 100, magazine: 2, cooldownMs: 50}})).ready();
    f.tick([f.fire()]); f.tick([f.envelope("a", {kind: "reload"})]);
    expect(results(f.tick([f.fire()])).at(-1)?.reason).toBe("reloading");
    f.tick(); expect(f.player("a").ammo).toBe(2); expect(f.player("a").reloadEndsAtMs).toBeNull();
  });
  it("awards one death, cancels reload, respawns and enforces protection", () => {
    const f = new Fixture(rules({respawnMs: 100, protectionMs: 100, weapon: {...DEFAULT_RULES.weapon, kind: "hitscan", speed: 0,
      damage: {head: 100, torso: 100, limbs: 100}, cooldownMs: 50}})).ready();
    f.tick([f.fire()]); expect(f.player().health).toBe(0); expect(f.player("a").kills).toBe(1);
    f.tick([f.fire()]); expect(f.player().deaths).toBe(1);
    f.tick(); expect(f.player().health).toBe(100); expect(f.player().protectedUntilMs).toBe(f.now + 100);
    expect(terminals(f.tick([f.fire()]))[0]?.reason).toBe("missExpired");
    f.tick([f.fire()]); expect(f.player().deaths).toBe(2);
  });
  it("pauses and cancels active shots when tracked geometry goes stale", () => {
    const f = new Fixture().ready(); f.tick([f.fire()]); f.observed = false;
    f.tick(); f.tick(); const events = f.tick();
    expect(f.simulation.snapshot().phase).toBe("paused"); expect(terminals(events)[0]?.reason).toBe("cancelled");
    expect(f.player().health).toBe(100); expect(f.simulation.snapshot().projectiles).toHaveLength(0);
    f.observed = true; f.tick(); expect(f.simulation.snapshot().phase).toBe("running");
  });
  it("keeps missing body geometry distinct from the explicitly selected phone proxy mode", () => {
    const f = new Fixture(rules({geometry: "phoneProxy"})); f.observed = false; f.ready();
    f.tick([f.fire()]); expect(f.simulation.snapshot().phase).toBe("running");
    const tracked = new Fixture(); tracked.observed = false;
    tracked.tick(tracked.ids.map(id => tracked.envelope(id, {kind: "frameReady", ready: true, residualMeters: 0, residualDegrees: 0, clockUncertaintyMs: 0})));
    expect(results(tracked.tick([tracked.envelope("a", {kind: "start"})])).at(-1)?.reason).toBe("notReady");
  });
  it("rejects teleports atomically without poisoning the last accepted phone sample", () => {
    const f = new Fixture().ready(); const before = f.simulation.checkpoint().phones.find(p => p.playerId === "b")!.samples.at(-1)!;
    f.phone.b = [100, 0, 0];
    const events = f.tick(); expect(results(events).some(r => r.playerId === "b" && r.reason === "poseMismatch")).toBe(true);
    expect(f.simulation.checkpoint().phones.find(p => p.playerId === "b")!.samples.at(-1)).toEqual(before);
  });
  it("accepts repeated identical camera body samples without duplicating history", () => {
    const f = new Fixture().ready(); const batch = f.poseCommands();
    for (const envelope of batch) if (envelope.command.kind === "pose") envelope.command.observations = envelope.command.observations.map(o => ({...o, capturedAtMs: f.now}));
    const oldLength = f.simulation.checkpoint().bodies[0]!.samples.length;
    expect(results(f.simulation.advance(batch)).every(r => r.accepted)).toBe(true);
    expect(f.simulation.checkpoint().bodies[0]!.samples).toHaveLength(oldLength);
  });
  it("returns a terminal command result for every accepted and refused control", () => {
    const f = new Fixture().ready(); const controls = [f.envelope("b", {kind: "start"}), f.envelope("a", {kind: "reload"}), f.fire()];
    const events = f.tick(controls);
    for (const control of controls) expect(results(events).filter(r => r.commandId === control.commandId)).toHaveLength(1);
  });
  it("bounds projectile count and expires flight even inside slow time", () => {
    const f = new Fixture(rules({weapon: {...DEFAULT_RULES.weapon, lifetimeMs: 100}})).ready();
    f.tick([f.fire()]); f.tick();
    expect(terminals(f.tick())[0]?.reason).toBe("missExpired"); expect(f.simulation.snapshot().projectiles).toHaveLength(0);
    const g = new Fixture().ready(); const checkpoint = g.simulation.checkpoint();
    const projectile: ProjectileState = {projectileId: "seed", shotId: "seed", shooterId: "a", spawnedAtMs: g.now, position: [0, 2, 0],
      direction: [1, 0, 0], speed: 8, segmentStartedAtMs: g.now, segmentOrigin: [0, 2, 0], timeScale: 1, radius: 0.01, expiresAtMs: g.now + 4000, distanceTravelled: 0};
    checkpoint.snapshot.projectiles = Array.from({length: 128}, (_, i) => ({...projectile, projectileId: `seed-${i}`, shotId: `seed-${i}`}));
    // Validated checkpoint can be used as a test seed only; public restore correctly cancels it.
    const seeded = CombatSimulation.create({matchId: "x", authorityEpoch: 1, frameEpoch: 1, players: checkpoint.snapshot.players, rules: checkpoint.snapshot.rules});
    Object.assign(seeded, {state: parseCheckpoint(checkpoint)}); g.simulation = seeded;
    expect(results(g.tick([g.fire()])).at(-1)?.reason).toBe("projectileLimit"); expect(g.player("a").ammo).toBe(8);
  });
  it("finishes on duration and refuses new fire", () => {
    const f = new Fixture(rules({durationMs: 100})).ready(); f.tick([f.fire()]);
    const events = f.tick([f.fire()]); expect(f.simulation.snapshot().phase).toBe("finished");
    expect(terminals(events).some(e => e.reason === "cancelled")).toBe(true); expect(results(events).at(-1)?.reason).toBe("notRunning");
  });
  it("anchors round duration at first host start, preserving it through pauses and recovery", () => {
    const f = new Fixture(); f.tick(); f.tick(); expect(f.simulation.snapshot().roundStartedAtMs).toBeNull();
    f.ready(); const start = f.now;
    expect(f.simulation.snapshot().roundStartedAtMs).toBe(start);
    f.tick([f.envelope("a", {kind: "start"})]); expect(f.simulation.snapshot().roundStartedAtMs).toBe(start);
    f.simulation.setConnected("b", false);
    const recovered = CombatSimulation.restore(f.simulation.checkpoint({includeTracking: false}), {authorityEpoch: 2, frameEpoch: 1});
    expect(recovered.snapshot().roundStartedAtMs).toBe(start);
    const corrupt = f.simulation.checkpoint(); corrupt.snapshot.roundStartedAtMs = 0;
    expect(() => parseCheckpoint(corrupt)).toThrow("header");
  });
});

describe("oriented phone shields and local slow fields", () => {
  it("blocks the front, consumes energy, prohibits simultaneous firing and preserves cooldown", () => {
    const f = new Fixture(fast()); f.orientation.b = LEFT; f.ready();
    f.tick([f.ability("shield"), f.fire()]);
    const illegal = f.fire("b"); if (illegal.command.kind === "fire") illegal.command.direction = [-1, 0, 0];
    expect(results(f.tick([illegal])).at(-1)?.reason).toBe("shieldActive");
    const hit = terminals(f.tick())[0]; expect(hit?.reason).toBe("shieldBlocked"); expect(f.player().health).toBe(100); expect(f.player().shield.energy).toBe(66);
    f.tick([f.envelope("b", {kind: "shield", active: false, poseSequence: (f.now + 50) / 50})]);
    expect(results(f.tick([f.ability("shield")])).at(-1)?.reason).toBe("abilityCooldown");
  });
  it("does not shield a phone's back face", () => {
    const f = new Fixture(fast()).ready(); f.tick([f.ability("shield"), f.fire()]); f.tick();
    expect(terminals(f.tick())[0]?.reason).toBe("bodyHit"); expect(f.player().shield.energy).toBe(100);
  });
  it("breaks an exhausted shield and allows the next bullet to hit", () => {
    const f = new Fixture({...fast(), shield: {...DEFAULT_RULES.shield, energy: 34}}); f.orientation.b = LEFT; f.ready();
    f.tick([f.ability("shield"), f.fire()]); f.tick([f.fire()]);
    expect(terminals(f.tick())[0]?.reason).toBe("shieldBlocked"); expect(f.player().shield.activeUntilMs).toBeNull();
    expect(terminals(f.tick())[0]?.reason).toBe("bodyHit");
  });
  it("splits field entry/exit continuously and uses minimum overlapping scale", () => {
    const f = new Fixture({...fast(100), slowField: {...DEFAULT_RULES.slowField, radius: 0.5, scale: 0.25}});
    f.phone.b = [1, 1, 0]; f.body.b = [sphere([1, 1, 0])]; f.ready();
    const checkpoint = f.simulation.checkpoint();
    checkpoint.snapshot.slowFields = [{fieldId: "one", ownerId: "b", center: [1, 0, 0], radius: 0.5, startsAtMs: f.now, endsAtMs: f.now + 2000, scale: 0.25},
      {fieldId: "two", ownerId: "a", center: [1, 0, 0], radius: 0.5, startsAtMs: f.now, endsAtMs: f.now + 2000, scale: 0.5}];
    Object.assign(f.simulation, {state: parseCheckpoint(checkpoint)});
    f.tick([f.fire()]); const events = f.tick();
    // .5m at 100m/s (5ms), 1m at 25m/s (40ms), .5m at 100m/s (5ms).
    expect(f.simulation.snapshot().projectiles[0]?.position[0]).toBeCloseTo(2, 7);
    const segments = events.filter(e => e.kind === "projectileSegment"); expect(segments.map(e => e.timeScale)).toEqual([0.25, 1]);
    expect(segments[0]?.atMs).toBeCloseTo(155); expect(segments[1]?.atMs).toBeCloseTo(195);
  });
  it("field expiration restores velocity at its exact time, and does not slow reload", () => {
    const f = new Fixture({...fast(100), weapon: {...fast(100).weapon, reloadMs: 50}, slowField: {...DEFAULT_RULES.slowField, radius: 2, durationMs: 75, cooldownMs: 100}}).ready();
    f.tick([f.ability("slowField", "a"), f.fire()]);
    // Field starts at 150, expires at 225, projectile travels 1.25m by 200.
    f.tick([f.envelope("a", {kind: "reload"})]);
    expect(f.player("a").reloadEndsAtMs).toBe(250);
    const events = f.tick(); expect(f.player("a").ammo).toBe(100);
    const segment = events.find(e => e.kind === "projectileSegment" && e.timeScale === 1);
    expect(segment?.kind === "projectileSegment" && segment.atMs).toBeCloseTo(225);
  });
});

describe("durable checkpoints and deterministic staging", () => {
  it("fork isolates uncommitted mutations and snapshots cannot mutate the authority", () => {
    const f = new Fixture().ready(), saved = f.simulation.snapshot(), checkpoint = f.simulation.checkpoint(), fork = f.simulation.fork();
    fork.advance([...f.poseCommands(), f.fire()]); expect(f.simulation.snapshot()).toEqual(saved);
    expect(f.simulation.checkpoint()).toEqual(checkpoint);
    saved.players[0]!.health = 0; expect(f.player("a").health).toBe(100);
    expect(parseCheckpoint(JSON.parse(JSON.stringify(f.simulation.checkpoint())))).toEqual(f.simulation.checkpoint());
  });
  it("restores no projectile future or stale pose readiness across downtime", () => {
    const f = new Fixture().ready(); f.tick([f.fire()]);
    const recovered = CombatSimulation.restore(JSON.parse(JSON.stringify(f.simulation.checkpoint())), {authorityEpoch: 2, frameEpoch: 1});
    expect(recovered.snapshot().matchTimeMs).toBe(f.now); expect(recovered.snapshot().projectiles).toHaveLength(0);
    expect(recovered.snapshot().phase).toBe("paused"); expect(recovered.snapshot().players.every(p => !p.frameReady && !p.connected)).toBe(true);
    expect(recovered.checkpoint().phones).toHaveLength(0); expect(recovered.checkpoint().bodies).toHaveLength(0);
    expect(terminals(recovered.takeRecoveryEvents())[0]?.reason).toBe("cancelled"); expect(recovered.takeRecoveryEvents()).toHaveLength(0);
    recovered.advance([]); expect(recovered.snapshot().matchTimeMs).toBe(f.now + 50); expect(recovered.snapshot().players[1]?.health).toBe(100);
  });
  it("rejects corrupt checkpoints and nonadvancing authority epochs", () => {
    const f = new Fixture().ready(), checkpoint = f.simulation.checkpoint();
    expect(() => CombatSimulation.restore(checkpoint, {authorityEpoch: 1, frameEpoch: 1})).toThrow("epoch");
    checkpoint.snapshot.players[0]!.health = Number.NaN;
    expect(() => CombatSimulation.restore(checkpoint, {authorityEpoch: 2, frameEpoch: 1})).toThrow("checkpoint");
    expect(() => parseCheckpoint({version: 1})).toThrow("checkpoint");
  });
  it("produces identical state and events for permuted delivery within a tick", () => {
    const f = new Fixture(fast(), 4).ready(), other = f.simulation.fork();
    const commands = [...f.poseCommands(), f.fire(), f.ability("slowField", "d")];
    const first = f.simulation.advance(commands), second = other.advance([...commands].reverse());
    expect(second).toEqual(first); expect(other.checkpoint()).toEqual(f.simulation.checkpoint());
  });
  it("orders simultaneous flight by impact time, letting later bullets pass an already killed target", () => {
    const f = new Fixture(fast(100), 4);
    f.phone.b = [2, 2, 0]; f.body.b = [sphere([2, 2, 0])];
    f.phone.c = [3, 0, 0]; f.body.c = [sphere([3, 0, 0])];
    f.phone.d = [5, 0, 0]; f.body.d = [sphere([5, 0, 0])]; f.ready();
    const checkpoint = f.simulation.checkpoint(); checkpoint.snapshot.players.find(p => p.playerId === "c")!.health = 34;
    const projectile = (id: string, shooterId: string, x: number): ProjectileState => ({projectileId: id, shotId: id, shooterId,
      spawnedAtMs: f.now, position: [x, 0, 0], direction: [1, 0, 0], speed: 100, segmentStartedAtMs: f.now,
      segmentOrigin: [x, 0, 0], timeScale: 1, radius: 0.015, expiresAtMs: f.now + 1000, distanceTravelled: 0});
    checkpoint.snapshot.projectiles = [projectile("first-array-later-hit", "a", 0), projectile("last-array-earlier-hit", "b", 2)];
    Object.assign(f.simulation, {state: parseCheckpoint(checkpoint)});
    const hits = terminals(f.tick());
    expect(hits.map(h => [h.shooterId, h.targetPlayerId])).toEqual([["b", "c"], ["a", "d"]]);
    expect(f.player("b").kills).toBe(1); expect(f.player("a").kills).toBe(0); expect(f.player("d").health).toBe(66);
  });
  it("publishes only validated latest poses and clears public poses when a member leaves", () => {
    const f = new Fixture().ready();
    expect(f.simulation.snapshot().phonePoses).toHaveLength(2);
    const events = f.tick(); expect(events.filter(e => e.kind === "poseChanged")).toHaveLength(2);
    f.simulation.setConnected("b", false);
    expect(f.simulation.snapshot().phonePoses.map(p => p.playerId)).toEqual(["a"]);
    expect(f.simulation.snapshot().phase).toBe("paused");
    expect(parseCheckpoint(f.simulation.checkpoint()).snapshot.phonePoses).toHaveLength(1);
  });
  it("emits unique wire-safe generated IDs accepted by the native replica", () => {
    const f = new Fixture().ready(); f.tick([f.fire(), f.ability("slowField", "b")]);
    const snapshot = f.simulation.snapshot();
    for (const id of [snapshot.projectiles[0]!.projectileId, snapshot.slowFields[0]!.fieldId]) expect(id).toMatch(/^[A-Za-z0-9_:\-]{1,128}$/);
    expect(snapshot.projectiles[0]!.projectileId).not.toBe(snapshot.slowFields[0]!.fieldId);
  });
  it("rejects mismatched checkpoint public and private pose data", () => {
    const f = new Fixture().ready(), checkpoint = f.simulation.checkpoint();
    checkpoint.snapshot.phonePoses[0]!.pose.position = [20, 0, 0];
    expect(() => parseCheckpoint(checkpoint)).toThrow("mismatch");
  });
  it("keeps compact durable checkpoints bounded without discarding gameplay state", () => {
    const f = new Fixture(fast(), 4);
    for (const id of f.ids) f.body[id] = Array.from({length: 32}, (_, i) => ({...sphere(f.phone[id]!), id: `collider-${i}`}));
    f.ready(); for (let i = 0; i < 16; i++) f.tick();
    f.tick([f.fire(), f.ability("slowField", "d"), f.ability("shield", "c")]);
    const full = f.simulation.checkpoint(), compact = f.simulation.checkpoint({includeTracking: false});
    expect(JSON.stringify(full).length).toBeGreaterThan(500_000);
    expect(JSON.stringify(compact).length).toBeLessThan(16_000);
    expect(compact.snapshot).toEqual({...full.snapshot, phonePoses: []});
    expect(compact.startedAtMs).toBe(full.startedAtMs); expect(compact.phones).toHaveLength(0); expect(compact.bodies).toHaveLength(0);
    const restored = CombatSimulation.restore(JSON.parse(JSON.stringify(compact)), {authorityEpoch: 2, frameEpoch: 1});
    expect(restored.snapshot().players.map(p => [p.health, p.ammo, p.kills, p.shield.cooldownUntilMs, p.slowFieldReadyAtMs]))
      .toEqual(full.snapshot.players.map(p => [p.health, p.ammo, p.kills, p.shield.cooldownUntilMs, p.slowFieldReadyAtMs]));
    expect(restored.snapshot().projectiles).toHaveLength(0);
    expect(terminals(restored.takeRecoveryEvents())).toHaveLength(full.snapshot.projectiles.length);
  });
});
