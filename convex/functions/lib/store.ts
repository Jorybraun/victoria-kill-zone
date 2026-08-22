import { ConvexError } from "convex/values";
import type { ErrorCode } from "../../domain/contract.js";
import { resolvePhase } from "../../domain/lifecycle.js";
import type { LobbyPlayer } from "../../domain/match.js";
import { isValidMatchCode, normalizeMatchCode } from "../../domain/match.js";
import { authenticates } from "../../domain/session.js";
import type { Doc, Id, MutationCtx, QueryCtx } from "./server.js";

/**
 * Stable error codes cross the wire as `ConvexError({ code })`; raw messages and
 * stack traces never reach a client.
 */
export function fail(code: ErrorCode): never {
  throw new ConvexError({ code });
}

export function toLobbyPlayer(player: Doc<"players">): LobbyPlayer {
  return {
    id: player._id,
    role: player.role,
    ready: player.ready,
    connected: player.connected,
  };
}

export async function listPlayers(
  ctx: MutationCtx | QueryCtx,
  matchId: Id<"matches">,
): Promise<Doc<"players">[]> {
  const players = await ctx.db
    .query("players")
    .withIndex("by_match", (q) => q.eq("matchId", matchId))
    .collect();

  return players.sort((left, right) => left.joinedAt - right.joinedAt);
}

export async function matchByCode(
  ctx: MutationCtx | QueryCtx,
  code: string,
): Promise<Doc<"matches"> | null> {
  const normalized = normalizeMatchCode(code);
  if (!isValidMatchCode(normalized)) {
    return null;
  }

  return await ctx.db
    .query("matches")
    .withIndex("by_code", (q) => q.eq("code", normalized))
    .unique();
}

/**
 * Persist a time-based phase advance so stored and resolved state agree. Reads
 * still resolve the phase from server time, so this is an optimization of the
 * record rather than the source of truth.
 */
export async function advancePhase(
  ctx: MutationCtx,
  match: Doc<"matches">,
  now: number,
): Promise<Doc<"matches">> {
  const phase = resolvePhase(match, now);
  if (phase === match.phase) {
    return match;
  }

  await ctx.db.patch(match._id, { phase });
  return { ...match, phase };
}

/**
 * Authenticate a match-scoped player session. The player must belong to the
 * match and the supplied secret must hash to that player's stored digest, so
 * one player's secret can never drive the opponent.
 */
export async function authenticatePlayer(
  ctx: MutationCtx | QueryCtx,
  args: { matchId: string; playerId: string; sessionSecret: string },
): Promise<{ match: Doc<"matches">; player: Doc<"players"> }> {
  const matchId = ctx.db.normalizeId("matches", args.matchId);
  const match = matchId === null ? null : await ctx.db.get(matchId);
  if (match === null) {
    fail("MATCH_NOT_FOUND");
  }

  const playerId = ctx.db.normalizeId("players", args.playerId);
  const player = playerId === null ? null : await ctx.db.get(playerId);
  if (player === null || player.matchId !== match._id) {
    fail("INVALID_SESSION");
  }

  if (!authenticates(args.sessionSecret, player.sessionHash)) {
    fail("INVALID_SESSION");
  }

  return { match, player };
}
