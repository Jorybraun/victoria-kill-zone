import { v } from "convex/values";
import { planRespawn } from "../domain/respawn.js";
import { internalMutation, mutation } from "./lib/server.js";
import {
  appendEvent,
  authenticatePlayer,
  toMatchState,
  toPlayerState,
} from "./lib/state.js";

const locationSample = v.object({
  latitude: v.number(),
  longitude: v.number(),
  accuracyMeters: v.number(),
  capturedAtClient: v.number(),
  headingDegrees: v.optional(v.number()),
});

/** Presence heartbeat; location is accepted for forward compatibility only. */
export const heartbeat = mutation({
  args: {
    matchId: v.id("matches"),
    playerId: v.id("players"),
    sessionSecret: v.string(),
    location: v.optional(locationSample),
  },
  returns: v.null(),
  handler: async (ctx, args) => {
    const player = await authenticatePlayer(ctx, args.matchId, args.playerId, args.sessionSecret);
    const now = Date.now();
    await ctx.db.patch(player._id, {
      connected: true,
      lastSeenAt: now,
      ...(player.lifeState === "disconnected" && player.health > 0 ? { lifeState: "alive" as const } : {}),
    });
    return null;
  },
});

/** Restore a killed player exactly once after the server-owned delay. */
export const respawn = internalMutation({
  args: {
    playerId: v.id("players"),
    expectedRespawnAt: v.number(),
  },
  returns: v.null(),
  handler: async (ctx, args) => {
    const player = await ctx.db.get(args.playerId);
    if (player === null) {
      return null;
    }
    const match = await ctx.db.get(player.matchId);
    if (match === null) {
      return null;
    }

    const now = Date.now();
    const patch = planRespawn(
      toMatchState(match).phase,
      toPlayerState(player),
      args.expectedRespawnAt,
      now,
    );
    if (patch === null) {
      return null;
    }

    await ctx.db.patch(player._id, patch);
    await appendEvent(ctx, {
      matchId: match._id,
      type: "respawned",
      actorPlayerId: player._id,
      targetPlayerId: null,
      zone: null,
      damage: null,
      message: `${player.displayName} RESPAWNED`,
      createdAt: now,
    });
    return null;
  },
});
