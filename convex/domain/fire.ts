import { GAMEPLAY, damageForZone } from "./config.js";
import type { FireLocationGate } from "./geofence.js";
import { hasExpired } from "./lifecycle.js";
import type {
  HitZone,
  MatchState,
  PlayerState,
  RejectReason,
  ShotOutcome,
  StatePatch,
} from "./types.js";

/** Client-submitted markerless hit claim. Damage is deliberately absent. */
export interface FireRequest {
  shooterId: string;
  clientShotId: string;
  targetId?: string;
  zone?: HitZone;
  poseConfidence?: number;
  origin?: readonly number[];
  direction?: readonly number[];
  impact?: readonly number[];
  firedAtClient: number;
}

export interface FireResult {
  accepted: boolean;
  outcome: ShotOutcome;
  rejectReason?: RejectReason;
  damage: number;
  shooterAmmo: number;
  targetHealth?: number;
  targetLifeState?: "alive" | "respawning";
}

export interface ShotLedgerDraft {
  clientShotId: string;
  targetId: string | null;
  zone: HitZone | null;
  damage: number;
  outcome: ShotOutcome;
  rejectReason: RejectReason | null;
  poseConfidence: number | null;
  origin: readonly number[] | null;
  direction: readonly number[] | null;
  impact: readonly number[] | null;
  firedAtClient: number;
}

export interface EventDraft {
  type: "shot" | "hit" | "eliminated";
  actorPlayerId: string | null;
  targetPlayerId: string | null;
  zone: HitZone | null;
  damage: number | null;
  message: string;
}

/** Terminal adjudication of one shot, independent of who adjudicated it. */
export type ShotResolution =
  | { kind: "miss" }
  | { kind: "hit"; zone: HitZone }
  | { kind: "rejected"; reason: RejectReason };

/** What the ledger row needs from a claim or host verdict record. */
export interface ShotIdentity {
  clientShotId: string;
  targetId: string | null;
  zone: HitZone | null;
  poseConfidence: number | null;
  origin: readonly number[] | null;
  direction: readonly number[] | null;
  impact: readonly number[] | null;
  firedAtClient: number;
}

export interface FirePlan {
  result: FireResult;
  shooterPatch: StatePatch<PlayerState> | null;
  targetPatch: StatePatch<PlayerState> | null;
  shot: ShotLedgerDraft;
  events: readonly EventDraft[];
  respawnAt: number | null;
}

export type VerdictKind = "hit" | "miss" | "rejected";

/** Host-adjudicated terminal record posted to the durable ledger (ADR 0004 §3). */
export interface ShotVerdictRecord {
  clientShotId: string;
  shooterPlayerId: string;
  targetPlayerId: string | null;
  zone: HitZone | null;
  damage: number;
  rewindMs: number;
  verdict: VerdictKind;
  rejectionReason: string | null;
  origin: readonly number[] | null;
  direction: readonly number[] | null;
  impact: readonly number[] | null;
  firedAtClient: number;
  adjudicatedBy: string;
  targetConfirmed: boolean | null;
}

/**
 * Resolve one markerless fire claim against server-owned state. Authentication
 * and the idempotency lookup happen in the Convex adapter before this planner.
 * `locationGate` is the authoritative geofence verdict computed by the adapter
 * (`fireLocationGate`); it is checked after presence/life and before ammo per
 * the contract ordering, and a gated shot changes no gameplay state.
 */
export function resolveFire(
  match: Pick<MatchState, "status" | "phase" | "endsAt">,
  shooter: PlayerState,
  opponent: PlayerState | null,
  request: FireRequest,
  now: number,
  locationGate: FireLocationGate | null = null,
): FirePlan {
  if (match.status !== "active" || match.phase !== "running") {
    return applyVerdict(shooter, opponent, { kind: "rejected", reason: "match_not_active" }, identityFrom(request), now);
  }

  if (hasExpired(match, now)) {
    return applyVerdict(shooter, opponent, { kind: "rejected", reason: "match_expired" }, identityFrom(request), now);
  }

  if (!shooter.connected) {
    return applyVerdict(shooter, opponent, { kind: "rejected", reason: "shooter_disconnected" }, identityFrom(request), now);
  }

  if (shooter.lifeState !== "alive") {
    return applyVerdict(shooter, opponent, { kind: "rejected", reason: "shooter_not_alive" }, identityFrom(request), now);
  }

  if (locationGate !== null) {
    return applyVerdict(shooter, opponent, { kind: "rejected", reason: locationGate }, identityFrom(request), now);
  }

  if (shooter.ammo <= 0) {
    return applyVerdict(shooter, opponent, { kind: "rejected", reason: "out_of_ammo" }, identityFrom(request), now);
  }

  if (shooter.lastShotAt !== null && now - shooter.lastShotAt < GAMEPLAY.fireCooldownMs) {
    return applyVerdict(shooter, opponent, { kind: "rejected", reason: "cooldown_active" }, identityFrom(request), now);
  }

  const hasTarget = request.targetId !== undefined;
  const hasZone = request.zone !== undefined;
  const hasConfidence = request.poseConfidence !== undefined;
  const isMiss = !hasTarget && !hasZone && !hasConfidence;

  if (isMiss) {
    return applyVerdict(shooter, opponent, { kind: "miss" }, identityFrom(request), now);
  }

  if (!hasTarget || !hasZone || !hasConfidence) {
    return applyVerdict(shooter, opponent, { kind: "rejected", reason: "invalid_target" }, identityFrom(request), now);
  }

  const claimedTargetId = request.targetId;
  const zone = request.zone;
  const poseConfidence = request.poseConfidence;
  if (
    claimedTargetId === undefined ||
    zone === undefined ||
    poseConfidence === undefined ||
    !Number.isFinite(poseConfidence) ||
    poseConfidence < (zone === "head" ? 0.6 : 0.45)
  ) {
    return applyVerdict(shooter, opponent, { kind: "rejected", reason: "invalid_target" }, identityFrom(request), now);
  }

  if (opponent === null || opponent.id !== claimedTargetId || opponent.id === shooter.id) {
    return applyVerdict(shooter, opponent, { kind: "rejected", reason: "invalid_target" }, identityFrom(request), now);
  }

  if (opponent.lifeState !== "alive") {
    return applyVerdict(shooter, opponent, { kind: "rejected", reason: "target_not_alive" }, identityFrom(request), now);
  }

  return applyVerdict(shooter, opponent, { kind: "hit", zone }, identityFrom(request), now);
}

/**
 * Apply a terminal resolution to server-owned state.
 * Rejections change no state and emit no event.
 */
export function applyVerdict(
  shooter: PlayerState,
  opponent: PlayerState | null,
  resolution: ShotResolution,
  identity: ShotIdentity,
  now: number,
): FirePlan {
  if (resolution.kind === "rejected") {
    return {
      result: {
        accepted: false,
        outcome: "rejected",
        rejectReason: resolution.reason,
        damage: 0,
        shooterAmmo: shooter.ammo,
      },
      shooterPatch: null,
      targetPatch: null,
      shot: ledger(identity, {
        targetId: identity.targetId,
        zone: identity.zone,
        damage: 0,
        outcome: "rejected",
        rejectReason: resolution.reason,
      }),
      events: [],
      respawnAt: null,
    };
  }

  const shooterPatch: StatePatch<PlayerState> = {
    ammo: Math.max(0, shooter.ammo - 1),
    shotsFired: shooter.shotsFired + 1,
    lastShotAt: now,
    lastSeenAt: now,
  };
  const shooterAmmo = shooterPatch.ammo ?? shooter.ammo;

  if (resolution.kind === "miss") {
    return {
      result: { accepted: true, outcome: "miss", damage: 0, shooterAmmo },
      shooterPatch,
      targetPatch: null,
      shot: ledger(identity, {
        targetId: identity.targetId,
        zone: identity.zone,
        damage: 0,
        outcome: "miss",
      }),
      events: [
        {
          type: "shot",
          actorPlayerId: shooter.id,
          targetPlayerId: null,
          zone: null,
          damage: null,
          message: `${shooter.displayName} MISSED`,
        },
      ],
      respawnAt: null,
    };
  }

  if (opponent === null || opponent.id !== identity.targetId || opponent.id === shooter.id) {
    return applyVerdict(
      shooter,
      opponent,
      { kind: "rejected", reason: "invalid_target" },
      identity,
      now,
    );
  }

  const damage = Math.min(damageForZone(resolution.zone), opponent.health);
  const remainingHealth = Math.max(0, opponent.health - damage);
  const eliminated = remainingHealth === 0;
  const outcome: ShotOutcome = eliminated ? "kill" : "hit";
  const targetPatch: StatePatch<PlayerState> = {
    health: remainingHealth,
    lifeState: eliminated ? "respawning" : "alive",
  };
  const fullShooterPatch: StatePatch<PlayerState> = {
    ...shooterPatch,
    shotsHit: shooter.shotsHit + 1,
    headshots: shooter.headshots + (resolution.zone === "head" ? 1 : 0),
    damageDealt: shooter.damageDealt + damage,
    kills: shooter.kills + (eliminated ? 1 : 0),
  };

  let respawnAt: number | null = null;
  if (eliminated) {
    respawnAt = now + GAMEPLAY.respawnDelayMs;
    targetPatch.deaths = opponent.deaths + 1;
    targetPatch.respawnAt = respawnAt;
  }

  const event: EventDraft = eliminated
    ? {
        type: "eliminated",
        actorPlayerId: shooter.id,
        targetPlayerId: opponent.id,
        zone: resolution.zone,
        damage,
        message: `${shooter.displayName} ELIMINATED ${opponent.displayName}`,
      }
    : {
        type: "hit",
        actorPlayerId: shooter.id,
        targetPlayerId: opponent.id,
        zone: resolution.zone,
        damage,
        message: `${shooter.displayName} HIT ${opponent.displayName}`,
      };

  return {
    result: {
      accepted: true,
      outcome,
      damage,
      shooterAmmo,
      targetHealth: remainingHealth,
      targetLifeState: eliminated ? "respawning" : "alive",
    },
    shooterPatch: fullShooterPatch,
    targetPatch,
    shot: ledger(identity, {
      targetId: opponent.id,
      zone: resolution.zone,
      damage,
      outcome,
    }),
    events: [event],
    respawnAt,
  };
}

/** Host and lifecycle gate used by the recordVerdict adapter. */
export function verdictGate(
  match: Pick<MatchState, "status" | "phase" | "endsAt" | "hostPlayerId">,
  callerId: string,
  now: number,
): RejectReason | null {
  if (match.hostPlayerId !== callerId) {
    return "not_host";
  }
  if (match.status !== "active" || match.phase !== "running") {
    return "match_not_active";
  }
  if (hasExpired(match, now)) {
    return "match_expired";
  }
  return null;
}

export function resolveVerdictRecord(
  _match: Pick<MatchState, "status" | "phase" | "endsAt" | "hostPlayerId">,
  _caller: PlayerState,
  shooter: PlayerState,
  target: PlayerState | null,
  record: ShotVerdictRecord,
  now: number,
): FirePlan {
  const identity: ShotIdentity = {
    clientShotId: record.clientShotId,
    targetId: record.targetPlayerId,
    zone: record.zone,
    poseConfidence: null,
    origin: record.origin,
    direction: record.direction,
    impact: record.impact,
    firedAtClient: record.firedAtClient,
  };

  if (record.verdict === "rejected") {
    return applyVerdict(shooter, target, { kind: "rejected", reason: "host_rejected" }, identity, now);
  }
  if (record.verdict === "miss") {
    return shooter.lifeState === "alive"
      ? applyVerdict(shooter, target, { kind: "miss" }, identity, now)
      : applyVerdict(shooter, target, { kind: "rejected", reason: "shooter_not_alive" }, identity, now);
  }
  if (
    record.zone === null ||
    target === null ||
    target.id !== record.targetPlayerId ||
    target.id === shooter.id
  ) {
    return applyVerdict(shooter, target, { kind: "rejected", reason: "invalid_target" }, identity, now);
  }
  if (target.lifeState !== "alive") {
    return applyVerdict(shooter, target, { kind: "rejected", reason: "target_not_alive" }, identity, now);
  }
  if (shooter.lifeState !== "alive") {
    return applyVerdict(shooter, target, { kind: "rejected", reason: "shooter_not_alive" }, identity, now);
  }
  return applyVerdict(shooter, target, { kind: "hit", zone: record.zone }, identity, now);
}

export function verdictFingerprint(record: ShotVerdictRecord): string {
  return JSON.stringify([
    record.shooterPlayerId,
    record.targetPlayerId,
    record.zone,
    record.damage,
    record.rewindMs,
    record.verdict,
    record.rejectionReason,
    record.origin,
    record.direction,
    record.impact,
    record.firedAtClient,
    record.adjudicatedBy,
  ]);
}

/**
 * G2 debug fire is a trusted torso claim against the only opponent. The
 * adapter passes a `locationGate` only for a match with a recorded arenaCenter;
 * a legacy centerless match keeps the ungated G2 behavior.
 */
export function resolveDebugFire(
  match: Pick<MatchState, "status" | "phase" | "endsAt">,
  shooter: PlayerState,
  opponent: PlayerState | null,
  request: FireRequest,
  now: number,
  locationGate: FireLocationGate | null = null,
): FirePlan {
  const targetId = opponent?.id ?? request.targetId;
  return resolveFire(
    match,
    shooter,
    opponent,
    {
      ...request,
      ...(targetId === undefined ? {} : { targetId }),
      zone: "torso",
      poseConfidence: 1,
    },
    now,
    locationGate,
  );
}

/** Stable claim identity used to distinguish a retry from conflicting reuse. */
export function fireClaimFingerprint(request: FireRequest): string {
  return JSON.stringify([
    request.targetId ?? null,
    request.zone ?? null,
    request.poseConfidence ?? null,
    request.origin ?? null,
    request.direction ?? null,
    request.impact ?? null,
    request.firedAtClient,
  ]);
}

/** Replay copies the original result; callers add `replayed: true` on the wire. */
export function replayResult(result: FireResult): FireResult {
  return { ...result };
}

function ledger(
  identity: ShotIdentity,
  resolution: {
    targetId: string | null;
    zone: HitZone | null;
    damage: number;
    outcome: ShotOutcome;
    rejectReason?: RejectReason;
  },
): ShotLedgerDraft {
  return {
    clientShotId: identity.clientShotId,
    targetId: resolution.targetId,
    zone: resolution.zone,
    damage: resolution.damage,
    outcome: resolution.outcome,
    rejectReason: resolution.rejectReason ?? null,
    poseConfidence: identity.poseConfidence,
    origin: identity.origin,
    direction: identity.direction,
    impact: identity.impact,
    firedAtClient: identity.firedAtClient,
  };
}

function identityFrom(request: FireRequest): ShotIdentity {
  return {
    clientShotId: request.clientShotId,
    targetId: request.targetId ?? null,
    zone: request.zone ?? null,
    poseConfidence: request.poseConfidence ?? null,
    origin: request.origin ?? null,
    direction: request.direction ?? null,
    impact: request.impact ?? null,
    firedAtClient: request.firedAtClient,
  };
}
