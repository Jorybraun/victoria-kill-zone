import { GAMEPLAY, damageForZone } from "./config.js";
import { hasExpired } from "./lifecycle.js";
import type {
  HitZone,
  MatchState,
  PlayerState,
  RejectReason,
  ShotOutcome,
  StatePatch,
} from "./types.js";

/** Client-submitted hit claim. Damage is deliberately absent from the request. */
export interface FireRequest {
  shooterId: string;
  clientShotId: string;
  targetId?: string;
  zone?: HitZone;
  poseConfidence?: number;
  firedAtClient: number;
}

export interface FireResult {
  accepted: boolean;
  outcome: ShotOutcome;
  rejectReason?: RejectReason;
  damage: number;
  shooterAmmo: number;
  targetHealth?: number;
  targetLifeState?: "alive" | "dead" | "respawning";
}

export interface ShotLedgerDraft {
  clientShotId: string;
  targetId: string | null;
  zone: HitZone | null;
  damage: number;
  outcome: ShotOutcome;
  rejectReason: RejectReason | null;
  poseConfidence: number | null;
  firedAtClient: number;
}

export interface EventDraft {
  type: "shot" | "hit" | "eliminated" | "finished";
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
 * Resolve a debug-fire hit claim against server-owned state.
 *
 * Validation order follows the technical specification: phase and timing, then
 * shooter membership/liveness, then ammunition and cooldown, then target
 * validity. Session authentication and shot idempotency are enforced by the
 * function layer before this runs, and every rejection is still ledgered.
 */
export function resolveDebugFire(
  match: Pick<MatchState, "status" | "endsAt">,
  shooter: PlayerState,
  opponent: PlayerState | null,
  request: FireRequest,
  now: number,
): FirePlan {
  if (match.status !== "active") {
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

  const claimedTargetId = request.targetId;
  const claimedZone = request.zone;
  if (claimedTargetId === undefined || claimedZone === undefined) {
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
          message: `${shooter.displayName} fired and missed`,
        },
      ],
      respawnAt: null,
    };
  }

  if (opponent === null || opponent.id !== claimedTargetId || opponent.id === shooter.id) {
    return reject(shooter, request, "invalid_target");
  }

  if (opponent.lifeState !== "alive") {
    return reject(shooter, request, "target_not_alive");
  }

  const zone = claimedZone;
  const damage = Math.min(damageForZone(zone), opponent.health);
  const remainingHealth = Math.max(0, opponent.health - damage);
  const eliminated = remainingHealth === 0;
  const outcome: ShotOutcome = eliminated ? "kill" : "hit";

  const events: EventDraft[] = [
    {
      type: "hit",
      actorPlayerId: shooter.id,
      targetPlayerId: opponent.id,
      zone,
      damage,
      message: `${shooter.displayName} hit ${opponent.displayName} (${zone}) for ${damage}`,
    },
  ];

  const targetPatch: StatePatch<PlayerState> = {
    health: remainingHealth,
    lifeState: eliminated ? "dead" : "alive",
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
    events.push({
      type: "eliminated",
      actorPlayerId: shooter.id,
      targetPlayerId: opponent.id,
      zone,
      damage,
      message: `${shooter.displayName} eliminated ${opponent.displayName}`,
    });
  }

  return {
    result: {
      accepted: true,
      outcome,
      damage,
      shooterAmmo,
      targetHealth: remainingHealth,
      targetLifeState: eliminated ? "dead" : "alive",
    },
    shooterPatch: fullShooterPatch,
    targetPatch,
    shot: ledger(request, { targetId: opponent.id, zone, damage, outcome }),
    events,
    respawnAt,
  };
}

/** Replay of an already-resolved `clientShotId`; never applies damage twice. */
export function replayResult(shot: Pick<ShotLedgerDraft, "outcome" | "damage">, shooterAmmo: number): FireResult {
  return {
    accepted: shot.outcome !== "rejected",
    outcome: shot.outcome,
    rejectReason: "duplicate_shot",
    damage: shot.damage,
    shooterAmmo,
  };
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
    firedAtClient: request.firedAtClient,
  };
}
