import { v } from "convex/values";
import {
  applyLocationSample,
  isWellFormedLocationSample,
  locationStateFrom,
  type LocationState,
} from "../domain/geofence.js";
import { planRespawn } from "../domain/respawn.js";
import { internalMutation, mutation, type Doc } from "./lib/server.js";
import {
  appendEvent,
  arenaGeometryOf,
  authenticatePlayer,
  fail,
  locationSampleValidator,
  toMatchState,
  toPlayerState,
} from "./lib/state.js";

/**
 * Presence heartbeat and the only writer of authoritative location state. A
 * supplied sample is validated (malformed shapes throw INVALID_LOCATION before
 * any write) and evaluated by the frozen geofence rules against this match's
 * arena; the resulting state overwrites only this player's current
 * match-scoped location fields. `locationAt` is the server receipt time.
 */
export const heartbeat = mutation({
  args: {
    matchId: v.id("matches"),
    playerId: v.id("players"),
    sessionSecret: v.string(),
    location: v.optional(locationSampleValidator),
  },
  returns: v.null(),
  handler: async (ctx, args) => {
    const player = await authenticatePlayer(ctx, args.matchId, args.playerId, args.sessionSecret);
    const now = Date.now();

    let locationPatch: Partial<Doc<"players">> = {};
    if (args.location !== undefined) {
      if (!isWellFormedLocationSample(args.location)) {
        fail("INVALID_LOCATION");
      }
      const match = await ctx.db.get(args.matchId);
      const next = applyLocationSample(
        match === null ? null : arenaGeometryOf(match),
        locationStateFrom(toPlayerState(player)),
        args.location,
        now,
      );
      locationPatch = locationFieldsPatch(next);
    }

    await ctx.db.patch(player._id, {
      connected: true,
      lastSeenAt: now,
      ...(player.lifeState === "disconnected" && player.health > 0 ? { lifeState: "alive" as const } : {}),
      ...locationPatch,
    });
    return null;
  },
});

function locationFieldsPatch(state: LocationState): Partial<Doc<"players">> {
  return {
    arenaState: state.arenaState,
    latitude: state.latitude,
    longitude: state.longitude,
    headingDegrees: state.headingDegrees,
    locationAccuracyMeters: state.accuracyMeters,
    locationAt: state.locationAt,
    outsideStreak: state.outsideStreak,
  };
}

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
