import { v } from "convex/values";
import {
  buildMatchSnapshot,
  buildSpectatorSnapshot,
  type MatchSnapshot,
  type SnapshotEvent,
  type SnapshotMatch,
  type SpectatorSnapshot,
} from "../domain/snapshot.js";
import { query, type Doc, type QueryCtx } from "./lib/server.js";
import {
  authenticatePlayer,
  fail,
  listPlayers,
  loadMatchByCode,
  toMatchState,
  toPlayerState,
} from "./lib/state.js";

const RECENT_EVENT_LIMIT = 40;

/** Authenticated phone projection used by both live players. */
export const matchSnapshot = query({
  args: {
    matchId: v.id("matches"),
    playerId: v.id("players"),
    sessionSecret: v.string(),
  },
  handler: async (ctx, args): Promise<MatchSnapshot> => {
    const localPlayer = await authenticatePlayer(ctx, args.matchId, args.playerId, args.sessionSecret);
    const match = await ctx.db.get(args.matchId);
    if (match === null) {
      fail("MATCH_NOT_FOUND");
    }

    const [players, events] = await Promise.all([
      listPlayers(ctx, match._id),
      recentEvents(ctx, match._id),
    ]);
    return buildMatchSnapshot(
      snapshotMatch(match),
      localPlayer._id,
      players.map(toPlayerState),
      events,
      Date.now(),
    );
  },
});

/** Public, read-only projection with no session or precise location material. */
export const spectatorSnapshot = query({
  args: { code: v.string() },
  handler: async (ctx, args): Promise<SpectatorSnapshot | null> => {
    const match = await loadMatchByCode(ctx, args.code);
    if (match === null) {
      return null;
    }

    const [players, events] = await Promise.all([
      listPlayers(ctx, match._id),
      recentEvents(ctx, match._id),
    ]);
    return buildSpectatorSnapshot(
      snapshotMatch(match),
      players.map(toPlayerState),
      events,
      Date.now(),
    );
  },
});

function snapshotMatch(match: Doc<"matches">): SnapshotMatch {
  return {
    ...toMatchState(match),
    id: match._id,
    code: match.code,
    centerLatitude: match.centerLatitude,
    centerLongitude: match.centerLongitude,
    arenaCenterAt: match.arenaCenterAt ?? null,
  };
}

async function recentEvents(ctx: QueryCtx, matchId: Doc<"matches">["_id"]): Promise<SnapshotEvent[]> {
  const events = await ctx.db
    .query("events")
    .withIndex("by_match_and_created_at", (q) => q.eq("matchId", matchId))
    .order("desc")
    .take(RECENT_EVENT_LIMIT);

  return events.map((event) => ({
    id: event._id,
    type: event.type,
    ...(event.clientShotId === undefined ? {} : { clientShotId: event.clientShotId }),
    actorPlayerId: event.actorPlayerId,
    targetPlayerId: event.targetPlayerId,
    zone: event.zone,
    damage: event.damage,
    targetConfirmed: event.targetConfirmed ?? null,
    message: event.message,
    createdAt: event.createdAt,
  }));
}
