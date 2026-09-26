import {describe, expect, it} from "vitest";
import {type BodyObservation, type CombatEvent} from "@vkz/combat-protocol";
import {Fixture, rules, sphere} from "./fixtures.js";

const sighting = () => rules({geometry: "sighting"});
const observation = (f: Fixture, overrides: Partial<BodyObservation> = {}): BodyObservation => ({
  targetPlayerId: "b", capturedAtMs: f.now, associationConfidence: 1, uncertaintyMeters: 0.01,
  colliders: [sphere([3, 0, 0], 0.35)], ...overrides});
const fire = (f: Fixture, obs: BodyObservation | null | undefined, shooter = "a") =>
  f.envelope(shooter, {kind: "fire", shotId: `shot-${f.now}-${shooter}`, poseSequence: (f.now + 50) / 50,
    origin: f.phone[shooter]!, direction: [1, 0, 0], ...(obs === undefined ? {} : {observation: obs})}, f.now + 50);
const terminalReasons = (events: CombatEvent[]) =>
  events.filter(e => e.kind === "projectileTerminal").map(e => e.reason);
const refusal = (events: CombatEvent[]) => {
  const refused = events.find(e => e.kind === "commandResult" && !e.accepted);
  if (refused?.kind === "commandResult") return refused.reason;
  const fire = events.find(e => e.kind === "fireRefused");
  return fire?.kind === "fireRefused" ? fire.reason : undefined;
};

function started(players = 2): Fixture {
  const f = new Fixture(sighting(), players);
  f.tick([f.envelope("a", {kind: "start"})]);
  if (f.simulation.snapshot().phase !== "running") throw new Error("Sighting fixture did not start");
  return f;
}

describe("sighting geometry", () => {
  it("starts with both players connected and frameReady false", () => {
    const f = started();
    expect(f.simulation.snapshot().players.every(p => !p.frameReady)).toBe(true);
    expect(f.simulation.snapshot().phase).toBe("running");
  });
  it("does not pause while running with frameReady false", () => {
    const f = started();
    f.tick(); f.tick();
    expect(f.simulation.snapshot().phase).toBe("running");
  });
  it("pauses when a player disconnects", () => {
    const f = started();
    f.simulation.setConnected("b", false);
    f.tick();
    expect(f.simulation.snapshot().phase).toBe("paused");
  });
  it("resolves a torso collider hit as bodyHit with damage", () => {
    const f = started();
    const events = f.tick([fire(f, observation(f))]);
    expect(terminalReasons(events)).toEqual(["bodyHit"]);
    expect(f.player("b").health).toBe(100 - 34);
    expect(f.player("a").ammo).toBe(7);
  });
  it("misses when no collider intersects the ray", () => {
    const f = started();
    const events = f.tick([fire(f, observation(f, {colliders: [sphere([3, 5, 0], 0.35)]}))]);
    expect(terminalReasons(events)).toEqual(["missExpired"]);
    expect(f.player("b").health).toBe(100);
  });
  it("refuses fire without an observation as noSighting", () => {
    const f = started();
    for (const obs of [undefined, null] as const) {
      const events = f.tick([fire(f, obs)]);
      expect(refusal(events)).toBe("noSighting");
    }
  });
  it("refuses a stale observation as noSighting", () => {
    const f = started();
    const events = f.tick([fire(f, observation(f, {capturedAtMs: f.now - 1500}))]);
    expect(refusal(events)).toBe("noSighting");
  });
  it("refuses a low-confidence observation as noSighting", () => {
    const f = started();
    const events = f.tick([fire(f, observation(f, {associationConfidence: 0.5}))]);
    expect(refusal(events)).toBe("noSighting");
  });
  it("refuses a mismatched targetPlayerId as invalidInput", () => {
    const f = started();
    const events = f.tick([fire(f, observation(f, {targetPlayerId: "a"}))]);
    expect(refusal(events)).toBe("invalidInput");
  });
  it("refuses fire on a 3-player sighting roster as ambiguousTarget", () => {
    const f = started(3);
    const events = f.tick([fire(f, observation(f))]);
    expect(refusal(events)).toBe("ambiguousTarget");
  });
  it("blocks a hit on an active shield", () => {
    const f = started();
    f.tick([f.ability("shield", "b")]);
    const events = f.tick([fire(f, observation(f))]);
    expect(terminalReasons(events)).toEqual(["shieldBlocked"]);
    expect(f.player("b").health).toBe(100);
    expect(f.player("b").shield.energy).toBe(66);
  });
  it("refuses slowField as invalidInput without consuming cooldown", () => {
    const f = started();
    const readyAtMs = f.player("a").slowFieldReadyAtMs;
    const events = f.tick([f.ability("slowField", "a")]);
    expect(refusal(events)).toBe("invalidInput");
    expect(f.simulation.snapshot().slowFields).toHaveLength(0);
    expect(f.player("a").slowFieldReadyAtMs).toBe(readyAtMs);
    const shielded = f.tick([f.ability("shield", "a")]);
    expect(refusal(shielded)).toBeUndefined();
    expect(f.player("a").shield.activeUntilMs).not.toBeNull();
  });
  it("keeps no live projectiles after a sighting fire", () => {
    const f = started();
    f.tick([fire(f, observation(f))]);
    f.tick();
    expect(f.simulation.snapshot().projectiles).toHaveLength(0);
  });
});

describe("non-sighting geometries unchanged", () => {
  it("accepts a phoneProxy fire without the observation key", () => {
    const f = new Fixture(rules({geometry: "phoneProxy"})).ready();
    const events = f.tick([f.fire("a")]);
    expect(refusal(events)).toBeUndefined();
    expect(events.some(e => e.kind === "projectileSpawn")).toBe(true);
  });
});
