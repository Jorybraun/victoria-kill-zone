import { v } from "convex/values";
import { shouldExpirePresence } from "../domain/presence.js";
import { internalMutation, mutation } from "./lib/server.js";
import { authenticatePlayer, schedulePresenceExpiry } from "./lib/store.js";

/**
 * `players:heartbeat` — renews the caller's own presence.
 *
 * Presence is a server fact rather than a client claim: the phone may only say
 * "still here", and the server records its own receipt time. Health, score, and
 * readiness are untouched, so a reconnecting player resumes exactly where the
 * authoritative state left them.
 */
export const heartbeat = mutation({
  args: { matchId: v.string(), playerId: v.string(), sessionSecret: v.string() },
  handler: async (ctx, args): Promise<null> => {
    const now = Date.now();
    const { player } = await authenticatePlayer(ctx, args);

    await ctx.db.patch(player._id, { connected: true, lastSeenAt: now });
    await schedulePresenceExpiry(ctx, player._id, now);

    return null;
  },
});

/**
 * `internal.players:expirePresence` — fires 15 seconds after the heartbeat it
 * was armed for.
 *
 * Guarded by that heartbeat, so a renewal supersedes its pending job and a
 * duplicate or early run writes nothing.
 */
export const expirePresence = internalMutation({
  args: { playerId: v.id("players"), expectedLastSeenAt: v.number() },
  handler: async (ctx, args): Promise<null> => {
    const player = await ctx.db.get(args.playerId);
    if (player === null) {
      return null;
    }

    if (shouldExpirePresence(player, args.expectedLastSeenAt, Date.now())) {
      await ctx.db.patch(player._id, { connected: false });
    }

    return null;
  },
});
