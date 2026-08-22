import { v } from "convex/values";
import { replayResult, resolveDebugFire, type FireRequest } from "../domain/fire.js";
import { mutation } from "./lib/server.js";
import { authenticatePlayer, fail, listPlayers, toPlayerState } from "./lib/state.js";

const hitZone = v.union(v.literal("head"), v.literal("torso"), v.literal("limbs"));

/**
 * Debug-fire network path: the shooter submits a hit claim and the server
 * resolves it authoritatively.
 *
 * Client-supplied damage does not exist in the argument shape; damage comes from
 * server-owned zone configuration. Shots are idempotent per
 * `{ shooterId, clientShotId }`, so a retried request never applies damage twice.
 */
export const debugFire = mutation({
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
    firedAtClient: v.number(),
  },
  returns: v.object({
    accepted: v.boolean(),
    outcome: v.union(
      v.literal("miss"),
      v.literal("hit"),
      v.literal("kill"),
      v.literal("rejected"),
    ),
    rejectReason: v.optional(v.string()),
    damage: v.number(),
    shooterAmmo: v.number(),
    targetHealth: v.optional(v.number()),
    targetLifeState: v.optional(
      v.union(v.literal("alive"), v.literal("dead"), v.literal("respawning")),
    ),
  }),
  handler: async (ctx, args) => {
    if (args.clientShotId.trim().length === 0) {
      fail("duplicate_shot");
    }

    const shooter = await authenticatePlayer(ctx, args.matchId, args.shooterId, args.sessionSecret);
    const match = await ctx.db.get(args.matchId);
    if (match === null) {
      fail("match_not_found");
    }

    const alreadyResolved = await ctx.db
      .query("shots")
      .withIndex("by_shooter_and_client_shot_id", (q) =>
        q.eq("shooterId", shooter._id).eq("clientShotId", args.clientShotId),
      )
      .unique();
    if (alreadyResolved !== null) {
      return replayResult(alreadyResolved, shooter.ammo);
    }

    const players = await listPlayers(ctx, match._id);
    const opponent = players.find((player) => player._id !== shooter._id) ?? null;

    const request: FireRequest = {
      shooterId: shooter._id,
      clientShotId: args.clientShotId,
      firedAtClient: args.firedAtClient,
      ...(args.targetId === undefined ? {} : { targetId: args.targetId }),
      ...(args.zone === undefined ? {} : { zone: args.zone }),
      ...(args.poseConfidence === undefined ? {} : { poseConfidence: args.poseConfidence }),
    };

    const now = Date.now();
    const plan = resolveDebugFire(
      match,
      toPlayerState(shooter),
      opponent === null ? null : toPlayerState(opponent),
      request,
      now,
    );

    if (plan.shooterPatch !== null) {
      await ctx.db.patch(shooter._id, plan.shooterPatch);
    }

    if (plan.targetPatch !== null && opponent !== null) {
      await ctx.db.patch(opponent._id, plan.targetPatch);
    }

    await ctx.db.insert("shots", {
      matchId: match._id,
      shooterId: shooter._id,
      targetId: plan.shot.targetId === null ? null : (opponent?._id ?? null),
      clientShotId: plan.shot.clientShotId,
      zone: plan.shot.zone,
      damage: plan.shot.damage,
      outcome: plan.shot.outcome,
      rejectReason: plan.shot.rejectReason,
      poseConfidence: plan.shot.poseConfidence,
      firedAtClient: plan.shot.firedAtClient,
      createdAt: now,
    });

    for (const event of plan.events) {
      await ctx.db.insert("events", {
        matchId: match._id,
        type: event.type === "finished" ? "finished" : event.type,
        actorPlayerId: event.actorPlayerId === null ? null : shooter._id,
        targetPlayerId: event.targetPlayerId === null ? null : (opponent?._id ?? null),
        zone: event.zone,
        damage: event.damage,
        message: event.message,
        createdAt: now,
      });
    }

    return {
      accepted: plan.result.accepted,
      outcome: plan.result.outcome,
      damage: plan.result.damage,
      shooterAmmo: plan.result.shooterAmmo,
      ...(plan.result.rejectReason === undefined ? {} : { rejectReason: plan.result.rejectReason }),
      ...(plan.result.targetHealth === undefined ? {} : { targetHealth: plan.result.targetHealth }),
      ...(plan.result.targetLifeState === undefined
        ? {}
        : { targetLifeState: plan.result.targetLifeState }),
    };
  },
});
