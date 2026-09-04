import { makeFunctionReference } from "convex/server";
import { v } from "convex/values";
import {
  fireClaimFingerprint,
  resolveDebugFire,
  resolveFire,
  resolveVerdictRecord,
  verdictFingerprint,
  verdictGate,
  type FirePlan,
  type FireRequest,
  type ShotVerdictRecord,
} from "../domain/fire.js";
import { fireLocationGate, locationStateFrom, type FireLocationGate } from "../domain/geofence.js";
import { mutation, type Doc, type Id, type MutationCtx } from "./lib/server.js";
import {
  appendEvent,
  arenaGeometryOf,
  authenticatePlayer,
  errorCodeForRejectReason,
  fail,
  listPlayers,
  toMatchState,
  toPlayerState,
  type BackendErrorCode,
} from "./lib/state.js";

const hitZone = v.union(v.literal("head"), v.literal("torso"), v.literal("limbs"));
const shotOutcome = v.union(
  v.literal("miss"),
  v.literal("hit"),
  v.literal("kill"),
  v.literal("rejected"),
);
const playerLifeState = v.union(
  v.literal("alive"),
  v.literal("dead"),
  v.literal("respawning"),
  v.literal("disconnected"),
);
const fireReturn = v.object({
  accepted: v.boolean(),
  outcome: shotOutcome,
  clientShotId: v.string(),
  replayed: v.boolean(),
  damage: v.number(),
  shooterAmmo: v.number(),
  targetHealth: v.optional(v.number()),
  targetLifeState: v.optional(playerLifeState),
  eventId: v.optional(v.id("events")),
  rejectReason: v.optional(v.string()),
});

const respawnReference = makeFunctionReference<
  "mutation",
  { playerId: Id<"players">; expectedRespawnAt: number },
  null
>("players:respawn");

interface FireWireResult {
  accepted: boolean;
  outcome: "miss" | "hit" | "kill" | "rejected";
  clientShotId: string;
  replayed: boolean;
  damage: number;
  shooterAmmo: number;
  targetHealth?: number;
  targetLifeState?: "alive" | "dead" | "respawning" | "disconnected";
  eventId?: Id<"events">;
  rejectReason?: BackendErrorCode;
}

interface DebugWireResult {
  accepted: boolean;
  outcome: "hit" | "rejected";
  clientShotId: string;
  replayed: boolean;
  damage: number;
  shooterAmmo: number;
  targetHealth: number;
  eventId?: Id<"events">;
  rejectReason?: BackendErrorCode;
}

/** G2-compatible trusted torso hit retained until physical markerless evidence. */
export const debugFire = mutation({
  args: {
    matchId: v.id("matches"),
    playerId: v.id("players"),
    sessionSecret: v.string(),
    clientShotId: v.string(),
  },
  returns: v.object({
    accepted: v.boolean(),
    outcome: v.union(v.literal("hit"), v.literal("rejected")),
    clientShotId: v.string(),
    replayed: v.boolean(),
    damage: v.number(),
    shooterAmmo: v.number(),
    targetHealth: v.number(),
    eventId: v.optional(v.id("events")),
    rejectReason: v.optional(v.string()),
  }),
  handler: async (ctx, args): Promise<DebugWireResult> => {
    if (args.clientShotId.trim().length === 0) {
      fail("INVALID_SESSION");
    }

    const shooter = await authenticatePlayer(ctx, args.matchId, args.playerId, args.sessionSecret);
    const match = await ctx.db.get(args.matchId);
    if (match === null) {
      fail("MATCH_NOT_FOUND");
    }
    const players = await listPlayers(ctx, match._id);
    const opponent = players.find((player) => player._id !== shooter._id) ?? null;

    const existing = await loadShot(ctx, shooter._id, args.clientShotId);
    if (existing !== null) {
      return debugResultFromStored(existing, opponent?.health ?? 100);
    }

    const now = Date.now();
    const request: FireRequest = {
      shooterId: shooter._id,
      clientShotId: args.clientShotId,
      ...(opponent === null ? {} : { targetId: opponent._id }),
      zone: "torso",
      poseConfidence: 1,
      firedAtClient: now,
    };
    // Migration rule: debug fire is arena-gated only when this match recorded
    // a validated arenaCenter. A legacy centerless match (current playable
    // iOS build, which never sends location) keeps working exactly as today.
    const locationGate =
      arenaGeometryOf(match) === null ? null : shooterLocationGate(shooter, now);
    const plan = resolveDebugFire(
      toMatchState(match),
      toPlayerState(shooter),
      opponent === null ? null : toPlayerState(opponent),
      request,
      now,
      locationGate,
    );

    const eventId = await persistPlan(ctx, match, shooter, opponent, request, plan, {
      mode: "debug",
      claimFingerprint: "debug",
      forceG2HitEvent: true,
    });
    return debugResult(plan, args.clientShotId, opponent?.health ?? 100, eventId);
  },
});

/** Phase0 markerless claim with authoritative zone damage and idempotency. */
export const fire = mutation({
  args: {
    matchId: v.id("matches"),
    shooterId: v.id("players"),
    sessionSecret: v.string(),
    clientShotId: v.string(),
    targetId: v.optional(v.id("players")),
    zone: v.optional(hitZone),
    poseConfidence: v.optional(v.number()),
    origin: v.optional(v.array(v.number())),
    direction: v.optional(v.array(v.number())),
    impact: v.optional(v.array(v.number())),
    firedAtClient: v.number(),
  },
  returns: fireReturn,
  handler: async (ctx, args): Promise<FireWireResult> => {
    const shooter = await authenticatePlayer(ctx, args.matchId, args.shooterId, args.sessionSecret);
    const match = await ctx.db.get(args.matchId);
    if (match === null) {
      fail("MATCH_NOT_FOUND");
    }

    if (
      args.clientShotId.trim().length === 0 ||
      !validVector(args.origin) ||
      !validVector(args.direction) ||
      !validVector(args.impact)
    ) {
      return conflictResult(args.clientShotId, shooter.ammo);
    }

    const request: FireRequest = {
      shooterId: shooter._id,
      clientShotId: args.clientShotId,
      firedAtClient: args.firedAtClient,
      ...(args.targetId === undefined ? {} : { targetId: args.targetId }),
      ...(args.zone === undefined ? {} : { zone: args.zone }),
      ...(args.poseConfidence === undefined ? {} : { poseConfidence: args.poseConfidence }),
      ...(args.origin === undefined ? {} : { origin: args.origin }),
      ...(args.direction === undefined ? {} : { direction: args.direction }),
      ...(args.impact === undefined ? {} : { impact: args.impact }),
    };
    const fingerprint = fireClaimFingerprint(request);
    const existing = await loadShot(ctx, shooter._id, args.clientShotId);
    if (existing !== null) {
      if (existing.mode === "fire" && existing.claimFingerprint === fingerprint) {
        return fireResultFromStored(existing);
      }
      return conflictResult(args.clientShotId, shooter.ammo);
    }

    const players = await listPlayers(ctx, match._id);
    const opponent = players.find((player) => player._id !== shooter._id) ?? null;
    const now = Date.now();
    // Centerless matches follow the same ungated migration rule as debug fire;
    // arena-centered matches retain the authoritative geofence gate.
    const plan = resolveFire(
      toMatchState(match),
      toPlayerState(shooter),
      opponent === null ? null : toPlayerState(opponent),
      request,
      now,
      arenaGeometryOf(match) === null ? null : shooterLocationGate(shooter, now),
    );
    const eventId = await persistPlan(ctx, match, shooter, opponent, request, plan, {
      mode: "fire",
      claimFingerprint: fingerprint,
      forceG2HitEvent: false,
    });
    return fireResult(plan, args.clientShotId, eventId);
  },
});

/** Host-posted spatial verdict persisted alongside the authoritative result. */
export const recordVerdict = mutation({
  args: {
    matchId: v.id("matches"),
    playerId: v.id("players"),
    sessionSecret: v.string(),
    record: v.object({
      clientShotId: v.string(),
      shooterPlayerId: v.id("players"),
      targetPlayerId: v.union(v.id("players"), v.null()),
      zone: v.union(hitZone, v.null()),
      damage: v.number(),
      rewindMs: v.number(),
      verdict: v.union(v.literal("hit"), v.literal("miss"), v.literal("rejected")),
      rejectionReason: v.union(v.string(), v.null()),
      origin: v.union(v.array(v.number()), v.null()),
      direction: v.union(v.array(v.number()), v.null()),
      impact: v.union(v.array(v.number()), v.null()),
      firedAtClient: v.number(),
      adjudicatedBy: v.id("players"),
      targetConfirmed: v.optional(v.union(v.boolean(), v.null())),
    }),
  },
  returns: fireReturn,
  handler: async (ctx, args): Promise<FireWireResult> => {
    const caller = await authenticatePlayer(ctx, args.matchId, args.playerId, args.sessionSecret);
    const match = await ctx.db.get(args.matchId);
    if (match === null) {
      fail("MATCH_NOT_FOUND");
    }
    const now = Date.now();
    const gate = verdictGate(toMatchState(match), caller._id, now);
    if (gate !== null) {
      fail(gate);
    }

    if (
      args.record.clientShotId.trim().length === 0 ||
      !validVector(args.record.origin) ||
      !validVector(args.record.direction) ||
      !validVector(args.record.impact)
    ) {
      return conflictResult(args.record.clientShotId, caller.ammo);
    }

    const record: ShotVerdictRecord = {
      ...args.record,
      targetConfirmed: args.record.targetConfirmed ?? null,
    };
    const fingerprint = verdictFingerprint(record);
    const existing = await loadShotForMatch(ctx, match._id, record.clientShotId);
    if (existing !== null) {
      if (existing.mode === "verdict" && existing.claimFingerprint === fingerprint) {
        return fireResultFromStored(existing);
      }
      return conflictResult(record.clientShotId, caller.ammo);
    }

    const players = await listPlayers(ctx, match._id);
    const shooter = players.find((player) => player._id === record.shooterPlayerId);
    if (shooter === undefined) {
      fail("INVALID_TARGET");
    }
    const target =
      record.targetPlayerId === null
        ? null
        : (players.find((player) => player._id === record.targetPlayerId) ?? null);
    const plan = resolveVerdictRecord(
      toMatchState(match),
      toPlayerState(caller),
      toPlayerState(shooter),
      target === null ? null : toPlayerState(target),
      record,
      now,
    );
    const request: FireRequest = {
      shooterId: shooter._id,
      clientShotId: record.clientShotId,
      firedAtClient: record.firedAtClient,
      ...(record.targetPlayerId === null ? {} : { targetId: record.targetPlayerId }),
      ...(record.zone === null ? {} : { zone: record.zone }),
      ...(record.origin === null ? {} : { origin: record.origin }),
      ...(record.direction === null ? {} : { direction: record.direction }),
      ...(record.impact === null ? {} : { impact: record.impact }),
    };
    const eventId = await persistPlan(ctx, match, shooter, target, request, plan, {
      mode: "verdict",
      claimFingerprint: fingerprint,
      forceG2HitEvent: false,
      targetConfirmed: args.record.targetConfirmed ?? null,
      ledgerExtras: {
        rewindMs: record.rewindMs,
        hostDamage: record.damage,
        verdict: record.verdict,
        hostRejectionReason: record.rejectionReason,
        adjudicatedBy: args.record.adjudicatedBy,
      },
    });
    return fireResult(plan, record.clientShotId, eventId);
  },
});

async function persistPlan(
  ctx: MutationCtx,
  match: Doc<"matches">,
  shooter: Doc<"players">,
  target: Doc<"players"> | null,
  request: FireRequest,
  plan: FirePlan,
  extra: PersistExtra,
): Promise<Id<"events"> | null> {
  if (plan.shooterPatch !== null) {
    await ctx.db.patch(shooter._id, plan.shooterPatch);
  }
  if (plan.targetPatch !== null && target !== null) {
    await ctx.db.patch(target._id, plan.targetPatch);
  }

  let eventId: Id<"events"> | null = null;
  const event = plan.events[0];
  if (event !== undefined) {
    eventId = await appendEvent(ctx, {
      matchId: match._id,
      type: extra.forceG2HitEvent ? "hit" : event.type,
      actorPlayerId: shooter._id,
      targetPlayerId: event.targetPlayerId === null ? null : (target?._id ?? null),
      zone: event.zone,
      damage: event.damage,
      message:
        extra.forceG2HitEvent && target !== null
          ? `${shooter.displayName} HIT ${target.displayName} • TORSO −${event.damage ?? 0}`
          : event.message,
      createdAt: Date.now(),
      ...(extra.targetConfirmed === undefined ? {} : { targetConfirmed: extra.targetConfirmed }),
    });
  }

  const rejectReason =
    plan.result.rejectReason === undefined
      ? null
      : extra.mode === "debug"
        ? debugErrorCode(plan.result.rejectReason)
        : errorCodeForRejectReason(plan.result.rejectReason);
  await ctx.db.insert("shots", {
    matchId: match._id,
    shooterId: shooter._id,
    targetId: plan.shot.targetId === null ? null : (target?._id ?? null),
    clientShotId: request.clientShotId,
    zone: plan.shot.zone,
    damage: plan.shot.damage,
    outcome: plan.shot.outcome,
    rejectReason,
    poseConfidence: plan.shot.poseConfidence,
    ...(request.origin === undefined ? {} : { origin: [...request.origin] }),
    ...(request.direction === undefined ? {} : { direction: [...request.direction] }),
    ...(request.impact === undefined ? {} : { impact: [...request.impact] }),
    firedAtClient: plan.shot.firedAtClient,
    mode: extra.mode,
    claimFingerprint: extra.claimFingerprint,
    shooterAmmo: plan.result.shooterAmmo,
    targetHealth: plan.result.targetHealth ?? null,
    targetLifeState: plan.result.targetLifeState ?? null,
    eventId,
    createdAt: Date.now(),
    ...extra.ledgerExtras,
  });

  if (plan.respawnAt !== null && target !== null) {
    await ctx.scheduler.runAt(plan.respawnAt, respawnReference, {
      playerId: target._id,
      expectedRespawnAt: plan.respawnAt,
    });
  }
  return eventId;
}

type PersistExtra = {
  mode: "debug" | "fire" | "verdict";
  claimFingerprint: string;
  forceG2HitEvent: boolean;
  targetConfirmed?: boolean | null;
  ledgerExtras?: Partial<
    Pick<
      Doc<"shots">,
      "rewindMs" | "hostDamage" | "verdict" | "hostRejectionReason" | "adjudicatedBy"
    >
  >;
};

async function loadShot(
  ctx: MutationCtx,
  shooterId: Id<"players">,
  clientShotId: string,
): Promise<Doc<"shots"> | null> {
  return await ctx.db
    .query("shots")
    .withIndex("by_shooter_and_client_shot_id", (q) =>
      q.eq("shooterId", shooterId).eq("clientShotId", clientShotId),
    )
    .unique();
}

async function loadShotForMatch(
  ctx: MutationCtx,
  matchId: Id<"matches">,
  clientShotId: string,
): Promise<Doc<"shots"> | null> {
  return await ctx.db
    .query("shots")
    .withIndex("by_match_and_client_shot_id", (q) =>
      q.eq("matchId", matchId).eq("clientShotId", clientShotId),
    )
    .unique();
}

function fireResult(
  plan: FirePlan,
  clientShotId: string,
  eventId: Id<"events"> | null,
): FireWireResult {
  return {
    accepted: plan.result.accepted,
    outcome: plan.result.outcome,
    clientShotId,
    replayed: false,
    damage: plan.result.damage,
    shooterAmmo: plan.result.shooterAmmo,
    ...(plan.result.targetHealth === undefined ? {} : { targetHealth: plan.result.targetHealth }),
    ...(plan.result.targetLifeState === undefined
      ? {}
      : { targetLifeState: plan.result.targetLifeState }),
    ...(eventId === null ? {} : { eventId }),
    ...(plan.result.rejectReason === undefined
      ? {}
      : { rejectReason: errorCodeForRejectReason(plan.result.rejectReason) }),
  };
}

function debugResult(
  plan: FirePlan,
  clientShotId: string,
  fallbackTargetHealth: number,
  eventId: Id<"events"> | null,
): DebugWireResult {
  return {
    accepted: plan.result.accepted,
    outcome: plan.result.accepted ? "hit" : "rejected",
    clientShotId,
    replayed: false,
    damage: plan.result.damage,
    shooterAmmo: plan.result.shooterAmmo,
    targetHealth: plan.result.targetHealth ?? fallbackTargetHealth,
    ...(eventId === null ? {} : { eventId }),
    ...(plan.result.rejectReason === undefined
      ? {}
      : { rejectReason: debugErrorCode(plan.result.rejectReason) }),
  };
}

function fireResultFromStored(shot: Doc<"shots">): FireWireResult {
  return {
    accepted: shot.outcome !== "rejected",
    outcome: shot.outcome,
    clientShotId: shot.clientShotId,
    replayed: true,
    damage: shot.damage,
    shooterAmmo: shot.shooterAmmo ?? 0,
    ...(shot.targetHealth === undefined || shot.targetHealth === null
      ? {}
      : { targetHealth: shot.targetHealth }),
    ...(shot.targetLifeState === undefined || shot.targetLifeState === null
      ? {}
      : { targetLifeState: shot.targetLifeState }),
    ...(shot.eventId === undefined || shot.eventId === null ? {} : { eventId: shot.eventId }),
    ...(shot.rejectReason === undefined || shot.rejectReason === null
      ? {}
      : { rejectReason: shot.rejectReason as BackendErrorCode }),
  };
}

function debugResultFromStored(shot: Doc<"shots">, fallbackTargetHealth: number): DebugWireResult {
  return {
    accepted: shot.outcome !== "rejected",
    outcome: shot.outcome === "rejected" ? "rejected" : "hit",
    clientShotId: shot.clientShotId,
    replayed: true,
    damage: shot.damage,
    shooterAmmo: shot.shooterAmmo ?? 0,
    targetHealth: shot.targetHealth ?? fallbackTargetHealth,
    ...(shot.eventId === undefined || shot.eventId === null ? {} : { eventId: shot.eventId }),
    ...(shot.rejectReason === undefined || shot.rejectReason === null
      ? {}
      : { rejectReason: shot.rejectReason as BackendErrorCode }),
  };
}

function conflictResult(clientShotId: string, shooterAmmo: number): FireWireResult {
  return {
    accepted: false,
    outcome: "rejected",
    clientShotId,
    replayed: false,
    damage: 0,
    shooterAmmo,
    rejectReason: "IDEMPOTENCY_CONFLICT",
  };
}

/** Authoritative geofence verdict for a shooter at fire time. */
function shooterLocationGate(shooter: Doc<"players">, now: number): FireLocationGate | null {
  return fireLocationGate(locationStateFrom(toPlayerState(shooter)), now);
}

function debugErrorCode(reason: NonNullable<FirePlan["result"]["rejectReason"]>): BackendErrorCode {
  switch (reason) {
    case "shooter_disconnected":
      return "CONNECTION_STALE";
    case "out_of_arena":
      return "OUT_OF_ARENA";
    case "location_stale":
      return "LOCATION_STALE";
    default:
      return "MATCH_NOT_RUNNING";
  }
}

function validVector(vector: number[] | null | undefined): boolean {
  return vector === undefined || vector === null || (vector.length === 3 && vector.every(Number.isFinite));
}
