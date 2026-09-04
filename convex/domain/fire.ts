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

export interface FirePlan {
  result: FireResult;
  shooterPatch: StatePatch<PlayerState> | null;
  targetPatch: StatePatch<PlayerState> | null;
  shot: ShotLedgerDraft;
  events: readonly EventDraft[];
  respawnAt: number | null;
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
    return reject(shooter, request, "match_not_active");
  }

  if (hasExpired(match, now)) {
    return reject(shooter, request, "match_expired");
  }

  if (!shooter.connected) {
    return reject(shooter, request, "shooter_disconnected");
  }

  if (shooter.lifeState !== "alive") {
    return reject(shooter, request, "shooter_not_alive");
  }

  if (locationGate !== null) {
    return reject(shooter, request, locationGate);
  }

  if (shooter.ammo <= 0) {
    return reject(shooter, request, "out_of_ammo");
  }

  if (shooter.lastShotAt !== null && now - shooter.lastShotAt < GAMEPLAY.fireCooldownMs) {
    return reject(shooter, request, "cooldown_active");
  }

  const shooterPatch: StatePatch<PlayerState> = {
    ammo: Math.max(0, shooter.ammo - 1),
    shotsFired: shooter.shotsFired + 1,
    lastShotAt: now,
    lastSeenAt: now,
  };
  const shooterAmmo = shooterPatch.ammo ?? shooter.ammo;

  const hasTarget = request.targetId !== undefined;
  const hasZone = request.zone !== undefined;
  const hasConfidence = request.poseConfidence !== undefined;
  const isMiss = !hasTarget && !hasZone && !hasConfidence;

  if (isMiss) {
    return {
      result: { accepted: true, outcome: "miss", damage: 0, shooterAmmo },
      shooterPatch,
      targetPatch: null,
      shot: ledger(request, { targetId: null, zone: null, damage: 0, outcome: "miss" }),
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

  if (!hasTarget || !hasZone || !hasConfidence) {
    return reject(shooter, request, "invalid_target");
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
    return reject(shooter, request, "invalid_target");
  }

  if (opponent === null || opponent.id !== claimedTargetId || opponent.id === shooter.id) {
    return reject(shooter, request, "invalid_target");
  }

  if (opponent.lifeState !== "alive") {
    return reject(shooter, request, "target_not_alive");
  }

  const damage = Math.min(damageForZone(zone), opponent.health);
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
    headshots: shooter.headshots + (zone === "head" ? 1 : 0),
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
        zone,
        damage,
        message: `${shooter.displayName} ELIMINATED ${opponent.displayName}`,
      }
    : {
        type: "hit",
        actorPlayerId: shooter.id,
        targetPlayerId: opponent.id,
        zone,
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
    shot: ledger(request, { targetId: opponent.id, zone, damage, outcome }),
    events: [event],
    respawnAt,
  };
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

function reject(shooter: PlayerState, request: FireRequest, reason: RejectReason): FirePlan {
  return {
    result: {
      accepted: false,
      outcome: "rejected",
      rejectReason: reason,
      damage: 0,
      shooterAmmo: shooter.ammo,
    },
    shooterPatch: null,
    targetPatch: null,
    shot: ledger(request, {
      targetId: request.targetId ?? null,
      zone: request.zone ?? null,
      damage: 0,
      outcome: "rejected",
      rejectReason: reason,
    }),
    events: [],
    respawnAt: null,
  };
}

function ledger(
  request: FireRequest,
  resolution: {
    targetId: string | null;
    zone: HitZone | null;
    damage: number;
    outcome: ShotOutcome;
    rejectReason?: RejectReason;
  },
): ShotLedgerDraft {
  return {
    clientShotId: request.clientShotId,
    targetId: resolution.targetId,
    zone: resolution.zone,
    damage: resolution.damage,
    outcome: resolution.outcome,
    rejectReason: resolution.rejectReason ?? null,
    poseConfidence: request.poseConfidence ?? null,
    origin: request.origin ?? null,
    direction: request.direction ?? null,
    impact: request.impact ?? null,
    firedAtClient: request.firedAtClient,
  };
}
