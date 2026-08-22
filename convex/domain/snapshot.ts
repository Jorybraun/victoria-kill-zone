import { hasExpired, phaseForStatus } from "./lifecycle.js";
import type {
  HitZone,
  MatchPhase,
  MatchState,
  MatchStatus,
  PlayerLifeState,
  PlayerRole,
  PlayerState,
} from "./types.js";

/**
 * Public snapshots are allow-listed field by field. Session hashes, session
 * secrets, and device identifiers are never part of a snapshot type, so a new
 * stored field cannot leak by accident.
 */
export interface SpectatorPlayer {
  id: string;
  displayName: string;
  role: PlayerRole;
  connected: boolean;
  lifeState: PlayerLifeState;
  health: number;
  ammo: number;
  kills: number;
  deaths: number;
  damageDealt: number;
  shotsFired: number;
  shotsHit: number;
  headshots: number;
  respawnInMs: number | null;
}

export interface SpectatorEvent {
  id: string;
  type: string;
  actorDisplayName: string | null;
  targetDisplayName: string | null;
  zone: HitZone | null;
  damage: number | null;
  message: string;
  createdAt: number;
}

export interface SpectatorSnapshot {
  matchId: string;
  code: string;
  status: MatchStatus;
  phase: MatchPhase;
  arena: { centerLatitude: number; centerLongitude: number; radiusMeters: number };
  startedAt: number | null;
  endsAt: number | null;
  remainingMs: number | null;
  winnerPlayerId: string | null;
  players: SpectatorPlayer[];
  events: SpectatorEvent[];
  generatedAt: number;
}

export interface SnapshotMatch extends MatchState {
  id: string;
  code: string;
  centerLatitude: number;
  centerLongitude: number;
}

export interface SnapshotEvent {
  id: string;
  type: string;
  actorPlayerId: string | null;
  targetPlayerId: string | null;
  zone: HitZone | null;
  damage: number | null;
  message: string;
  createdAt: number;
}

/**
 * Build the read-only spectator projection. An `active` duel whose `endsAt` has
 * passed is reported as `ended` so a delayed finish job cannot show a live duel.
 */
export function buildSpectatorSnapshot(
  match: SnapshotMatch,
  players: readonly PlayerState[],
  events: readonly SnapshotEvent[],
  now: number,
): SpectatorSnapshot {
  const expired = hasExpired(match, now);
  const status: MatchStatus = expired ? "ended" : match.status;
  const endReason = expired && match.endReason === null ? "duration_elapsed" : match.endReason;
  const names = new Map(players.map((player) => [player.id, player.displayName]));

  return {
    matchId: match.id,
    code: match.code,
    status,
    phase: phaseForStatus({ status, endReason }),
    arena: {
      centerLatitude: match.centerLatitude,
      centerLongitude: match.centerLongitude,
      radiusMeters: match.radiusMeters,
    },
    startedAt: match.startedAt,
    endsAt: match.endsAt,
    remainingMs: match.endsAt === null ? null : Math.max(0, match.endsAt - now),
    winnerPlayerId: match.winnerPlayerId,
    players: players.map((player) => ({
      id: player.id,
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
      respawnInMs: player.respawnAt === null ? null : Math.max(0, player.respawnAt - now),
    })),
    events: events.map((event) => ({
      id: event.id,
      type: event.type,
      actorDisplayName: event.actorPlayerId === null ? null : names.get(event.actorPlayerId) ?? null,
      targetDisplayName: event.targetPlayerId === null ? null : names.get(event.targetPlayerId) ?? null,
      zone: event.zone,
      damage: event.damage,
      message: event.message,
      createdAt: event.createdAt,
    })),
    generatedAt: now,
  };
}
