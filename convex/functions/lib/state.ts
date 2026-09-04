import { ConvexError, v } from "convex/values";
import { normalizeMatchCode } from "../../domain/config.js";
import type { ArenaGeometry } from "../../domain/geofence.js";
import { authenticates } from "../../domain/session.js";
import type { MatchPhase, MatchState, PlayerState, RejectReason } from "../../domain/types.js";
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
    ready: player.ready ?? false,
    connected: player.connected,
    lifeState: player.lifeState,
    arenaState: player.arenaState ?? "inside",
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
    latitude: player.latitude ?? null,
    longitude: player.longitude ?? null,
    headingDegrees: player.headingDegrees ?? null,
    locationAccuracyMeters: player.locationAccuracyMeters ?? null,
    locationAt: player.locationAt ?? null,
    outsideStreak: player.outsideStreak ?? 0,
  };
}

/**
 * Arena geometry for geofence evaluation. `null` for a legacy centerless
 * match: its fence is unenforceable, so heartbeats never derive `inside` and
 * debug fire stays ungated per the migration rule.
 */
export function arenaGeometryOf(match: Doc<"matches">): ArenaGeometry | null {
  if (match.arenaCenterAt === undefined || match.arenaCenterAt === null) {
    return null;
  }
  return {
    latitude: match.centerLatitude,
    longitude: match.centerLongitude,
    radiusMeters: match.radiusMeters,
  };
}

export function toMatchState(match: Doc<"matches">): MatchState {
  return {
    status: match.status,
    phase: match.phase ?? phaseFromLegacyStatus(match.status),
    hostPlayerId: match.hostPlayerId,
    radiusMeters: match.radiusMeters,
    durationMs: match.durationMs,
    startsAt: match.startsAt ?? match.startedAt,
    endsAt: match.endsAt,
    winnerPlayerId: match.winnerPlayerId,
    endReason: match.endReason,
  };
}

/** Shared wire validator for a phase0.v1 LocationSample argument. */
export const locationSampleValidator = v.object({
  latitude: v.number(),
  longitude: v.number(),
  accuracyMeters: v.number(),
  capturedAtClient: v.number(),
  headingDegrees: v.optional(v.number()),
});

export type BackendErrorCode =
  | "INVALID_DISPLAY_NAME"
  | "INVALID_CODE"
  | "MATCH_NOT_FOUND"
  | "MATCH_FULL"
  | "MATCH_ALREADY_STARTED"
  | "INVALID_SESSION"
  | "PLAYERS_NOT_READY"
  | "PLAYERS_NOT_CONNECTED"
  | "HOST_ONLY"
  | "MATCH_NOT_RUNNING"
  | "CONNECTION_STALE"
  | "SHOOTER_NOT_ALIVE"
  | "OUT_OF_ARENA"
  | "LOCATION_STALE"
  | "INVALID_ARENA"
  | "INVALID_LOCATION"
  | "OUT_OF_AMMO"
  | "FIRE_COOLDOWN"
  | "INVALID_TARGET"
  | "TARGET_NOT_ALIVE"
  | "IDEMPOTENCY_CONFLICT";

const ERROR_BY_REJECT_REASON: Record<RejectReason, BackendErrorCode> = {
  match_not_found: "MATCH_NOT_FOUND",
  match_not_active: "MATCH_NOT_RUNNING",
  match_expired: "MATCH_NOT_RUNNING",
  match_full: "MATCH_FULL",
  match_already_started: "MATCH_ALREADY_STARTED",
  not_a_member: "INVALID_SESSION",
  not_host: "HOST_ONLY",
  opponent_missing: "PLAYERS_NOT_CONNECTED",
  players_not_ready: "PLAYERS_NOT_READY",
  players_not_connected: "PLAYERS_NOT_CONNECTED",
  invalid_session: "INVALID_SESSION",
  shooter_not_alive: "SHOOTER_NOT_ALIVE",
  shooter_disconnected: "CONNECTION_STALE",
  out_of_arena: "OUT_OF_ARENA",
  location_stale: "LOCATION_STALE",
  out_of_ammo: "OUT_OF_AMMO",
  cooldown_active: "FIRE_COOLDOWN",
  invalid_target: "INVALID_TARGET",
  target_not_alive: "TARGET_NOT_ALIVE",
  host_rejected: "INVALID_TARGET",
  duplicate_shot: "IDEMPOTENCY_CONFLICT",
};

/** Thrown contract errors always carry the accepted `{ code }` payload. */
export function fail(reason: BackendErrorCode | RejectReason): never {
  const code = reason in ERROR_BY_REJECT_REASON ? ERROR_BY_REJECT_REASON[reason as RejectReason] : reason;
  throw new ConvexError({ code });
}

export function errorCodeForRejectReason(reason: RejectReason): BackendErrorCode {
  return ERROR_BY_REJECT_REASON[reason];
}

export async function listPlayers(
  ctx: MutationCtx | QueryCtx,
  matchId: Id<"matches">,
): Promise<Doc<"players">[]> {
  const players = await ctx.db
    .query("players")
    .withIndex("by_match", (q) => q.eq("matchId", matchId))
    .collect();

  return players.sort(
    (left, right) =>
      Number(left.role === "guest") - Number(right.role === "guest") ||
      left.joinedAt - right.joinedAt ||
      String(left._id).localeCompare(String(right._id)),
  );
}

/**
 * Authenticate a match-scoped player session: the player must belong to the
 * match and the supplied secret must hash to that player's stored digest. A
 * player's secret therefore cannot control the opponent.
 */
export async function authenticatePlayer(
  ctx: MutationCtx | QueryCtx,
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
  const normalized = normalizeMatchCode(code);
  if (normalized === null) {
    return null;
  }

  return await ctx.db
    .query("matches")
    .withIndex("by_code", (q) => q.eq("code", normalized))
    .unique();
}

export async function appendEvent(
  ctx: MutationCtx,
  event: Omit<Doc<"events">, "_id" | "_creationTime">,
): Promise<Id<"events">> {
  return await ctx.db.insert("events", event);
}

function phaseFromLegacyStatus(status: MatchState["status"]): MatchPhase {
  switch (status) {
    case "setup":
    case "waiting":
      return "lobby";
    case "active":
      return "running";
    case "ended":
      return "finished";
  }
}
