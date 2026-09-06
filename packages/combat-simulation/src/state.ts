import {LIMITS, type BodyObservation, type CombatRules, type CombatSnapshot, type Member, type PhonePose} from "@vkz/combat-protocol";

export interface SimulationConfiguration {
  matchId: string;
  authorityEpoch: number;
  frameEpoch: number;
  players: readonly Member[];
  rules: CombatRules;
}
export interface PhoneHistory {playerId: string; samples: PhonePose[]}
export interface BodyHistory {observerId: string; targetId: string; samples: BodyObservation[]}
export interface SimulationCheckpoint {
  version: 1;
  snapshot: CombatSnapshot;
  startedAtMs: number | null;
  phones: PhoneHistory[];
  bodies: BodyHistory[];
}
export const clone = <T>(value: T): T => structuredClone(value);
const object = (x: unknown): x is Record<string, unknown> => typeof x === "object" && x !== null && !Array.isArray(x);
const string = (x: unknown): x is string => typeof x === "string" && x.length > 0 && x.length <= 256;
const number = (x: unknown, min = 0, max = Number.MAX_SAFE_INTEGER): x is number => typeof x === "number" && Number.isFinite(x) && x >= min && x <= max;
const integer = (x: unknown, min = 0): x is number => number(x, min) && Number.isSafeInteger(x);
const optionalTime = (x: unknown): boolean => x === null || number(x);
const vector = (x: unknown): boolean => Array.isArray(x) && x.length === 3 && x.every(v => number(v, -100_000, 100_000));
const quaternion = (x: unknown): boolean => Array.isArray(x) && x.length === 4 && x.every(v => number(v, -1.001, 1.001)) && Math.abs(x.reduce((sum: number, v: number) => sum + v * v, 0) - 1) <= 0.020001;
const zone = (x: unknown): boolean => x === "head" || x === "torso" || x === "limbs";
export function validRules(x: unknown): x is CombatRules {
  if (!object(x) || !object(x.weapon) || !object(x.weapon.damage) || !object(x.shield) || !object(x.slowField)) return false;
  const w = x.weapon, damage = x.weapon.damage, s = x.shield, f = x.slowField;
  return number(x.durationMs, 50, 3_600_000) && (x.geometry === "trackedBody" || x.geometry === "phoneProxy")
    && number(x.respawnMs, 50, 60_000) && number(x.protectionMs, 0, 30_000)
    && (w.id === "sidearm" || w.id === "pulse") && (w.kind === "hitscan" || w.kind === "projectile")
    && [damage.head, damage.torso, damage.limbs].every(v => integer(v, 1) && v <= 100)
    && number(w.cooldownMs, 50, 10_000) && integer(w.magazine, 1) && w.magazine <= 100
    && number(w.reloadMs, 50, 60_000) && number(w.speed, w.kind === "hitscan" ? 0 : 0.1, 1000)
    && number(w.projectileRadius, 0, 0.25) && number(w.lifetimeMs, 50, 30_000) && number(w.rangeMeters, 0.1, 100)
    && number(s.radius, 0.05, 2) && number(s.offsetMeters, 0, 0.5) && number(s.durationMs, 50, 30_000)
    && number(s.cooldownMs, s.durationMs as number, 120_000) && number(s.energy, 1, 1000)
    && number(f.radius, 0.1, 10) && number(f.durationMs, 50, 30_000)
    && number(f.cooldownMs, f.durationMs as number, 120_000) && number(f.scale, 0.05, 1);
}
export function validPhone(x: unknown): x is PhonePose {
  return object(x) && integer(x.sequence) && number(x.capturedAtMs) && vector(x.position)
    && quaternion(x.orientation) && ["normal", "limited", "lost"].includes(x.tracking as string);
}
export function validObservation(x: unknown): x is BodyObservation {
  if (!object(x) || !string(x.targetPlayerId) || !number(x.capturedAtMs)
    || !number(x.associationConfidence, 0, 1) || !number(x.uncertaintyMeters, 0, 10)
    || !Array.isArray(x.colliders) || x.colliders.length < 1 || x.colliders.length > 32) return false;
  const ids = new Set<unknown>();
  return x.colliders.every((c: unknown) => {
    if (!object(c) || !string(c.id) || ids.has(c.id) || !zone(c.zone) || !number(c.radius, 0.005, 1)) return false;
    ids.add(c.id);
    return c.kind === "sphere" ? vector(c.center) : c.kind === "capsule" && vector(c.a) && vector(c.b);
  });
}
export function validateConfiguration(x: SimulationConfiguration): void {
  if (!string(x.matchId) || !integer(x.authorityEpoch, 1) || !integer(x.frameEpoch, 1) || !validRules(x.rules)
    || x.players.length < 2 || x.players.length > LIMITS.players
    || new Set(x.players.map(p => p.playerId)).size !== x.players.length
    || x.players.filter(p => p.role === "host").length !== 1
    || !x.players.every(p => string(p.playerId) && p.playerId.length <= 128 && string(p.displayName) && ["host", "player"].includes(p.role))) {
    throw new Error("Invalid simulation configuration");
  }
}

/** Validate persisted JSON before accepting the TypeScript checkpoint type.
 * Recovery is deliberately stricter than a forgiving client snapshot decoder.
 */
export function parseCheckpoint(input: unknown): SimulationCheckpoint {
  if (!object(input) || input.version !== 1 || !object(input.snapshot) || !optionalTime(input.startedAtMs)) throw new Error("Invalid simulation checkpoint");
  const s = input.snapshot;
  if (!string(s.matchId) || !integer(s.authorityEpoch, 1) || !integer(s.frameEpoch, 1) || !integer(s.tick)
    || s.matchTimeMs !== s.tick * LIMITS.tickMs || s.roundStartedAtMs !== input.startedAtMs
    || !["calibrating", "running", "paused", "finished"].includes(s.phase as string)
    || !validRules(s.rules) || !Array.isArray(s.players) || s.players.length < 2 || s.players.length > 4
    || !Array.isArray(s.projectiles) || s.projectiles.length > LIMITS.projectiles
    || !Array.isArray(s.phonePoses) || s.phonePoses.length > 4
    || !Array.isArray(s.slowFields) || s.slowFields.length > 4
    || (input.startedAtMs !== null && (input.startedAtMs as number) > (s.matchTimeMs as number))) throw new Error("Invalid simulation checkpoint header");
  const ids = new Set<string>();
  for (const p of s.players) {
    if (!object(p) || !string(p.playerId) || p.playerId.length > 128 || ids.has(p.playerId) || !string(p.displayName)
      || !["host", "player"].includes(p.role as string) || !integer(p.health) || p.health > 100
      || !integer(p.ammo) || p.ammo > s.rules.weapon.magazine || !integer(p.kills) || !integer(p.deaths)
      || typeof p.connected !== "boolean" || typeof p.frameReady !== "boolean"
      || ![p.lastFireAtMs, p.reloadEndsAtMs, p.respawnAtMs, p.protectedUntilMs].every(optionalTime)
      || !number(p.slowFieldReadyAtMs) || !object(p.shield) || !optionalTime(p.shield.activeUntilMs)
      || !number(p.shield.cooldownUntilMs) || !number(p.shield.energy, 0, s.rules.shield.energy)) throw new Error("Invalid checkpoint player");
    ids.add(p.playerId);
  }
  if (s.players.filter(p => (p as Record<string, unknown>).role === "host").length !== 1) throw new Error("Invalid checkpoint host");
  const publicPoseIds = new Set<string>();
  for (const entry of s.phonePoses) {
    if (!object(entry) || !ids.has(entry.playerId as string) || publicPoseIds.has(entry.playerId as string) || !validPhone(entry.pose)
      || entry.pose.capturedAtMs > (s.matchTimeMs as number)) throw new Error("Invalid checkpoint public pose");
    publicPoseIds.add(entry.playerId as string);
  }
  const projectileIds = new Set<string>();
  for (const p of s.projectiles) {
    if (!object(p) || !string(p.projectileId) || projectileIds.has(p.projectileId) || !string(p.shotId)
      || !ids.has(p.shooterId as string) || !vector(p.position) || !vector(p.direction) || !vector(p.segmentOrigin)
      || !number(p.speed, 0.1, 1000) || !number(p.radius, 0, 0.25) || !number(p.timeScale, 0.05, 1)
      || !number(p.spawnedAtMs) || !number(p.segmentStartedAtMs) || !number(p.expiresAtMs)
      || !number(p.distanceTravelled, 0, s.rules.weapon.rangeMeters + 0.001)
      || p.spawnedAtMs > p.segmentStartedAtMs || p.segmentStartedAtMs > (s.matchTimeMs as number)
      || p.expiresAtMs < p.spawnedAtMs || p.expiresAtMs - p.spawnedAtMs > s.rules.weapon.lifetimeMs
      || Math.abs((p.direction as number[]).reduce((sum, n) => sum + n * n, 0) - 1) > 0.001) throw new Error("Invalid checkpoint projectile");
    projectileIds.add(p.projectileId);
  }
  const fieldIds = new Set<string>();
  for (const f of s.slowFields) {
    if (!object(f) || !string(f.fieldId) || fieldIds.has(f.fieldId) || !ids.has(f.ownerId as string)
      || !vector(f.center) || !number(f.radius, 0.1, 10) || !number(f.scale, 0.05, 1)
      || !number(f.startsAtMs) || !number(f.endsAtMs) || f.endsAtMs <= f.startsAtMs
      || f.endsAtMs - f.startsAtMs > s.rules.slowField.durationMs) throw new Error("Invalid checkpoint field");
    fieldIds.add(f.fieldId);
  }
  if (!Array.isArray(input.phones) || input.phones.length > 4 || !Array.isArray(input.bodies) || input.bodies.length > 12) throw new Error("Invalid checkpoint histories");
  const phoneIds = new Set<string>();
  for (const h of input.phones) {
    if (!object(h) || !ids.has(h.playerId as string) || phoneIds.has(h.playerId as string)
      || !Array.isArray(h.samples) || h.samples.length > 16 || !h.samples.every(validPhone)) throw new Error("Invalid checkpoint phone history");
    for (let i = 0; i < h.samples.length; i++) {
      const pose = h.samples[i] as PhonePose;
      if (pose.capturedAtMs > (s.matchTimeMs as number) || (i > 0 && (pose.capturedAtMs <= (h.samples[i - 1] as PhonePose).capturedAtMs || pose.sequence <= (h.samples[i - 1] as PhonePose).sequence))) throw new Error("Nonmonotonic checkpoint poses");
    }
    phoneIds.add(h.playerId as string);
    const publicPose = s.phonePoses.find(p => (p as Record<string, unknown>).playerId === h.playerId) as Record<string, unknown> | undefined;
    if (!publicPose || JSON.stringify(publicPose.pose) !== JSON.stringify(h.samples.at(-1))) throw new Error("Checkpoint pose history mismatch");
  }
  if (phoneIds.size !== publicPoseIds.size) throw new Error("Checkpoint public pose history mismatch");
  const bodyIds = new Set<string>();
  for (const h of input.bodies) {
    if (!object(h) || !ids.has(h.observerId as string) || !ids.has(h.targetId as string) || h.observerId === h.targetId
      || bodyIds.has(JSON.stringify([h.observerId, h.targetId])) || !Array.isArray(h.samples)
      || h.samples.length > 16 || !h.samples.every(validObservation)) throw new Error("Invalid checkpoint body history");
    for (let i = 0; i < h.samples.length; i++) {
      const body = h.samples[i] as BodyObservation;
      if (body.targetPlayerId !== h.targetId || body.capturedAtMs > (s.matchTimeMs as number)
        || (i > 0 && body.capturedAtMs <= (h.samples[i - 1] as BodyObservation).capturedAtMs)) throw new Error("Nonmonotonic checkpoint bodies");
    }
    bodyIds.add(JSON.stringify([h.observerId, h.targetId]));
  }
  return clone(input as unknown as SimulationCheckpoint);
}
