import { v } from "convex/values";
import type { DebugFireResult } from "../domain/fire.js";
import { replayShot, resolveDebugFire } from "../domain/fire.js";
import { resolvePhase } from "../domain/lifecycle.js";
import { mutation, type MutationCtx } from "./lib/server.js";
import { advancePhase, authenticatePlayer, fail, listPlayers } from "./lib/store.js";

/**
 * `shots:debugFire` — the authoritative, host-only debug network path.
 *
 * Damage, ammunition, and the ledger are server owned; the client contributes
 * only its idempotency key. Repeating `(shooterId, clientShotId)` returns the
 * stored outcome without a second state change or a second event.
 */
const debugFireArgs = {
  matchId: v.string(),
  playerId: v.string(),
  sessionSecret: v.string(),
  clientShotId: v.string(),
};

async function debugFireHandler(
  ctx: MutationCtx,
  args: {
    matchId: string;
    playerId: string;
    sessionSecret: string;
    clientShotId: string;
  },
): Promise<DebugFireResult> {
  const now = Date.now();
  const { match: stored, player: shooter } = await authenticatePlayer(ctx, args);

  const existing = await ctx.db
    .query("shots")
    .withIndex("by_shooter_client_shot", (q) =>
      q.eq("shooterId", shooter._id).eq("clientShotId", args.clientShotId),
    )
    .unique();

  if (existing !== null) {
    return replayShot(existing).result;
  }

  const match = await advancePhase(ctx, stored, now);
  const players = await listPlayers(ctx, match._id);
  const target = players.find((player) => player._id !== shooter._id);
  if (target === undefined) {
    fail("MATCH_NOT_RUNNING");
  }

  const plan = resolveDebugFire({
    phase: resolvePhase(match, now),
    shooter: {
      id: shooter._id,
      displayName: shooter.displayName,
      role: shooter.role,
      connected: shooter.connected,
      ammo: shooter.ammo,
    },
    target: {
      id: target._id,
      displayName: target.displayName,
      connected: target.connected,
      health: target.health,
    },
    clientShotId: args.clientShotId,
    now,
  });

  if (plan.ledger === undefined || plan.event === undefined) {
    return plan.result;
  }

  await ctx.db.patch(shooter._id, { ammo: plan.result.shooterAmmo });
  await ctx.db.patch(target._id, { health: plan.result.targetHealth });

  const eventId = await ctx.db.insert("events", {
    matchId: match._id,
    type: plan.event.type,
    message: plan.event.message,
    actorPlayerId: shooter._id,
    targetPlayerId: target._id,
    zone: plan.event.zone,
    damage: plan.event.damage,
    createdAt: plan.event.createdAt,
  });

  await ctx.db.insert("shots", {
    matchId: match._id,
    shooterId: shooter._id,
    targetId: target._id,
    clientShotId: plan.ledger.clientShotId,
    zone: plan.ledger.zone,
    damage: plan.ledger.damage,
    shooterAmmo: plan.ledger.shooterAmmo,
    targetHealth: plan.ledger.targetHealth,
    eventId,
    createdAt: plan.ledger.createdAt,
  });

  return { ...plan.result, eventId };
}

export const debugFire = mutation({
  args: debugFireArgs,
  handler: debugFireHandler,
});
