import {describe, expect, it} from "vitest";
import {type CombatEvent, type ProjectileState} from "@vkz/combat-protocol";
import {resolveFlights, type FlightPath} from "../src/flight.js";
import type {SimulationCheckpoint} from "../src/state.js";
import {Fixture, sphere} from "./fixtures.js";

const path = (id: string, at = 100): FlightPath => {
  const projectile: ProjectileState = {projectileId: id, shotId: id, shooterId: "a", spawnedAtMs: 100,
    position: [4, 0, 0], direction: [1, 0, 0], speed: 80, segmentStartedAtMs: 100,
    segmentOrigin: [0, 0, 0], timeScale: 1, radius: 0.015, expiresAtMs: 1000, distanceTravelled: 4};
  return {projectile, segments: [{fromMs: 100, toMs: 150, start: [0, 0, 0], end: [4, 0, 0], scale: 1,
    geometryFromMs: at, geometryToMs: at}], changes: [], expires: false, endTimeMs: 150};
};
const terminals = (events: CombatEvent[]) => events.filter(event => event.kind === "projectileTerminal");

function measured(checkpoint: SimulationCheckpoint, paths: FlightPath[]) {
  const state = structuredClone(checkpoint), bodies = state.bodies;
  let historyReads = 0;
  Object.defineProperty(state, "bodies", {get: () => {historyReads++; return bodies;}});
  return {result: resolveFlights(state, paths), get historyReads() {return historyReads;}};
}

describe("flight geometry reuse", () => {
  it("resolves a full projectile burst like independent misses while amortizing history selection", () => {
    const f = new Fixture(); f.body.b = [sphere([3, 2, 0])]; f.ready();
    const checkpoint = f.simulation.checkpoint();
    const paths = Array.from({length: 128}, (_, i) => path(`shot-${i}`));
    const together = measured(checkpoint, paths), independent = paths.map(p => measured(checkpoint, [p]));
    expect(together.result.events).toEqual([]);
    expect(together.result.survivors).toEqual(independent.flatMap(item => item.result.survivors));
    expect(together.result.survivors).toHaveLength(128);
    // The negative control requests each shot independently, so no lookup can
    // be shared across shots. Both paths use the actual collision resolver.
    const separateReads = independent.reduce((sum, item) => sum + item.historyReads, 0);
    expect(together.historyReads).toBeGreaterThan(0);
    expect(separateReads).toBe(together.historyReads * 128);
  });

  it("keeps historical geometry distinct from current geometry for the same target", () => {
    const f = new Fixture().ready();
    f.body.b = [sphere([3, 0.8, 0])]; f.tick();
    const result = resolveFlights(f.simulation.checkpoint(), [path("historical", 100), path("current", 150)]);
    expect(terminals(result.events).map(event => [event.projectileId, event.reason, event.targetPlayerId])).toEqual([
      ["historical", "bodyHit", "b"],
    ]);
    expect(result.survivors.map(p => p.projectileId)).toEqual(["current"]);
  });

  it("does not retain geometry when a later resolution sees different body observations", () => {
    const f = new Fixture(); f.body.b = [sphere([3, 2, 0])]; f.ready();
    const state = f.simulation.checkpoint();
    expect(resolveFlights(state, [path("before")]).survivors).toHaveLength(1);
    for (const history of state.bodies) if (history.targetId === "b") {
      for (const sample of history.samples) sample.colliders = [sphere([3, 0, 0])];
    }
    const after = resolveFlights(state, [path("after")]);
    expect(terminals(after.events).map(event => event.reason)).toEqual(["bodyHit"]);
    expect(after.survivors).toEqual([]);
  });

  it("recomputes overflow intervals and preserves distinctive hits beyond the retained budget", () => {
    const f = new Fixture(); f.body.b = [sphere([3, 0.8, 0])]; f.ready();
    f.body.b = [sphere([3, 0, 0])]; f.tick();
    const checkpoint = f.simulation.checkpoint();
    const paths = Array.from({length: 128}, (_, i) => {
      const p = path(`distinct-${i}`, 100 + i * 0.025), first = p.segments[0]!;
      // The first 64 paths fill 128 unique intervals. Two later shots use
      // the same new interval where the target has moved onto their path.
      const secondAt = i === 64 || i === 65 ? 150 : 110 + i * 0.025;
      p.segments = [{...first, fromMs: 150, toMs: 175, end: [2, 0, 0]},
        {...first, fromMs: 175, toMs: 200, start: [2, 0, 0], geometryFromMs: secondAt, geometryToMs: secondAt}];
      p.endTimeMs = 200;
      return p;
    });
    const together = measured(checkpoint, paths);
    expect(terminals(together.result.events).map(event => [event.projectileId, event.reason])).toEqual([
      ["distinct-64", "bodyHit"], ["distinct-65", "bodyHit"],
    ]);
    expect(together.result.survivors).toHaveLength(126);
    // An unbounded cache would reuse the second overflowing hit interval.
    expect(together.historyReads).toBe(256);
  });
});
