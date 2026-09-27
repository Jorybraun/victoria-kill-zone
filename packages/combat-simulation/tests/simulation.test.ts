import {describe, expect, it} from "vitest";
import {DEFAULT_RULES, type CombatEvent, type ProjectileState} from "@vkz/combat-protocol";
import {CombatSimulation, parseCheckpoint} from "../src/index.js";
import {Fixture, LEFT, rules, sphere} from "./fixtures.js";

const terminals = (events: CombatEvent[]) => events.filter(e => e.kind === "projectileTerminal");
const results = (events: CombatEvent[]) => events.filter(e => e.kind === "commandResult");
const reason = (events: CombatEvent[]) => results(events).at(-1)?.reason;

describe("authoritative fixed-step simulation", () => {
  it("host start reaches running with no frameReady command ever sent", () => {
    const f = new Fixture(rules());
    f.tick();
    f.tick([f.envelope("a", {kind: "start"})]);
    const snapshot = f.simulation.snapshot();
    expect(snapshot.phase).toBe("running");
    expect(snapshot.players.every(p => !p.frameReady)).toBe(true);
  });
  it("starts only with host authorization and full connection coverage for 2 players", () => {
    const f = new Fixture(rules());
    expect(reason(f.tick([f.envelope("b", {kind: "start"})]))).toBe("notHost");
    f.simulation.setConnected("b", false);
    expect(reason(f.tick([f.envelope("a", {kind: "start"})]))).toBe("notReady");
    f.simulation.setConnected("b", true);
    f.ready(); expect(f.simulation.snapshot().players).toHaveLength(2);
    expect(() => new Fixture(rules(), 1)).toThrow("configuration");
  });
  it("resolves every sighting fire instantly and spends ammo even for a miss", () => {
    const f = new Fixture().ready();
    f.body.b = [sphere([3, 5, 0])];
    const events = f.tick([f.fire()]);
    expect(terminals(events).map(e => e.reason)).toEqual(["missExpired"]);
    expect(f.player("a").ammo).toBe(7);
    expect(f.simulation.snapshot().projectiles).toHaveLength(0);
  });
  it("enforces fire cadence, input age, pose binding and camera aim", () => {
    const f = new Fixture().ready(); f.tick([f.fire()]);
    expect(reason(f.tick([f.fire()]))).toBe("cooldown");
    const wrong = f.fire(); if (wrong.command.kind === "fire") wrong.command.direction = [0, 1, 0];
    expect(reason(f.tick([wrong]))).toBe("invalidRay");
    const stale = f.fire("a", "late", 0); expect(results(f.tick([stale])).find(r => r.commandId === stale.commandId)?.reason).toBe("tooLate");
    const future = f.fire("a", "future", f.now + 500); expect(results(f.tick([future])).find(r => r.commandId === future.commandId)?.reason).toBe("futureInput");
  });
  it("refuses unknown players, malformed envelopes, stale and missing firing poses", () => {
    const f = new Fixture().ready();
    const outsider = {...f.fire(), playerId: "outsider"};
    expect(results(f.tick([outsider])).find(r => r.commandId === outsider.commandId)?.reason).toBe("unknownPlayer");
    const malformed = {...f.fire(), commandId: ""};
    expect(results(f.tick([malformed])).find(r => r.commandId === malformed.commandId)?.reason).toBe("invalidInput");
    const unknownPose = f.fire(); if (unknownPose.command.kind === "fire") unknownPose.command.poseSequence = 999;
    expect(results(f.tick([unknownPose])).find(r => r.commandId === unknownPose.commandId)?.reason).toBe("poseMismatch");
    for (let tick = 0; tick <= LIMITS_POSE_TICKS; tick += 1) f.tick();
    const stale = f.fire(); if (stale.command.kind === "fire") stale.command.poseSequence = 1;
    expect(results(f.tick([stale])).find(r => r.commandId === stale.commandId)?.reason).toBe("poseStale");
  });
  it("refuses a fire while the shooter's pose reports lost tracking", () => {
    const f = new Fixture().ready();
    const at = f.now + 50;
    const lost = f.envelope("a", {kind: "pose", pose: {sequence: at / 50, capturedAtMs: at,
      position: f.phone.a!, orientation: f.orientation.a!, tracking: "lost"}, observations: []});
    const fire = f.fire("a");
    const events = f.simulation.advance([lost, fire]);
    expect(results(events).find(r => r.commandId === fire.commandId)?.reason).toBe("trackingLost");
  });
  it("reload completes on the shared clock and blocks firing during reload", () => {
    const f = new Fixture(rules({weapon: {...DEFAULT_RULES.weapon, reloadMs: 100, magazine: 2, cooldownMs: 50}})).ready();
    f.tick([f.fire()]); f.tick([f.envelope("a", {kind: "reload"})]);
    expect(reason(f.tick([f.fire()]))).toBe("reloading");
    f.tick(); expect(f.player("a").ammo).toBe(2); expect(f.player("a").reloadEndsAtMs).toBeNull();
  });
  it("refuses fire with an empty magazine as outOfAmmo", () => {
    const f = new Fixture(rules({weapon: {...DEFAULT_RULES.weapon, magazine: 1, cooldownMs: 50}})).ready();
    f.tick([f.fire()]);
    expect(reason(f.tick([f.fire()]))).toBe("outOfAmmo");
  });
  it("awards one death, cancels reload, respawns and enforces protection", () => {
    const f = new Fixture(rules({respawnMs: 100, protectionMs: 100,
      weapon: {...DEFAULT_RULES.weapon, damage: {head: 100, torso: 100, limbs: 100}, cooldownMs: 50}})).ready();
    f.tick([f.fire()]); expect(f.player().health).toBe(0); expect(f.player("a").kills).toBe(1);
    f.tick([f.fire()]); expect(f.player().deaths).toBe(1);
    f.tick(); expect(f.player().health).toBe(100); expect(f.player().protectedUntilMs).toBe(f.now + 100);
    expect(terminals(f.tick([f.fire()]))[0]?.reason).toBe("missExpired");
    f.tick([f.fire()]); expect(f.player().deaths).toBe(2);
  });
  it("refuses the respawned shooter's own fire during protection", () => {
    const f = new Fixture(rules({respawnMs: 50, protectionMs: 200,
      weapon: {...DEFAULT_RULES.weapon, damage: {head: 100, torso: 100, limbs: 100}, cooldownMs: 50}})).ready();
    // a dies: b shoots a, aiming along -X at a's collider supplied in b's own space.
    const kill = f.fire("b"); if (kill.command.kind === "fire") {
      kill.command.observation = {targetPlayerId: "a", capturedAtMs: f.now, associationConfidence: 1,
        uncertaintyMeters: 0.01, colliders: [sphere([6, 0, 0])]};
    }
    f.tick([kill]); expect(f.player("a").health).toBe(0);
    f.tick(); expect(f.player("a").health).toBe(100); // respawned and protected
    expect(reason(f.tick([f.fire("a")]))).toBe("protected");
  });
  it("refuses a dead player's fire as notAlive", () => {
    const f = new Fixture(rules({weapon: {...DEFAULT_RULES.weapon, damage: {head: 100, torso: 100, limbs: 100}, cooldownMs: 50}})).ready();
    const kill = f.fire("b"); if (kill.command.kind === "fire") {
      kill.command.observation = {targetPlayerId: "a", capturedAtMs: f.now, associationConfidence: 1,
        uncertaintyMeters: 0.01, colliders: [sphere([6, 0, 0])]};
    }
    f.tick([kill]); expect(f.player("a").health).toBe(0);
    expect(reason(f.tick([f.fire("a")]))).toBe("notAlive");
  });
  it("pauses when a player disconnects mid-round and resumes when they return", () => {
    const f = new Fixture().ready();
    f.simulation.setConnected("b", false);
    expect(f.simulation.snapshot().phase).toBe("paused");
    f.tick(); expect(f.simulation.snapshot().phase).toBe("paused");
    f.simulation.setConnected("b", true);
    f.tick(); expect(f.simulation.snapshot().phase).toBe("running");
  });
  it("refuses actions while the match is not running", () => {
    const f = new Fixture(rules());
    expect(reason(f.tick([f.fire()]))).toBe("notRunning");
    expect(reason(f.tick([f.envelope("a", {kind: "reload"})]))).toBe("notRunning");
  });
  it("refuses a disconnected member's input as notReady", () => {
    const f = new Fixture(rules());
    f.simulation.setConnected("b", false);
    const pose = f.poseCommands().find(e => e.playerId === "b")!;
    expect(results(f.simulation.advance([pose])).find(r => r.commandId === pose.commandId)?.reason).toBe("notReady");
  });
  it("rejects teleports atomically without poisoning the last accepted phone sample", () => {
    const f = new Fixture().ready(); const before = f.simulation.checkpoint().phones.find(p => p.playerId === "b")!.samples.at(-1)!;
    f.phone.b = [100, 0, 0];
    const events = f.tick(); expect(results(events).some(r => r.playerId === "b" && r.reason === "poseMismatch")).toBe(true);
    expect(f.simulation.checkpoint().phones.find(p => p.playerId === "b")!.samples.at(-1)).toEqual(before);
  });
  it("returns a terminal command result for every accepted and refused control", () => {
    const f = new Fixture().ready(); const controls = [f.envelope("b", {kind: "start"}), f.envelope("a", {kind: "reload"}), f.fire()];
    const events = f.tick(controls);
    for (const control of controls) expect(results(events).filter(r => r.commandId === control.commandId)).toHaveLength(1);
  });
  it("refuses new fire when the projectile ceiling is already seeded", () => {
    const f = new Fixture().ready(); const checkpoint = f.simulation.checkpoint();
    const projectile: ProjectileState = {projectileId: "seed", shotId: "seed", shooterId: "a", spawnedAtMs: f.now, position: [0, 2, 0],
      direction: [1, 0, 0], speed: 8, segmentStartedAtMs: f.now, segmentOrigin: [0, 2, 0], timeScale: 1, radius: 0.01, expiresAtMs: f.now + 4000, distanceTravelled: 0};
    checkpoint.snapshot.projectiles = Array.from({length: 128}, (_, i) => ({...projectile, projectileId: `seed-${i}`, shotId: `seed-${i}`}));
    // Validated checkpoint can be used as a test seed only; public restore correctly cancels it.
    const seeded = CombatSimulation.create({matchId: "x", authorityEpoch: 1, frameEpoch: 1, players: checkpoint.snapshot.players, rules: checkpoint.snapshot.rules});
    Object.assign(seeded, {state: parseCheckpoint(checkpoint)}); f.simulation = seeded;
    expect(reason(f.tick([f.fire()]))).toBe("projectileLimit"); expect(f.player("a").ammo).toBe(8);
  });
  it("finishes on duration and refuses new fire", () => {
    const f = new Fixture(rules({durationMs: 100})).ready(); f.tick([f.fire()]);
    const events = f.tick([f.fire()]); expect(f.simulation.snapshot().phase).toBe("finished");
    expect(results(events).at(-1)?.reason).toBe("notRunning");
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

describe("oriented phone shields", () => {
  it("blocks the front, consumes energy, prohibits simultaneous firing and preserves cooldown", () => {
    const f = new Fixture(); f.orientation.b = LEFT; f.ready();
    f.tick([f.ability("shield")]);
    const illegal = f.fire("b"); if (illegal.command.kind === "fire") illegal.command.direction = [-1, 0, 0];
    expect(reason(f.tick([illegal]))).toBe("shieldActive");
    // A sighting hit on the shielded target is blocked at the shield.
    const hit = f.tick([f.fire()]);
    expect(terminals(hit)[0]?.reason).toBe("shieldBlocked"); expect(f.player().health).toBe(100); expect(f.player().shield.energy).toBe(66);
    f.tick([f.envelope("b", {kind: "shield", active: false, poseSequence: (f.now + 50) / 50})]);
    expect(reason(f.tick([f.ability("shield")]))).toBe("abilityCooldown");
  });
  it("breaks an exhausted shield and allows the next shot to hit", () => {
    const f = new Fixture({...rules(), weapon: {...DEFAULT_RULES.weapon, cooldownMs: 50}, shield: {...DEFAULT_RULES.shield, energy: 34}}); f.orientation.b = LEFT; f.ready();
    f.tick([f.ability("shield")]);
    expect(terminals(f.tick([f.fire()]))[0]?.reason).toBe("shieldBlocked"); expect(f.player().shield.activeUntilMs).toBeNull();
    expect(terminals(f.tick([f.fire()]))[0]?.reason).toBe("bodyHit");
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
    const f = new Fixture().ready(); f.body.b = [sphere([3, 5, 0])]; f.tick([f.fire()]);
    const recovered = CombatSimulation.restore(JSON.parse(JSON.stringify(f.simulation.checkpoint())), {authorityEpoch: 2, frameEpoch: 1});
    expect(recovered.snapshot().matchTimeMs).toBe(f.now); expect(recovered.snapshot().projectiles).toHaveLength(0);
    expect(recovered.snapshot().phase).toBe("paused"); expect(recovered.snapshot().players.every(p => !p.frameReady && !p.connected)).toBe(true);
    expect(recovered.checkpoint().phones).toHaveLength(0);
    expect(recovered.takeRecoveryEvents()).not.toHaveLength(0); expect(recovered.takeRecoveryEvents()).toHaveLength(0);
    recovered.advance([]); expect(recovered.snapshot().matchTimeMs).toBe(f.now + 50); expect(recovered.snapshot().players[1]?.health).toBe(100);
  });
  it("rejects corrupt checkpoints and nonadvancing authority epochs", () => {
    const f = new Fixture().ready(), checkpoint = f.simulation.checkpoint();
    expect(() => CombatSimulation.restore(checkpoint, {authorityEpoch: 1, frameEpoch: 1})).toThrow("epoch");
    checkpoint.snapshot.players[0]!.health = Number.NaN;
    expect(() => CombatSimulation.restore(checkpoint, {authorityEpoch: 2, frameEpoch: 1})).toThrow("checkpoint");
    expect(() => parseCheckpoint({version: 1})).toThrow("checkpoint");
  });
  it("tolerates a legacy checkpoint bodies key without trusting it", () => {
    const f = new Fixture().ready(), checkpoint = f.simulation.checkpoint() as unknown as Record<string, unknown>;
    checkpoint["bodies"] = [{observerId: "a", targetId: "b", samples: []}];
    const parsed = parseCheckpoint(JSON.parse(JSON.stringify(checkpoint)));
    expect(parsed.snapshot.players).toHaveLength(2);
  });
  it("produces identical state and events for permuted delivery within a tick", () => {
    const f = new Fixture(rules(), 4).ready(), other = f.simulation.fork();
    const commands = [...f.poseCommands(), f.fire(), f.ability("shield", "d")];
    const first = f.simulation.advance(commands), second = other.advance([...commands].reverse());
    expect(second).toEqual(first); expect(other.checkpoint()).toEqual(f.simulation.checkpoint());
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
  it("emits wire-safe generated projectile IDs on the spawn event", () => {
    const f = new Fixture().ready();
    const events = f.tick([f.fire()]);
    const spawn = events.find(e => e.kind === "projectileSpawn");
    expect(spawn?.kind === "projectileSpawn" && spawn.projectile.projectileId).toMatch(/^[A-Za-z0-9_:\-]{1,128}$/);
  });
  it("rejects mismatched checkpoint public and private pose data", () => {
    const f = new Fixture().ready(), checkpoint = f.simulation.checkpoint();
    checkpoint.snapshot.phonePoses[0]!.pose.position = [20, 0, 0];
    expect(() => parseCheckpoint(checkpoint)).toThrow("mismatch");
  });
  it("keeps compact durable checkpoints bounded without discarding gameplay state", () => {
    const f = new Fixture(rules(), 4);
    for (const id of f.ids) f.body[id] = Array.from({length: 32}, (_, i) => ({...sphere(f.phone[id]!), id: `collider-${i}`}));
    f.ready(); for (let i = 0; i < 16; i++) f.tick();
    f.tick([f.fire("a", "compact", f.now + 50, false), f.ability("shield", "d")]);
    const full = f.simulation.checkpoint(), compact = f.simulation.checkpoint({includeTracking: false});
    expect(compact.snapshot).toEqual({...full.snapshot, phonePoses: []});
    expect(compact.startedAtMs).toBe(full.startedAtMs); expect(compact.phones).toHaveLength(0);
    const restored = CombatSimulation.restore(JSON.parse(JSON.stringify(compact)), {authorityEpoch: 2, frameEpoch: 1});
    expect(restored.snapshot().players.map(p => [p.health, p.ammo, p.kills, p.shield.cooldownUntilMs, p.slowFieldReadyAtMs]))
      .toEqual(full.snapshot.players.map(p => [p.health, p.ammo, p.kills, p.shield.cooldownUntilMs, p.slowFieldReadyAtMs]));
    expect(restored.snapshot().projectiles).toHaveLength(0);
    expect(terminals(restored.takeRecoveryEvents())).toHaveLength(full.snapshot.projectiles.length);
  });
});

const LIMITS_POSE_TICKS = 3;
