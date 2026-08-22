import { v } from "convex/values";
import type { MatchSnapshot, SpectatorSnapshot } from "../domain/snapshot.js";
import { buildMatchSnapshot, buildSpectatorSnapshot } from "../domain/snapshot.js";
import { query } from "./lib/server.js";
import { authenticatePlayer, listEvents, listPlayers, matchByCode, toStoredEvent, toStoredMatch, toStoredPlayer } from "./lib/store.js";

/** `queries:matchSnapshot` — authenticated, player-scoped authoritative state. */
export const matchSnapshot = query({
  args: { matchId: v.string(), playerId: v.string(), sessionSecret: v.string() },
  handler: async (ctx, args): Promise<MatchSnapshot> => {
    const now = Date.now();
    const { match, player } = await authenticatePlayer(ctx, args);

    return buildMatchSnapshot({
      match: toStoredMatch(match),
      localPlayerId: player._id,
      players: (await listPlayers(ctx, match._id)).map(toStoredPlayer),
      events: (await listEvents(ctx, match._id)).map(toStoredEvent),
      now,
    });
  },
});

/**
 * `queries:spectatorSnapshot` — deliberately public and sanitized. It exposes no
 * session material, device identity, location, targeting evidence, or mutation
 * capability, and returns `null` for an unknown code.
 */
export const spectatorSnapshot = query({
  args: { code: v.string() },
  handler: async (ctx, args): Promise<SpectatorSnapshot | null> => {
    const now = Date.now();
    const match = await matchByCode(ctx, args.code);
    if (match === null) {
      return null;
    }

    return buildSpectatorSnapshot({
      match: toStoredMatch(match),
      players: (await listPlayers(ctx, match._id)).map(toStoredPlayer),
      events: (await listEvents(ctx, match._id)).map(toStoredEvent),
      now,
    });
  },
});
