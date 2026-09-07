export const PROTOCOL_VERSION = 1 as const;
export const LIMITS = Object.freeze({
  players: 4, tickMs: 50, poseAgeMs: 100, rewindMs: 250, clockUncertaintyMs: 25,
  messageBytes: 16_384, serverMessageBytes: 131_072, commandsPerSecond: 60, commandsPerTick: 64,
  commandHistory: 512, eventHistory: 1024, projectiles: 128,
  mapBytes: 8 * 1024 * 1024, ticketLifetimeSeconds: 120,
});
export type Vec3 = readonly [number, number, number];
/** Quaternion in x,y,z,w order. */
export type Quaternion = readonly [number, number, number, number];
export type HitZone = "head" | "torso" | "limbs";
export type TrackingQuality = "normal" | "limited" | "lost";
export interface PhonePose {
  sequence: number;
  capturedAtMs: number;
  position: Vec3;
  orientation: Quaternion;
  tracking: TrackingQuality;
}
export interface PlayerPhonePose {playerId: string; pose: PhonePose}
export type BodyCollider =
  | {id: string; kind: "sphere"; zone: HitZone; center: Vec3; radius: number}
  | {id: string; kind: "capsule"; zone: HitZone; a: Vec3; b: Vec3; radius: number};
export interface BodyObservation {
  targetPlayerId: string;
  capturedAtMs: number;
  associationConfidence: number;
  uncertaintyMeters: number;
  colliders: readonly BodyCollider[];
}
export interface Member {playerId: string; displayName: string; role: "host" | "player"}
export interface WeaponRules {
  id: "sidearm" | "pulse";
  kind: "hitscan" | "projectile";
  damage: Readonly<Record<HitZone, number>>;
  cooldownMs: number;
  magazine: number;
  reloadMs: number;
  speed: number;
  projectileRadius: number;
  lifetimeMs: number;
  rangeMeters: number;
}
export interface CombatRules {
  durationMs: number;
  geometry: "trackedBody" | "phoneProxy";
  respawnMs: number;
  protectionMs: number;
  weapon: WeaponRules;
  shield: {radius: number; offsetMeters: number; durationMs: number; cooldownMs: number; energy: number};
  slowField: {radius: number; durationMs: number; cooldownMs: number; scale: number};
}
export const DEFAULT_RULES: CombatRules = {
  durationMs: 180_000, geometry: "trackedBody", respawnMs: 5000, protectionMs: 2000,
  weapon: {id: "pulse", kind: "projectile", damage: {head:75,torso:34,limbs:20},
    cooldownMs:150,magazine:8,reloadMs:1250,speed:8,projectileRadius:0.015,lifetimeMs:4000,rangeMeters:25},
  shield:{radius:0.40,offsetMeters:0.15,durationMs:2000,cooldownMs:8000,energy:100},
  slowField:{radius:2,durationMs:2000,cooldownMs:10_000,scale:0.25},
};
export type CombatCommand =
  | {kind: "pose"; pose: PhonePose; observations: readonly BodyObservation[]}
  | {kind: "frameReady"; ready: boolean; residualMeters: number; residualDegrees: number; clockUncertaintyMs: number}
  | {kind: "start"}
  | {kind: "fire"; shotId: string; poseSequence: number; origin: Vec3; direction: Vec3}
  | {kind: "reload"}
  | {kind: "shield"; active: boolean; poseSequence: number}
  | {kind: "slowField"; poseSequence: number}
  | {kind: "leave"};
export interface CommandEnvelope {
  v: 1;
  commandId: string;
  clientSequence: number;
  authorityEpoch: number;
  frameEpoch: number;
  sentAtMs: number;
  command: CombatCommand;
}
export interface AuthenticatedCommand extends CommandEnvelope {playerId: string}
export interface ShieldState {activeUntilMs: number | null; cooldownUntilMs: number; energy: number}
export interface CombatPlayerState extends Member {
  health: number; ammo: number; kills: number; deaths: number;
  connected: boolean; frameReady: boolean;
  lastFireAtMs: number | null; reloadEndsAtMs: number | null;
  respawnAtMs: number | null; protectedUntilMs: number | null;
  shield: ShieldState; slowFieldReadyAtMs: number;
}
export interface ProjectileState {
  projectileId: string; shotId: string; shooterId: string;
  spawnedAtMs: number; position: Vec3; direction: Vec3; speed: number;
  segmentStartedAtMs: number; segmentOrigin: Vec3; timeScale: number;
  radius: number; expiresAtMs: number; distanceTravelled: number;
}
export interface SlowFieldState {
  fieldId: string; ownerId: string; center: Vec3; radius: number;
  startsAtMs: number; endsAtMs: number; scale: number;
}
export type RefusalReason =
  | "notRunning" | "notReady" | "notAlive" | "protected" | "cooldown" | "reloading"
  | "outOfAmmo" | "trackingLost" | "poseStale" | "poseMismatch" | "invalidRay"
  | "shieldActive" | "abilityCooldown" | "projectileLimit" | "tooLate" | "futureInput"
  | "notHost" | "unknownPlayer" | "invalidInput";
export type CombatEvent =
  | {kind: "poseChanged"; playerId: string; pose: PhonePose}
  | {kind: "commandResult"; commandId: string; clientSequence: number; playerId: string; accepted: boolean; reason: RefusalReason | null}
  | {kind: "projectileSpawn"; projectile: ProjectileState}
  | {kind: "projectileSegment"; projectileId: string; atMs: number; position: Vec3; timeScale: number}
  | {kind: "projectileTerminal"; projectileId: string; shotId: string; shooterId: string;
      reason: "bodyHit" | "shieldBlocked" | "missExpired" | "cancelled";
      atMs: number; position: Vec3; targetPlayerId: string | null; zone: HitZone | null; damage: number}
  | {kind: "fireRefused"; commandId: string; shotId: string | null; playerId: string; reason: RefusalReason}
  | {kind: "playerChanged"; player: CombatPlayerState}
  | {kind: "slowFieldChanged"; field: SlowFieldState}
  | {kind: "phaseChanged"; phase: CombatPhase; reason: string};
export type CombatPhase = "calibrating" | "running" | "paused" | "finished";
export interface CombatSnapshot {
  matchId: string; authorityEpoch: number; frameEpoch: number; tick: number; matchTimeMs: number;
  roundStartedAtMs: number | null;
  phase: CombatPhase; rules: CombatRules; players: readonly CombatPlayerState[];
  phonePoses: readonly PlayerPhonePose[];
  projectiles: readonly ProjectileState[]; slowFields: readonly SlowFieldState[];
}
export interface ServerEvent {
  v: 1; matchId: string; authorityEpoch: number; frameEpoch: number;
  eventSequence: number; tick: number; matchTimeMs: number; event: CombatEvent;
}
export type ClientMessage =
  | {type: "command"; envelope: CommandEnvelope}
  | {type: "received"; eventSequence: number}
  | {type: "resume"; afterEventSequence: number}
  | {type: "ping"; nonce: string; clientSentAtMs: number};
export type ServerMessage =
  | {type: "snapshot"; snapshot: CombatSnapshot; eventSequence: number; clientSequence: number}
  | {type: "events"; events: readonly ServerEvent[]}
  | {type: "ack"; commandId: string; clientSequence: number; replayed: boolean; eventSequence: number}
  | {type: "pong"; nonce: string; clientSentAtMs: number; serverReceivedAtMs: number; serverSentAtMs: number}
  | {type: "error"; code: "invalidMessage" | "unauthorized" | "rateLimited" | "epochMismatch" | "sequenceConflict" | "idempotencyConflict" | "replayExpired" | "roomFull" | "unavailable"; commandId?: string};
/** Signed by trusted lobby action, never accepted from an unauthenticated client. */
export interface CombatTicketClaims {
  v: 1; iss: "vkz-lobby"; aud: "vkz-combat";
  matchId: string; playerId: string; roster: readonly Member[];
  authorityEpoch: number; frameEpoch: number; rules: CombatRules;
  iat: number; exp: number; nonce: string;
}
/** Private authority-to-lobby projection; no camera, map or body observations. */
export interface CombatProjection {
  v: 1;
  matchId: string; authorityEpoch: number; frameEpoch: number;
  fromEventSequence: number; throughEventSequence: number;
  matchTimeMs: number; roundStartedAtMs: number | null; phase: CombatPhase;
  players: readonly CombatPlayerState[];
  terminals: readonly {eventSequence: number; event: Extract<CombatEvent, {kind: "projectileTerminal"}>}[];
}
export {parseClientMessage, validateCombatRules, validateTicketClaims, validateCombatProjection} from "./validation.js";
