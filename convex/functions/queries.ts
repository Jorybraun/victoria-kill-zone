import { v } from "convex/values";
import { buildSpectatorSnapshot, type SpectatorSnapshot } from "../domain/snapshot.js";
import { query } from "./lib/server.js";
import { listPlayers, loadMatchByCode, toMatchState, toPlayerState } from "./lib/state.js";

const RECENT_EVENT_LIMIT = 40;

/**
 * Read-only spectator projection.
 *
 * The returned shape is built by the pure `buildSpectatorSnapshot` allow-list,
 * so session digests, session secrets, and device identifiers cannot appear in
 * a public subscription.
 */
export const spectatorSnapshot = query({
  args: { code: v.string() },
  handler: async (ctx, args): Promise<SpectatorSnapshot | null> => {
    const match = await loadMatchByCode(ctx, args.code);
    if (match === null) {
      return null;
    }

    const players = await listPlayers(ctx, match._id);
    const events = await ctx.db
      .query("events")
      .withIndex("by_match_and_created_at", (q) => q.eq("matchId", match._id))
      .order("desc")
      .take(RECENT_EVENT_LIMIT);

    return buildSpectatorSnapshot(
      {
        ...toMatchState(match),
        id: match._id,
        code: match.code,
        centerLatitude: match.centerLatitude,
        centerLongitude: match.centerLongitude,
      },
      players.map(toPlayerState),
      events.map((event) => ({
        id: event._id,
        type: event.type,
        actorPlayerId: event.actorPlayerId,
        targetPlayerId: event.targetPlayerId,
        zone: event.zone,
        damage: event.damage,
        message: event.message,
        createdAt: event.createdAt,
      })),
      Date.now(),
    );
  },
});
