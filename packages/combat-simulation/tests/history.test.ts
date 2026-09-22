import {describe, expect, it} from "vitest";
import {colliderPairs} from "../src/history.js";
import {Fixture, rules, sphere} from "./fixtures.js";

describe("body collision history", () => {
  it("rejects collider identity changes across an interval", () => {
    const f = new Fixture(rules({geometry: "trackedBody"})).ready();
    const state = f.simulation.checkpoint();
    const now = state.snapshot.matchTimeMs;
    expect(colliderPairs(state, "b", now - 50, now)).not.toBeNull();
    const history = state.bodies.find(h => h.observerId === "a" && h.targetId === "b")!;
    history.samples = [
      {targetPlayerId: "b", capturedAtMs: now - 50, associationConfidence: 1, uncertaintyMeters: 0.01, colliders: [sphere([3, 0, 0])]},
      {targetPlayerId: "b", capturedAtMs: now, associationConfidence: 1, uncertaintyMeters: 0.01, colliders: [{...sphere([3, 0, 0]), id: "head"}]},
    ];
    expect(colliderPairs(state, "b", now - 50, now)).toBeNull();
    expect(colliderPairs(state, "b", now, now)).not.toBeNull();
  });
});
