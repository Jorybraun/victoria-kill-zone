import {
  ARENA_RADIUS_MAX_METERS,
  ARENA_RADIUS_MIN_METERS,
  COUNTDOWN_MS,
  DISPLAY_NAME_MAX_SCALARS,
  INITIAL_AMMO,
  INITIAL_HEALTH,
  MATCH_CODE_ALPHABET,
  MATCH_CODE_INPUT_ALPHABET,
  MATCH_CODE_LENGTH,
  MATCH_DURATION_MS,
  PLAYER_CAPACITY,
  type MatchPhase,
  type PlayerRole,
} from "./contract.js";
import { isJoinable, isTerminal } from "./lifecycle.js";
import { isPresent } from "./presence.js";
import { ok, rejected, type DomainResult } from "./result.js";

/** Lobby view of a stored player: the only player fields lifecycle rules read. */
export interface LobbyPlayer {
  readonly id: string;
  readonly role: PlayerRole;
  readonly ready: boolean;
  readonly connected: boolean;
  readonly lastSeenAt: number;
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
  readonly lastSeenAt: number;
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
}

/**
 * Trim surrounding Unicode whitespace and change nothing else.
 *
 * Internal characters — including runs of spaces, emoji, and combining marks —
 * are preserved, and an overlong name is rejected rather than truncated, so a
 * player never sees a silently different name than the one they typed.
 */
export function normalizeDisplayName(value: string): string {
  return value.trim();
}

/** Unicode scalar values, so an emoji or surrogate pair counts once. */
export function displayNameLength(value: string): number {
  return [...normalizeDisplayName(value)].length;
}

export function isValidDisplayName(value: string): boolean {
  const length = displayNameLength(value);
  return length >= 1 && length <= DISPLAY_NAME_MAX_SCALARS;
}

/**
 * Uppercase and drop the separators a human types, without truncating.
 *
 * Only ASCII whitespace and hyphens are separators. Any other character is
 * malformed input, and length is a validation concern rather than a
 * normalization one: truncating would silently resolve a different duel.
 */
export function normalizeMatchCode(value: string): string {
  return value.toUpperCase().replace(/[ \t\n\v\f\r-]/g, "");
}

/**
 * Every scalar a duel code may be typed with, before any case folding.
 *
 * Unicode uppercasing is not injective into ASCII — `ſ` becomes `S`, `ı`
 * becomes `I`, and `ß` becomes `SS` — so a forbidden scalar could otherwise
 * launder itself into a valid code, or even into a valid length. The raw input
 * is therefore checked first and only ASCII survives.
 */
const MATCH_CODE_TYPED_SCALARS = /^[A-Za-z0-9 \t\n\v\f\r-]*$/u;

/** True only for exactly {@link MATCH_CODE_LENGTH} typed-alphabet characters. */
export function isValidMatchCode(value: string): boolean {
  if (!MATCH_CODE_TYPED_SCALARS.test(value)) {
    return false;
  }

  const normalized = normalizeMatchCode(value);
  if (normalized.length !== MATCH_CODE_LENGTH) {
    return false;
  }

  return [...normalized].every((character) => MATCH_CODE_INPUT_ALPHABET.includes(character));
}

/** A radius is a finite measurement; NaN and infinity are malformed shape. */
export function isFiniteArenaRadius(meters: number): boolean {
  return Number.isFinite(meters);
}

/**
 * Round to the nearest whole metre and clamp to the playable range.
 *
 * Only finite input has a meaning to round, so a non-finite request is rejected
 * rather than coerced into a playable arena the caller never asked for: a duel
 * fought inside a silently invented geofence is worse than a failed create.
 */
export function normalizeArenaRadius(meters: number): DomainResult<number> {
  if (!isFiniteArenaRadius(meters)) {
    return rejected("INVALID_ARENA_RADIUS");
  }

  return ok(
    Math.min(ARENA_RADIUS_MAX_METERS, Math.max(ARENA_RADIUS_MIN_METERS, Math.round(meters))),
  );
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

function newPlayer(
  displayName: string,
  role: PlayerRole,
  now: number,
): PlayerDraft {
  return {
    displayName,
    role,
    ready: false,
    connected: true,
    health: INITIAL_HEALTH,
    ammo: INITIAL_AMMO,
    lastSeenAt: now,
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

  const arenaRadiusMeters = normalizeArenaRadius(request.arenaRadiusMeters);
  if (!arenaRadiusMeters.ok) {
    return rejected(arenaRadiusMeters.code);
  }

  return ok({
    match: {
      code: request.code,
      phase: "lobby",
      arenaRadiusMeters: arenaRadiusMeters.value,
      durationMs: MATCH_DURATION_MS,
      createdAt: request.now,
    },
    host: newPlayer(
      normalizeDisplayName(request.displayName),
      "host",
      request.now,
    ),
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
    message: `${request.displayName} ${request.isReady ? "READY" : "NOT READY"}`,
  });
}

/**
 * Host-only start. The duel begins only with exactly two ready players whose
 * presence is still fresh, and the server alone owns the countdown timestamp.
 * `endsAt` belongs to activation, not to the countdown.
 */
export function planStartMatch(request: {
  readonly phase: MatchPhase;
  readonly actorRole: PlayerRole;
  readonly players: readonly LobbyPlayer[];
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

  if (request.players.some((player) => !isPresent(player, request.now))) {
    return rejected("PLAYERS_NOT_CONNECTED");
  }

  if (request.players.some((player) => !player.ready)) {
    return rejected("PLAYERS_NOT_READY");
  }

  return ok({
    phase: "countdown",
    startsAt: request.now + COUNTDOWN_MS,
  });
}
