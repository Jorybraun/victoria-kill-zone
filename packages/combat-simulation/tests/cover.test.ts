import {describe, expect, it} from "vitest";
import {DEFAULT_RULES, type CombatEvent, type CombatRules} from "@vkz/combat-protocol";
import {Fixture, LEFT, rules} from "./fixtures.js";

const terminals = (events: CombatEvent[]) => events.filter(e => e.kind === "projectileTerminal");
const quick = (geometry: CombatRules["geometry"]): CombatRules =>
  rules({geometry, weapon: {...DEFAULT_RULES.weapon, speed: 40, cooldownMs: 50, magazine: 100, rangeMeters: 4}});
const settle = (f: Fixture, ticks = 6): CombatEvent[] => Array.from({length: ticks}, () => f.tick()).flat();

describe("phoneProxy cover gate", () => {
  it("lands a hit on a victim the shooter freshly observed", () => {
    const f = new Fixture(quick("phoneProxy")).ready();
    f.tick([f.fire()]);
    expect(terminals(settle(f)).map(e => e.reason)).toEqual(["bodyHit"]);
    expect(f.player("b").health).toBe(66);
  });
  it("misses a victim the shooter never observed", () => {
    const f = new Fixture(quick("phoneProxy")); f.observed = false; f.ready();
    f.tick([f.fire()]);
    expect(terminals(settle(f)).map(e => e.reason)).toEqual(["missExpired"]);
    expect(f.player("b").health).toBe(100);
  });
  it("misses a victim whose last observation aged past the freshness window", () => {
    const f = new Fixture(quick("phoneProxy")).ready();
    f.observed = false;
    for (let i = 0; i < 21; i++) f.tick();
    expect(f.simulation.checkpoint().bodies.some(h => h.observerId === "a" && h.targetId === "b")).toBe(true);
    f.tick([f.fire()]);
    expect(terminals(settle(f)).map(e => e.reason)).toEqual(["missExpired"]);
    expect(f.player("b").health).toBe(100);
  });
  it("ignores another player's fresh sighting of the victim", () => {
    const f = new Fixture(quick("phoneProxy"), 3); f.blind.add("a"); f.ready();
    expect(f.simulation.checkpoint().bodies.some(h => h.observerId === "c" && h.targetId === "b")).toBe(true);
    expect(f.simulation.checkpoint().bodies.some(h => h.observerId === "a")).toBe(false);
    f.tick([f.fire()]);
    expect(terminals(settle(f)).map(e => e.reason)).toEqual(["missExpired"]);
    expect(f.player("b").health).toBe(100);
  });
  it("gates a shield block behind the shooter's own observation", () => {
    const f = new Fixture(quick("phoneProxy")); f.orientation.b = LEFT; f.observed = false; f.ready();
    const fire = f.fire(); if (fire.command.kind === "fire") fire.command.origin = [0, 0.39, 0];
    f.tick([f.ability("shield", "b"), fire]);
    expect(terminals(settle(f)).map(e => e.reason)).toEqual(["missExpired"]);
    expect(f.player("b").shield.energy).toBe(100);
    expect(f.player("b").health).toBe(100);
  });
  it("lets a freshly observed shield still block", () => {
    const f = new Fixture(quick("phoneProxy")); f.orientation.b = LEFT; f.ready();
    const fire = f.fire(); if (fire.command.kind === "fire") fire.command.origin = [0, 0.39, 0];
    f.tick([f.ability("shield", "b"), fire]);
    expect(terminals(settle(f)).map(e => e.reason)).toEqual(["shieldBlocked"]);
    expect(f.player("b").shield.energy).toBe(66);
  });
  it("does not gate trackedBody hits on the shooter's own sighting", () => {
    const f = new Fixture(quick("trackedBody"), 3); f.blind.add("a"); f.ready();
    f.tick([f.fire()]);
    expect(terminals(settle(f)).map(e => e.reason)).toEqual(["bodyHit"]);
    expect(f.player("b").health).toBe(66);
  });
});
