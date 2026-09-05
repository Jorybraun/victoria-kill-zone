import {LIMITS, type BodyCollider, type BodyObservation, type PhonePose, type Vec3} from "@vkz/combat-protocol";
import {distance, interpolateCollider, lerp, phoneForward} from "./geometry.js";
import type {BodyHistory, SimulationCheckpoint} from "./state.js";

/** Plausibility limits reject teleports; they do not authenticate camera truth. */
const MAX_SPEED = 15;
const POSITION_SLACK = 0.1;
const withinSpeed = (a: Vec3, b: Vec3, dtMs: number): boolean => distance(a, b) <= MAX_SPEED * dtMs / 1000 + POSITION_SLACK;
function pair<T extends {capturedAtMs: number}>(samples: readonly T[], atMs: number): [T, T, number] | null {
  const before = [...samples].reverse().find(p => p.capturedAtMs <= atMs);
  if (!before || atMs - before.capturedAtMs > LIMITS.poseAgeMs) return null;
  const after = samples.find(p => p.capturedAtMs >= atMs) ?? before;
  if (after.capturedAtMs - before.capturedAtMs > LIMITS.poseAgeMs) return null;
  return [before, after, after === before ? 0 : (atMs - before.capturedAtMs) / (after.capturedAtMs - before.capturedAtMs)];
}
export function phoneAt(state: SimulationCheckpoint, playerId: string, atMs: number): {position: Vec3; normal: Vec3} | null {
  const history = state.phones.find(p => p.playerId === playerId);
  const p = history && pair(history.samples, atMs);
  if (!p || p[0].tracking !== "normal" || p[1].tracking !== "normal") return null;
  return {position: lerp(p[0].position, p[1].position, p[2]), normal: lerp(phoneForward(p[0].orientation), phoneForward(p[1].orientation), p[2])};
}
export function phoneMovementValid(previous: PhonePose | undefined, next: PhonePose): boolean {
  if (!previous) return true;
  if (next.sequence <= previous.sequence || next.capturedAtMs <= previous.capturedAtMs) return false;
  const dt = next.capturedAtMs - previous.capturedAtMs;
  if (!withinSpeed(previous.position, next.position, dt)) return false;
  const cosine = Math.min(1, Math.abs(previous.orientation.reduce((n, v, i) => n + v * next.orientation[i]!, 0)));
  return 2 * Math.acos(cosine) <= 8 * Math.PI * dt / 1000 + 0.1;
}
export function bodyMovementValid(previous: BodyObservation | undefined, next: BodyObservation): boolean {
  if (next.colliders.some(c => c.kind === "capsule" && distance(c.a, c.b) > 3)) return false;
  if (!previous) return true;
  const dt = next.capturedAtMs - previous.capturedAtMs;
  if (dt <= 0) return false;
  return next.colliders.every(c => {
    const old = previous.colliders.find(x => x.id === c.id);
    if (!old) return true; // A new track cannot interpolate through the old sample.
    if (c.kind !== old.kind || c.zone !== old.zone || Math.abs(c.radius - old.radius) > 0.05) return false;
    if (c.kind === "sphere" && old.kind === "sphere") return withinSpeed(old.center, c.center, dt);
    return c.kind === "capsule" && old.kind === "capsule" && withinSpeed(old.a, c.a, dt) && withinSpeed(old.b, c.b, dt);
  });
}
export function bodyAt(history: BodyHistory, atMs: number): BodyCollider[] | null {
  const p = pair(history.samples, atMs);
  if (!p) return null;
  const [a, b, u] = p;
  if (a.colliders.length !== b.colliders.length) return null;
  const colliders: BodyCollider[] = [];
  for (const collider of a.colliders) {
    const second = b.colliders.find(c => c.id === collider.id);
    const value = second && interpolateCollider(collider, second, u);
    if (!value) return null;
    colliders.push(value);
  }
  return colliders;
}
export function selectBody(state: SimulationCheckpoint, targetId: string, fromMs: number, toMs: number): BodyHistory | null {
  const now = state.snapshot.matchTimeMs;
  const histories = state.bodies.filter(h => h.targetId === targetId && state.snapshot.players.some(p => p.playerId === h.observerId && p.connected && p.frameReady)
    && phoneAt(state, h.observerId, now) && bodyAt(h, fromMs) && bodyAt(h, toMs));
  histories.sort((a, b) => b.samples.at(-1)!.capturedAtMs - a.samples.at(-1)!.capturedAtMs || a.observerId.localeCompare(b.observerId));
  return histories[0] ?? null;
}
export function colliderPairs(state: SimulationCheckpoint, playerId: string, fromMs: number, toMs: number): [BodyCollider, BodyCollider][] | null {
  if (state.snapshot.rules.geometry === "phoneProxy") {
    const a = phoneAt(state, playerId, fromMs), b = phoneAt(state, playerId, toMs);
    return a && b ? [[{id: "phone-proxy", kind: "sphere", zone: "torso", center: a.position, radius: 0.35},
      {id: "phone-proxy", kind: "sphere", zone: "torso", center: b.position, radius: 0.35}]] : null;
  }
  const h = selectBody(state, playerId, fromMs, toMs);
  if (!h) return null;
  const a = bodyAt(h, fromMs)!, b = bodyAt(h, toMs)!;
  return a.map(c => [c, b.find(x => x.id === c.id)!]);
}
export function sampleBoundaries(state: SimulationCheckpoint, fromMs: number, toMs: number): number[] {
  return [...new Set([...state.phones.flatMap(h => h.samples), ...state.bodies.flatMap(h => h.samples)]
    .map(p => p.capturedAtMs).filter(t => t > fromMs && t < toMs))].sort((a, b) => a - b);
}
