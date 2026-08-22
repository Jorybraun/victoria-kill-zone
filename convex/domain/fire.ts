import {
  DEBUG_TORSO_DAMAGE,
  INITIAL_HEALTH,
  type ErrorCode,
  type HitZone,
} from "./contract.js";
import type { MatchPhase, PlayerRole } from "./contract.js";
import { isPresent } from "./presence.js";

/**
 * Debug fire: the temporary, explicitly labelled network path that proves one
 * phone can change the other's authoritative health through Convex. It claims a
 * torso hit only, and the server owns the damage, ammunition, and ledger.
 *
 * This is not markerless targeting and must stay until Vision targeting has
 * physical-device evidence.
 */

export interface DebugFireResult {
  accepted: boolean;
  outcome: "hit" | "rejected";
  clientShotId: string;
  replayed: boolean;
  damage: number;
  shooterAmmo: number;
  targetHealth: number;
  eventId?: string;
  rejectReason?: ErrorCode;
}

export interface FireShooter {
  readonly id: string;
  readonly displayName: string;
  readonly role: PlayerRole;
  readonly connected: boolean;
  readonly lastSeenAt: number;
  readonly ammo: number;
}

export interface FireTarget {
  readonly id: string;
  readonly displayName: string;
  readonly connected: boolean;
  readonly lastSeenAt: number;
  readonly health: number;
}

export interface ShotLedgerDraft {
  readonly shooterId: string;
  readonly targetId: string;
  readonly clientShotId: string;
  readonly zone: HitZone;
  readonly damage: number;
  readonly shooterAmmo: number;
  readonly targetHealth: number;
  readonly createdAt: number;
}

export interface HitEventDraft {
  readonly type: "hit";
  readonly message: string;
  readonly actorPlayerId: string;
  readonly targetPlayerId: string;
  readonly zone: HitZone;
  readonly damage: number;
  readonly createdAt: number;
}

export interface FirePlan {
  readonly result: DebugFireResult;
  /** Present only for an accepted first-time shot. */
  readonly ledger?: ShotLedgerDraft;
  readonly event?: HitEventDraft;
}

/** Stored ledger row used to answer a retry of the same press. */
export interface StoredShot {
  readonly clientShotId: string;
  readonly damage: number;
  readonly shooterAmmo: number;
  readonly targetHealth: number;
  readonly eventId?: string;
}

/**
 * Every rejection after successful authentication is a returned result, never a
 * throw, and reports the unchanged authoritative ammunition and health. Before a
 * second player joins there is no target row, so the result carries the health a
 * player is created with rather than inventing a sentinel.
 */
function rejection(
  clientShotId: string,
  shooter: FireShooter,
  target: FireTarget | null,
  reason?: ErrorCode,
): FirePlan {
  return {
    result: {
      accepted: false,
      outcome: "rejected",
      clientShotId,
      replayed: false,
      damage: 0,
      shooterAmmo: shooter.ammo,
      targetHealth: target?.health ?? INITIAL_HEALTH,
      ...(reason === undefined ? {} : { rejectReason: reason }),
    },
  };
}

/**
 * Replay of a stored `(shooterId, clientShotId)` press: the recorded outcome is
 * returned verbatim, so a retry consumes no ammunition, changes no health, and
 * appends no second event.
 */
export function replayShot(shot: StoredShot): FirePlan {
  return {
    result: {
      accepted: true,
      outcome: "hit",
      clientShotId: shot.clientShotId,
      replayed: true,
      damage: shot.damage,
      shooterAmmo: shot.shooterAmmo,
      targetHealth: shot.targetHealth,
      ...(shot.eventId === undefined ? {} : { eventId: shot.eventId }),
    },
  };
}

export function resolveDebugFire(request: {
  readonly phase: MatchPhase;
  readonly shooter: FireShooter;
  /** `null` until an opponent joins: a solo lobby has nothing to shoot at. */
  readonly target: FireTarget | null;
  readonly clientShotId: string;
  readonly now: number;
}): FirePlan {
  const { clientShotId, shooter, target } = request;

  // A missing idempotency key is a malformed press, not a credential problem, and
  // the frozen error union has no code for it.
  if (clientShotId.trim().length === 0) {
    return rejection(clientShotId, shooter, target);
  }

  if (request.phase !== "running" || target === null) {
    return rejection(clientShotId, shooter, target, "MATCH_NOT_RUNNING");
  }

  // Debug fire stays host-only for this slice; the guest has no fire control.
  if (shooter.role !== "host") {
    return rejection(clientShotId, shooter, target, "HOST_ONLY");
  }

  // Presence is the stored flag *and* heartbeat freshness at server time, so a
  // phone whose expiry job has not landed yet still cannot fire or be hit.
  if (!isPresent(shooter, request.now) || !isPresent(target, request.now)) {
    return rejection(clientShotId, shooter, target, "CONNECTION_STALE");
  }

  // The frozen error union has no ammunition or elimination code because reload,
  // respawn, and winner resolution are later gates; these press outcomes are
  // reported as a plain rejection.
  if (shooter.ammo <= 0 || target.health <= 0) {
    return rejection(clientShotId, shooter, target);
  }

  const damage = Math.min(DEBUG_TORSO_DAMAGE, target.health);
  const shooterAmmo = shooter.ammo - 1;
  const targetHealth = target.health - damage;

  return {
    result: {
      accepted: true,
      outcome: "hit",
      clientShotId,
      replayed: false,
      damage,
      shooterAmmo,
      targetHealth,
    },
    ledger: {
      shooterId: shooter.id,
      targetId: target.id,
      clientShotId,
      zone: "torso",
      damage,
      shooterAmmo,
      targetHealth,
      createdAt: request.now,
    },
    event: {
      type: "hit",
      message: `${shooter.displayName} HIT ${target.displayName} • TORSO \u2212${damage}`,
      actorPlayerId: shooter.id,
      targetPlayerId: target.id,
      zone: "torso",
      damage,
      createdAt: request.now,
    },
  };
}
