import {
  arenaRelativePosition,
  effectiveArenaState,
  locationStateFrom,
  type ArenaRelativePosition,
} from "./geofence.js";
import { hasExpired } from "./lifecycle.js";
import type {
  ArenaState,
  HitZone,
  MatchPhase,
  MatchState,
  PlayerLifeState,
  PlayerRole,
  PlayerState,
} from "./types.js";

export interface MatchSummarySnapshot {
  id: string;
  code: string;
  phase: MatchPhase;
  durationMs: number;
  startsAt?: number;
  endsAt?: number;
  winnerPlayerId?: string;
}

export interface PlayerSnapshot {
  id: string;
  displayName: string;
  role: PlayerRole;
  ready: boolean;
  connected: boolean;
  health: number;
  ammo: number;
  kills: number;
  deaths: number;
  damageDealt: number;
  shotsFired: number;
  shotsHit: number;
  headshots: number;
  lifeState: PlayerLifeState;
  arenaState: ArenaState;
  lastSeenAt: number;
  lastShotAt?: number;
  respawnAt?: number;
  latitude?: number;
  longitude?: number;
  headingDegrees?: number;
  locationAccuracyMeters?: number;
  locationAt?: number;
}

/**
 * The public spectator projection never carries raw coordinates, accuracy,
 * location timestamps, or presence timestamps — only the sanitized
 * arena-relative position in metres.
 */
export type SpectatorPlayerSnapshot = Omit<
  PlayerSnapshot,
  | "lastSeenAt"
  | "latitude"
  | "longitude"
  | "headingDegrees"
  | "locationAccuracyMeters"
  | "locationAt"
> & { arenaPosition?: ArenaRelativePosition };

export interface EventSnapshot {
  id: string;
  type: string;
  message: string;
  createdAt: number;
  actorPlayerId?: string;
  targetPlayerId?: string;
  zone?: HitZone;
  damage?: number;
  targetConfirmed?: boolean | null;
}

export interface MatchSnapshot {
  serverNow: number;
  match: MatchSummarySnapshot;
  arena: { latitude: number; longitude: number; radiusMeters: number };
  localPlayerId: string;
  players: PlayerSnapshot[];
  events: EventSnapshot[];
}

export interface SpectatorSnapshot {
  serverNow: number;
  match: MatchSummarySnapshot;
  arena: { radiusMeters: number };
  players: SpectatorPlayerSnapshot[];
  events: EventSnapshot[];
}

export interface SnapshotMatch extends MatchState {
  id: string;
  code: string;
  centerLatitude: number;
  centerLongitude: number;
  /** Non-null only when a validated phase0 arenaCenter was captured. */
  arenaCenterAt: number | null;
}

export interface SnapshotEvent {
  id: string;
  type: string;
  actorPlayerId: string | null;
  targetPlayerId: string | null;
  zone: HitZone | null;
  damage: number | null;
  targetConfirmed?: boolean | null;
  message: string;
  createdAt: number;
}

/** Authenticated phone projection: additive phase0 fields retain every G2 field. */
export function buildMatchSnapshot(
  match: SnapshotMatch,
  localPlayerId: string,
  players: readonly PlayerState[],
  events: readonly SnapshotEvent[],
  now: number,
): MatchSnapshot {
  return {
    serverNow: now,
    match: projectMatch(match, now),
    arena: {
      latitude: match.centerLatitude,
      longitude: match.centerLongitude,
      radiusMeters: match.radiusMeters,
    },
    localPlayerId,
    players: orderedPlayers(players).map((player) => projectPlayer(player, match, now)),
    events: orderedEvents(events).map(projectEvent),
  };
}

/** Public spectator projection never contains capability or precise arena data. */
export function buildSpectatorSnapshot(
  match: SnapshotMatch,
  players: readonly PlayerState[],
  events: readonly SnapshotEvent[],
  now: number,
): SpectatorSnapshot {
  return {
    serverNow: now,
    match: projectMatch(match, now),
    arena: { radiusMeters: match.radiusMeters },
    players: orderedPlayers(players).map((player) => projectSpectatorPlayer(player, match, now)),
    events: orderedEvents(events).map(projectEvent),
  };
}

function projectMatch(match: SnapshotMatch, now: number): MatchSummarySnapshot {
  const phase = hasExpired(match, now) ? "finished" : match.phase;
  return {
    id: match.id,
    code: match.code,
    phase,
    durationMs: match.durationMs,
    ...(match.startsAt === null ? {} : { startsAt: match.startsAt }),
    ...(match.endsAt === null ? {} : { endsAt: match.endsAt }),
    ...(match.winnerPlayerId === null ? {} : { winnerPlayerId: match.winnerPlayerId }),
  };
}

/**
 * Authoritative arena state at `now`. A geofenced match (recorded arenaCenter)
 * projects the evaluated effective state so grace and staleness decay are
 * visible without waiting for the next heartbeat; a legacy centerless match
 * keeps its stored pre-geofence state exactly.
 */
function projectedArenaState(player: PlayerState, match: SnapshotMatch, now: number): ArenaState {
  return match.arenaCenterAt === null
    ? player.arenaState
    : effectiveArenaState(locationStateFrom(player), now);
}

function projectPlayer(player: PlayerState, match: SnapshotMatch, now: number): PlayerSnapshot {
  return {
    id: player.id,
    displayName: player.displayName,
    role: player.role,
    ready: player.ready,
    connected: player.connected,
    health: player.health,
    ammo: player.ammo,
    kills: player.kills,
    deaths: player.deaths,
    damageDealt: player.damageDealt,
    shotsFired: player.shotsFired,
    shotsHit: player.shotsHit,
    headshots: player.headshots,
    lifeState: player.lifeState,
    arenaState: projectedArenaState(player, match, now),
    lastSeenAt: player.lastSeenAt,
    ...(player.lastShotAt === null ? {} : { lastShotAt: player.lastShotAt }),
    ...(player.respawnAt === null ? {} : { respawnAt: player.respawnAt }),
    ...(player.latitude === null ? {} : { latitude: player.latitude }),
    ...(player.longitude === null ? {} : { longitude: player.longitude }),
    ...(player.headingDegrees === null ? {} : { headingDegrees: player.headingDegrees }),
    ...(player.locationAccuracyMeters === null
      ? {}
      : { locationAccuracyMeters: player.locationAccuracyMeters }),
    ...(player.locationAt === null ? {} : { locationAt: player.locationAt }),
  };
}

function projectSpectatorPlayer(
  player: PlayerState,
  match: SnapshotMatch,
  now: number,
): SpectatorPlayerSnapshot {
  const hasPosition =
    match.arenaCenterAt !== null && player.latitude !== null && player.longitude !== null;
  return {
    id: player.id,
    displayName: player.displayName,
    role: player.role,
    ready: player.ready,
    connected: player.connected,
    health: player.health,
    ammo: player.ammo,
    kills: player.kills,
    deaths: player.deaths,
    damageDealt: player.damageDealt,
    shotsFired: player.shotsFired,
    shotsHit: player.shotsHit,
    headshots: player.headshots,
    lifeState: player.lifeState,
    arenaState: projectedArenaState(player, match, now),
    ...(player.lastShotAt === null ? {} : { lastShotAt: player.lastShotAt }),
    ...(player.respawnAt === null ? {} : { respawnAt: player.respawnAt }),
    ...(hasPosition && player.latitude !== null && player.longitude !== null
      ? {
          arenaPosition: arenaRelativePosition(
            { latitude: match.centerLatitude, longitude: match.centerLongitude },
            player.latitude,
            player.longitude,
            player.headingDegrees,
          ),
        }
      : {}),
  };
}

function projectEvent(event: SnapshotEvent): EventSnapshot {
  return {
    id: event.id,
    type: event.type,
    message: event.message,
    createdAt: event.createdAt,
    ...(event.actorPlayerId === null ? {} : { actorPlayerId: event.actorPlayerId }),
    ...(event.targetPlayerId === null ? {} : { targetPlayerId: event.targetPlayerId }),
    ...(event.zone === null ? {} : { zone: event.zone }),
    ...(event.damage === null ? {} : { damage: event.damage }),
    ...(event.targetConfirmed === undefined || event.targetConfirmed === null
      ? {}
      : { targetConfirmed: event.targetConfirmed }),
  };
}

function orderedPlayers(players: readonly PlayerState[]): PlayerState[] {
  return [...players].sort(
    (left, right) =>
      Number(left.role === "guest") - Number(right.role === "guest") ||
      left.joinedAt - right.joinedAt ||
      left.id.localeCompare(right.id),
  );
}

function orderedEvents(events: readonly SnapshotEvent[]): SnapshotEvent[] {
  return [...events].sort(
    (left, right) => right.createdAt - left.createdAt || left.id.localeCompare(right.id),
  );
}
