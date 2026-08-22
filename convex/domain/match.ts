import {
  ARENA_RADIUS_MAX_METERS,
  ARENA_RADIUS_MIN_METERS,
  COUNTDOWN_MS,
  DISPLAY_NAME_MAX_LENGTH,
  INITIAL_AMMO,
  INITIAL_HEALTH,
  MATCH_CODE_ALPHABET,
  MATCH_CODE_LENGTH,
  MATCH_DURATION_MS,
  PLAYER_CAPACITY,
  type MatchPhase,
  type PlayerRole,
} from "./contract.js";
import { isJoinable, isTerminal } from "./lifecycle.js";
import { ok, rejected, type DomainResult } from "./result.js";

/** Lobby view of a stored player: the only player fields lifecycle rules read. */
export interface LobbyPlayer {
  readonly id: string;
  readonly role: PlayerRole;
  readonly ready: boolean;
  readonly connected: boolean;
}

export interface MatchDraft {
  readonly code: string;
  readonly phase: MatchPhase;
  readonly arenaRadiusMeters: number;
  readonly durationMs: number;
  readonly createdAt: number;
}

export interface PlayerDraft {
  readonly displayName: string;
  readonly role: PlayerRole;
  readonly ready: boolean;
  readonly connected: boolean;
  readonly health: number;
  readonly ammo: number;
  readonly joinedAt: number;
}

export interface CreateMatchPlan {
  readonly match: MatchDraft;
  readonly host: PlayerDraft;
  readonly message: string;
}

export interface JoinMatchPlan {
  readonly guest: PlayerDraft;
  readonly message: string;
}

export interface StartMatchPlan {
  readonly phase: "countdown";
  readonly startsAt: number;
  readonly endsAt: number;
  readonly message: string;
}

export function normalizeDisplayName(value: string): string {
  return value.trim().replace(/\s+/g, " ").slice(0, DISPLAY_NAME_MAX_LENGTH);
}

export function isValidDisplayName(value: string): boolean {
  return normalizeDisplayName(value).length > 0;
}

export function normalizeMatchCode(value: string): string {
  return value
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, "")
    .slice(0, MATCH_CODE_LENGTH);
}

export function isValidMatchCode(value: string): boolean {
  return normalizeMatchCode(value).length === MATCH_CODE_LENGTH;
}

export function normalizeArenaRadius(meters: number): number {
  if (!Number.isFinite(meters)) {
    return ARENA_RADIUS_MIN_METERS;
  }

  return Math.min(ARENA_RADIUS_MAX_METERS, Math.max(ARENA_RADIUS_MIN_METERS, Math.round(meters)));
}

/** Deterministic given its random bytes, so code allocation stays testable. */
export function matchCodeFromBytes(bytes: Uint8Array): string {
  let code = "";
  for (let index = 0; index < MATCH_CODE_LENGTH; index += 1) {
    const byte = bytes[index % bytes.length] ?? 0;
    code += MATCH_CODE_ALPHABET[byte % MATCH_CODE_ALPHABET.length];
  }

  return code;
}

function newPlayer(displayName: string, role: PlayerRole, now: number): PlayerDraft {
  return {
    displayName,
    role,
    ready: false,
    connected: true,
    health: INITIAL_HEALTH,
    ammo: INITIAL_AMMO,
    joinedAt: now,
  };
}

export function planCreateMatch(request: {
  readonly displayName: string;
  readonly arenaRadiusMeters: number;
  readonly code: string;
  readonly now: number;
}): DomainResult<CreateMatchPlan> {
  if (!isValidDisplayName(request.displayName)) {
    return rejected("INVALID_DISPLAY_NAME");
  }

  return ok({
    match: {
      code: request.code,
      phase: "lobby",
      arenaRadiusMeters: normalizeArenaRadius(request.arenaRadiusMeters),
      durationMs: MATCH_DURATION_MS,
      createdAt: request.now,
    },
    host: newPlayer(normalizeDisplayName(request.displayName), "host", request.now),
    message: `${normalizeDisplayName(request.displayName)} JOINED`,
  });
}

export function planJoinMatch(request: {
  readonly displayName: string;
  readonly code: string;
  readonly phase: MatchPhase;
  readonly players: readonly LobbyPlayer[];
  readonly now: number;
}): DomainResult<JoinMatchPlan> {
  if (!isValidDisplayName(request.displayName)) {
    return rejected("INVALID_DISPLAY_NAME");
  }

  if (!isValidMatchCode(request.code)) {
    return rejected("INVALID_CODE");
  }

  if (!isJoinable(request.phase)) {
    return rejected("MATCH_ALREADY_STARTED");
  }

  if (request.players.length >= PLAYER_CAPACITY) {
    return rejected("MATCH_FULL");
  }

  const displayName = normalizeDisplayName(request.displayName);

  return ok({
    guest: newPlayer(displayName, "guest", request.now),
    message: `${displayName} JOINED`,
  });
}

export function planSetReady(request: {
  readonly phase: MatchPhase;
  readonly displayName: string;
  readonly isReady: boolean;
}): DomainResult<{ readonly ready: boolean; readonly message: string }> {
  if (request.phase !== "lobby") {
    return rejected("MATCH_ALREADY_STARTED");
  }

  return ok({
    ready: request.isReady,
    message: `${request.displayName} IS ${request.isReady ? "READY" : "NOT READY"}`,
  });
}

/**
 * Host-only start. The duel begins only with exactly two ready, connected
 * players, and the server alone owns the countdown and end timestamps.
 */
export function planStartMatch(request: {
  readonly phase: MatchPhase;
  readonly actorRole: PlayerRole;
  readonly players: readonly LobbyPlayer[];
  readonly durationMs: number;
  readonly now: number;
}): DomainResult<StartMatchPlan> {
  if (request.actorRole !== "host") {
    return rejected("HOST_ONLY");
  }

  if (request.phase !== "lobby" || isTerminal(request.phase)) {
    return rejected("MATCH_ALREADY_STARTED");
  }

  if (request.players.length !== PLAYER_CAPACITY) {
    return rejected("PLAYERS_NOT_READY");
  }

  if (request.players.some((player) => !player.connected)) {
    return rejected("PLAYERS_NOT_CONNECTED");
  }

  if (request.players.some((player) => !player.ready)) {
    return rejected("PLAYERS_NOT_READY");
  }

  const startsAt = request.now + COUNTDOWN_MS;

  return ok({
    phase: "countdown",
    startsAt,
    endsAt: startsAt + request.durationMs,
    message: "DUEL STARTED",
  });
}
