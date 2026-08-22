import type { EventType, HitZone, MatchPhase, PlayerRole } from "./contract.js";
import { resolvePhase, type MatchTiming } from "./lifecycle.js";

/**
 * Snapshot projections for `queries:matchSnapshot` and the deliberately public
 * `queries:spectatorSnapshot`.
 *
 * Both projections are allow-lists built field by field: a session digest,
 * device identifier, location, or targeting record cannot leak by adding a
 * stored column.
 */

export interface MatchSummary {
  id: string;
  code: string;
  phase: MatchPhase;
  durationMs: number;
  startsAt?: number;
  endsAt?: number;
}

export interface PlayerSnapshot {
  id: string;
  displayName: string;
  role: PlayerRole;
  ready: boolean;
  connected: boolean;
  health: number;
  ammo: number;
}

export interface EventSnapshot {
  id: string;
  type: EventType;
  message: string;
  createdAt: number;
  actorPlayerId?: string;
  targetPlayerId?: string;
  zone?: HitZone;
  damage?: number;
}

export interface MatchSnapshot {
  serverNow: number;
  match: MatchSummary;
  localPlayerId: string;
  players: PlayerSnapshot[];
  events: EventSnapshot[];
}

export interface SpectatorSnapshot {
  serverNow: number;
  match: MatchSummary;
  players: PlayerSnapshot[];
  events: EventSnapshot[];
}

/** Stored shapes the projections read; only these fields are ever consulted. */
export interface StoredMatch extends MatchTiming {
  readonly id: string;
  readonly code: string;
  readonly durationMs: number;
}

export interface StoredPlayer {
  readonly id: string;
  readonly displayName: string;
  readonly role: PlayerRole;
  readonly ready: boolean;
  readonly connected: boolean;
  readonly health: number;
  readonly ammo: number;
}

export interface StoredEvent {
  readonly id: string;
  readonly type: EventType;
  readonly message: string;
  readonly createdAt: number;
  readonly actorPlayerId?: string;
  readonly targetPlayerId?: string;
  readonly zone?: HitZone;
  readonly damage?: number;
}

export function matchSummary(match: StoredMatch, now: number): MatchSummary {
  const summary: MatchSummary = {
    id: match.id,
    code: match.code,
    phase: resolvePhase(match, now),
    durationMs: match.durationMs,
  };

  return {
    ...summary,
    ...(match.startsAt === undefined ? {} : { startsAt: match.startsAt }),
    ...(match.endsAt === undefined ? {} : { endsAt: match.endsAt }),
  };
}

function playerSnapshot(player: StoredPlayer): PlayerSnapshot {
  return {
    id: player.id,
    displayName: player.displayName,
    role: player.role,
    ready: player.ready,
    connected: player.connected,
    health: player.health,
    ammo: player.ammo,
  };
}

function eventSnapshot(event: StoredEvent): EventSnapshot {
  return {
    id: event.id,
    type: event.type,
    message: event.message,
    createdAt: event.createdAt,
    ...(event.actorPlayerId === undefined ? {} : { actorPlayerId: event.actorPlayerId }),
    ...(event.targetPlayerId === undefined ? {} : { targetPlayerId: event.targetPlayerId }),
    ...(event.zone === undefined ? {} : { zone: event.zone }),
    ...(event.damage === undefined ? {} : { damage: event.damage }),
  };
}

/**
 * Newest-first by `createdAt`, then ascending by `id` for equal timestamps.
 *
 * Two writes inside one mutation share a server timestamp, so the id tiebreak is
 * what makes the feed a total order: every subscriber sees the same sequence and
 * can de-duplicate a replayed page by id.
 */
function eventFeed(events: readonly StoredEvent[]): EventSnapshot[] {
  return [...events]
    .sort((left, right) =>
      left.createdAt === right.createdAt
        ? left.id < right.id
          ? -1
          : left.id > right.id
            ? 1
            : 0
        : right.createdAt - left.createdAt,
    )
    .map((event) => eventSnapshot(event));
}

function playerFeed(players: readonly StoredPlayer[]): PlayerSnapshot[] {
  return [...players]
    .sort((left, right) => (left.role === right.role ? 0 : left.role === "host" ? -1 : 1))
    .map((player) => playerSnapshot(player));
}

export function buildMatchSnapshot(input: {
  readonly match: StoredMatch;
  readonly localPlayerId: string;
  readonly players: readonly StoredPlayer[];
  readonly events: readonly StoredEvent[];
  readonly now: number;
}): MatchSnapshot {
  return {
    serverNow: input.now,
    match: matchSummary(input.match, input.now),
    localPlayerId: input.localPlayerId,
    players: playerFeed(input.players),
    events: eventFeed(input.events),
  };
}

export function buildSpectatorSnapshot(input: {
  readonly match: StoredMatch;
  readonly players: readonly StoredPlayer[];
  readonly events: readonly StoredEvent[];
  readonly now: number;
}): SpectatorSnapshot {
  return {
    serverNow: input.now,
    match: matchSummary(input.match, input.now),
    players: playerFeed(input.players),
    events: eventFeed(input.events),
  };
}
