import {LIMITS, type PhonePose, type Vec3} from "@vkz/combat-protocol";
import {distance, lerp, phoneForward} from "./geometry.js";
import type {SimulationCheckpoint} from "./state.js";

/** Plausibility limits reject teleports; they do not authenticate camera truth. */
const MAX_SPEED = 15;
const POSITION_SLACK = 0.1;
/** A sighting observation stays fresh for one second after its capture. */
export const COVER_OBSERVATION_MS = 1_000;
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
