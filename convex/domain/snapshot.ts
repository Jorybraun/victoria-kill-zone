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
}

export type SpectatorPlayerSnapshot = Omit<PlayerSnapshot, "lastSeenAt">;

export interface EventSnapshot {
  id: string;
  type: string;
  message: string;
  createdAt: number;
  actorPlayerId?: string;
  targetPlayerId?: string;
  zone?: HitZone;
  damage?: number;
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
    players: orderedPlayers(players).map(projectPlayer),
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
    players: orderedPlayers(players).map(projectSpectatorPlayer),
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

function projectPlayer(player: PlayerState): PlayerSnapshot {
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
    arenaState: player.arenaState,
    lastSeenAt: player.lastSeenAt,
    ...(player.lastShotAt === null ? {} : { lastShotAt: player.lastShotAt }),
    ...(player.respawnAt === null ? {} : { respawnAt: player.respawnAt }),
  };
}

function projectSpectatorPlayer(player: PlayerState): SpectatorPlayerSnapshot {
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
    arenaState: player.arenaState,
    ...(player.lastShotAt === null ? {} : { lastShotAt: player.lastShotAt }),
    ...(player.respawnAt === null ? {} : { respawnAt: player.respawnAt }),
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
