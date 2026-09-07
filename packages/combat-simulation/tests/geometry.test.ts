import {describe, expect, it} from "vitest";
import type {BodyCollider, Vec3} from "@vkz/combat-protocol";
import {sweepCollider, sweepShield, unitIntervalRoots} from "../src/geometry.js";

const sphere = (center: Vec3, radius = 0.1): BodyCollider => ({id: "body", kind: "sphere", zone: "torso", center, radius});
const capsule = (a: Vec3, b: Vec3, radius = 0.1): BodyCollider => ({id: "body", kind: "capsule", zone: "torso", a, b, radius});

describe("continuous collision geometry", () => {
  it("finds thin colliders between both sampled bullet positions", () => {
    const target = sphere([5, 0, 0]);
    expect(sweepCollider([0, 0, 0], [10, 0, 0], target, target, 0.01)).toBeCloseTo(0.489, 9);
  });
  it("lets a body dodge out of the path before the bullet arrives", () => {
    expect(sweepCollider([0, 0, 0], [2, 0, 0], sphere([1.5, 0, 0]), sphere([1.5, 0.8, 0]), 0.01)).toBeNull();
  });
  it("detects a body moving into the path although both body endpoints miss", () => {
    expect(sweepCollider([0, 0, 0], [2, 0, 0], sphere([1, 0.4, 0]), sphere([1, -0.4, 0]), 0.01)).toBeCloseTo(0.449, 2);
  });
  it("keeps exact sphere and capsule grazes", () => {
    const ball = sphere([5, 1, 0], 1), body = capsule([5, 1, -1], [5, 1, 1], 1);
    expect(sweepCollider([0, 0, 0], [10, 0, 0], ball, ball, 0)).toBeCloseTo(0.5, 8);
    expect(sweepCollider([0, 0, 0], [10, 0, 0], body, body, 0)).toBeCloseTo(0.5, 8);
  });
  it("sweeps moving and rotating capsule endpoints", () => {
    const a = capsule([1, 0.4, -0.5], [1, 0.4, 0.5]);
    const b = capsule([1, -0.6, -0.5], [1, -0.2, 0.5]);
    const hit = sweepCollider([0, 0, 0], [2, 0, 0], a, b, 0.01);
    expect(hit).not.toBeNull(); expect(hit!).toBeGreaterThan(0.3); expect(hit!).toBeLessThan(0.6);
  });
  it("does not match colliders with different track identities", () => {
    expect(sweepCollider([0, 0, 0], [2, 0, 0], sphere([1, 0, 0]), {...sphere([1, 0, 0]), id: "new"}, 0)).toBeNull();
  });
  it("blocks only front-to-back oriented shield crossings, including a moving phone", () => {
    expect(sweepShield([0, 0, 0], [2, 0, 0], [1, 0, 0], [1.1, 0, 0], [-1, 0, 0], [-1, 0, 0], 0.4, 0.01)).toBeCloseTo(1 / 1.9);
    expect(sweepShield([2, 0, 0], [0, 0, 0], [1, 0, 0], [1, 0, 0], [-1, 0, 0], [-1, 0, 0], 0.4, 0.01)).toBeNull();
    expect(sweepShield([0, 0.42, 0], [2, 0.42, 0], [1, 0, 0], [1, 0, 0], [-1, 0, 0], [-1, 0, 0], 0.4, 0.01)).toBeNull();
  });
  it("isolates repeated quartic roots without relying on a sign change", () => {
    // (t-.25)^2(t-.75)^2
    const roots = unitIntervalRoots([0.03515625, -0.375, 1.375, -2, 1]);
    expect(roots).toHaveLength(2); expect(roots[0]).toBeCloseTo(0.25, 7); expect(roots[1]).toBeCloseTo(0.75, 7);
  });
});
