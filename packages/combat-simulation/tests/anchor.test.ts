import {describe, expect, it} from "vitest";
import {DEFAULT_RULES, type CombatEvent, type CombatRules} from "@vkz/combat-protocol";
import {Fixture, rules, sphere} from "./fixtures.js";

const terminals = (events: CombatEvent[]) => events.filter(e => e.kind === "projectileTerminal");
const results = (events: CombatEvent[]) => events.filter(e => e.kind === "commandResult");
const quick = (geometry: CombatRules["geometry"], speed = 40): CombatRules =>
  rules({geometry, weapon: {...DEFAULT_RULES.weapon, kind: "projectile", speed, cooldownMs: 50, magazine: 100, rangeMeters: 4}});
const settle = (f: Fixture, ticks = 12): CombatEvent[] => Array.from({length: ticks}, () => f.tick()).flat();

describe("tracked body phone anchors", () => {
  it("rejects a first observation placed far from the victim's phone", () => {
    const f = new Fixture(quick("trackedBody")).ready();
    f.body.b = [{id: "fake", kind: "sphere", zone: "torso", center: [0.5, 0, 0], radius: 0.1}];
    const events = f.tick([f.fire()]);
    expect(results(events).find(e => e.playerId === "a" && e.reason === "poseMismatch")?.accepted).toBe(false);
    expect(terminals(settle(f))).toHaveLength(0);
    expect(f.player("b").health).toBe(100);
  });

  it("rejects a hit whose impact is far from the victim's authenticated phone", () => {
    const f = new Fixture(quick("trackedBody", 8)).ready();
    f.tick([f.fire()]);
    for (let i = 0; i < 4; i++) {
      f.phone.b = [3 + 0.7 * (i + 1), 0, 0];
      f.tick();
    }
    expect(terminals(settle(f)).map(e => e.reason)).toEqual(["missExpired"]);
    expect(f.player("b").health).toBe(100);
  });
});
