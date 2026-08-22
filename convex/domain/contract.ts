/**
 * Server-side mirror of the frozen G2 network interface contract
 * (`docs/interface-contracts.md`). Nothing here may drift: a wire name, enum,
 * constant, required field, authentication rule, or idempotency key change
 * requires an integration-owned contract revision.
 */

export const PLAYER_CAPACITY = 2;
export const MATCH_CODE_LENGTH = 6;
export const INITIAL_HEALTH = 100;
export const INITIAL_AMMO = 8;
export const DEBUG_TORSO_DAMAGE = 34;
export const COUNTDOWN_MS = 3_000;

/** Server-owned duel length; clients read it as `MatchSummary.durationMs`. */
export const MATCH_DURATION_MS = 180_000;

export const ARENA_RADIUS_MIN_METERS = 20;
export const ARENA_RADIUS_MAX_METERS = 60;
export const ARENA_RADIUS_DEFAULT_METERS = 30;

export const DISPLAY_NAME_MAX_LENGTH = 24;

/** Ambiguous glyphs are excluded so a spoken or typed code stays unique. */
export const MATCH_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

export type MatchPhase = "lobby" | "countdown" | "running" | "finished" | "cancelled";

export type PlayerRole = "host" | "guest";

export type EventType = "joined" | "ready" | "started" | "hit";

export type HitZone = "torso";

export type ErrorCode =
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
  | "CONNECTION_STALE";

/** Match-scoped capability handed to the phone that created or joined a duel. */
export interface PlayerSession {
  matchId: string;
  code: string;
  playerId: string;
  sessionSecret: string;
}
