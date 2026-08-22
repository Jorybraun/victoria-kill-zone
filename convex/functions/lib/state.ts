import { ConvexError } from "convex/values";
import { authenticates } from "../../domain/session.js";
import type { MatchState, PlayerState, RejectReason } from "../../domain/types.js";
import type { Doc, Id, MutationCtx, QueryCtx } from "./server.js";

/**
 * Mapping between stored documents and the pure domain state. Session and
 * device digests are dropped here, so no rule or snapshot can read them.
 */
export function toPlayerState(player: Doc<"players">): PlayerState {
  return {
    id: player._id,
    displayName: player.displayName,
    role: player.role,
    connected: player.connected,
    lifeState: player.lifeState,
    health: player.health,
    ammo: player.ammo,
    kills: player.kills,
    deaths: player.deaths,
    damageDealt: player.damageDealt,
    shotsFired: player.shotsFired,
    shotsHit: player.shotsHit,
    headshots: player.headshots,
    lastShotAt: player.lastShotAt,
    respawnAt: player.respawnAt,
    lastSeenAt: player.lastSeenAt,
    joinedAt: player.joinedAt,
  };
}

export function toMatchState(match: Doc<"matches">): MatchState {
  return {
    status: match.status,
    hostPlayerId: match.hostPlayerId,
    radiusMeters: match.radiusMeters,
    durationMs: match.durationMs,
    startedAt: match.startedAt,
    endsAt: match.endsAt,
    winnerPlayerId: match.winnerPlayerId,
    endReason: match.endReason,
  };
}

/** Domain rejections surface as `ConvexError` with the stable reason string. */
export function fail(reason: RejectReason): never {
  throw new ConvexError(reason satisfies RejectReason);
}

export async function listPlayers(
  ctx: MutationCtx | QueryCtx,
  matchId: Id<"matches">,
): Promise<Doc<"players">[]> {
  return await ctx.db
    .query("players")
    .withIndex("by_match", (q) => q.eq("matchId", matchId))
    .collect();
}

/**
 * Authenticate a match-scoped player session: the player must belong to the
 * match and the supplied secret must hash to that player's stored digest. A
 * player's secret therefore cannot control the opponent.
 */
export async function authenticatePlayer(
  ctx: MutationCtx,
  matchId: Id<"matches">,
  playerId: Id<"players">,
  sessionSecret: string,
): Promise<Doc<"players">> {
  const player = await ctx.db.get(playerId);
  if (player === null || player.matchId !== matchId) {
    fail("not_a_member");
  }

  if (!authenticates(sessionSecret, player.sessionHash)) {
    fail("invalid_session");
  }

  return player;
}

export async function loadMatchByCode(
  ctx: MutationCtx | QueryCtx,
  code: string,
): Promise<Doc<"matches"> | null> {
  return await ctx.db
    .query("matches")
    .withIndex("by_code", (q) => q.eq("code", code.trim().toUpperCase()))
    .unique();
}
