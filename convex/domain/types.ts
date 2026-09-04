/**
 * Pure domain vocabulary for the Victoria Kill Zone duel.
 *
 * Nothing in `domain/` may import Convex, Node, or any environment-specific
 * module: the rules are exercised by deterministic unit tests and reused by the
 * Convex function layer in `functions/`.
 */

/**
 * Explicit duel lifecycle.
 *
 * - `setup`: created by the host, no opponent yet.
 * - `waiting`: two players present, awaiting the host start.
 * - `active`: the duel is running until `endsAt`.
 * - `ended`: terminal; the winner is resolved and no gameplay is accepted.
 *
 * Client-facing snapshots also carry the spec-frozen `MatchPhase` projection
 * (`lobby | countdown | running | finished | cancelled`) so iOS and spectator
 * work can consume either vocabulary. See `phaseForStatus`.
 */
export type MatchStatus = "setup" | "waiting" | "active" | "ended";

/** Frozen cross-workstream phase vocabulary from the technical specification. */
export type MatchPhase = "lobby" | "countdown" | "running" | "finished" | "cancelled";

export type PlayerRole = "host" | "guest";

export type PlayerLifeState = "alive" | "dead" | "respawning" | "disconnected";

export type ArenaState = "inside" | "warning" | "uncertain" | "outside";

export type HitZone = "head" | "torso" | "limbs";

export type ShotOutcome = "miss" | "hit" | "kill" | "rejected";

export type EndReason = "duration_elapsed" | "host_ended" | "abandoned";

/**
 * Every reason the server may refuse a gameplay action. Reject reasons are
 * stable strings: clients render copy from them and the shot ledger stores them.
 */
export type RejectReason =
  | "match_not_found"
  | "match_not_active"
  | "match_expired"
  | "match_full"
  | "match_already_started"
  | "not_a_member"
  | "not_host"
  | "opponent_missing"
  | "players_not_ready"
  | "players_not_connected"
  | "invalid_session"
  | "shooter_not_alive"
  | "shooter_disconnected"
  | "out_of_arena"
  | "location_stale"
  | "out_of_ammo"
  | "cooldown_active"
  | "invalid_target"
  | "target_not_alive"
  | "host_rejected"
  | "duplicate_shot";

/** Server-owned match record fields the domain rules read. */
export interface MatchState {
  status: MatchStatus;
  phase: MatchPhase;
  hostPlayerId: string | null;
  radiusMeters: number;
  durationMs: number;
  startsAt: number | null;
  endsAt: number | null;
  winnerPlayerId: string | null;
  endReason: EndReason | null;
}

/** Server-owned player record fields the domain rules read. */
export interface PlayerState {
  id: string;
  displayName: string;
  role: PlayerRole;
  ready: boolean;
  connected: boolean;
  lifeState: PlayerLifeState;
  arenaState: ArenaState;
  health: number;
  ammo: number;
  kills: number;
  deaths: number;
  damageDealt: number;
  shotsFired: number;
  shotsHit: number;
  headshots: number;
  lastShotAt: number | null;
  respawnAt: number | null;
  lastSeenAt: number;
  joinedAt: number;
  // Authoritative geofence state. `locationAt` is server receipt time of the
  // last trusted sample; `capturedAtClient` never becomes authoritative.
  latitude: number | null;
  longitude: number | null;
  headingDegrees: number | null;
  locationAccuracyMeters: number | null;
  locationAt: number | null;
  outsideStreak: number;
}

/** A partial update the function layer applies with `ctx.db.patch`. */
export type StatePatch<T> = Partial<T>;
