import { GAMEPLAY, normalizeArenaRadius, normalizeDisplayName } from "./config.js";
import { canTransition, isJoinable } from "./lifecycle.js";
import { ok, rejected, type DomainResult } from "./result.js";
import type { MatchState, MatchStatus, PlayerRole, PlayerState, StatePatch } from "./types.js";

const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

/**
 * Build a match code from caller-supplied random bytes. Randomness stays in the
 * function layer so the domain remains deterministic and testable.
 */
export function matchCodeFromBytes(bytes: Uint8Array): string {
  let code = "";
  for (let index = 0; index < GAMEPLAY.matchCodeLength; index += 1) {
    const byte = bytes[index % Math.max(bytes.length, 1)] ?? 0;
    code += CODE_ALPHABET[byte % CODE_ALPHABET.length];
  }

  return code;
}

export interface CreateMatchInput {
  displayName: string;
  centerLatitude: number;
  centerLongitude: number;
  radiusMeters?: number;
  now: number;
}

export interface NewMatch {
  match: {
    code: string;
    status: "setup";
    centerLatitude: number;
    centerLongitude: number;
    radiusMeters: number;
    maxPlayers: number;
    durationMs: number;
    startedAt: null;
    endsAt: null;
    winnerPlayerId: null;
    endReason: null;
    createdAt: number;
    updatedAt: number;
  };
  host: Omit<PlayerState, "id">;
}

/** A freshly created duel starts in `setup` with only the host present. */
export function planCreateMatch(input: CreateMatchInput, code: string): NewMatch {
  return {
    match: {
      code,
      status: "setup" as const,
      centerLatitude: input.centerLatitude,
      centerLongitude: input.centerLongitude,
      radiusMeters: normalizeArenaRadius(input.radiusMeters),
      maxPlayers: GAMEPLAY.maxPlayers,
      durationMs: GAMEPLAY.matchDurationMs,
      startedAt: null,
      endsAt: null,
      winnerPlayerId: null,
      endReason: null,
      createdAt: input.now,
      updatedAt: input.now,
    },
    host: newPlayer(normalizeDisplayName(input.displayName, "Host"), "host", input.now),
  };
}

/** Server-owned starting state for a player record. */
export function newPlayer(displayName: string, role: PlayerRole, now: number): Omit<PlayerState, "id"> {
  return {
    displayName,
    role,
    connected: true,
    lifeState: "alive",
    health: GAMEPLAY.startingHealth,
    ammo: GAMEPLAY.magazineSize,
    kills: 0,
    deaths: 0,
    damageDealt: 0,
    shotsFired: 0,
    shotsHit: 0,
    headshots: 0,
    lastShotAt: null,
    respawnAt: null,
    lastSeenAt: now,
    joinedAt: now,
  };
}

export interface JoinMatchInput {
  displayName: string;
  now: number;
}

export interface JoinPlan {
  guest: Omit<PlayerState, "id">;
  matchPatch: { status: MatchStatus; updatedAt: number };
}

/**
 * Only a duel in `setup` accepts a second player; the two-player limit and the
 * `setup -> waiting` transition are enforced here rather than by the client.
 */
export function planJoinMatch(
  match: Pick<MatchState, "status">,
  playerCount: number,
  input: JoinMatchInput,
): DomainResult<JoinPlan> {
  if (match.status === "active" || match.status === "ended") {
    return rejected("match_already_started");
  }

  if (!isJoinable(match, playerCount, GAMEPLAY.maxPlayers)) {
    return rejected("match_full");
  }

  return ok({
    guest: newPlayer(normalizeDisplayName(input.displayName, "Challenger"), "guest", input.now),
    matchPatch: { status: "waiting" as const, updatedAt: input.now },
  });
}

export interface StartPlan {
  matchPatch: { status: "active"; startedAt: number; endsAt: number; updatedAt: number };
  playerResetPatch: StatePatch<PlayerState>;
}

/**
 * Host-only start. Requires exactly two connected players and a duel that is
 * `waiting`; the server owns `startedAt`/`endsAt` so clients cannot extend a duel.
 */
export function planStartMatch(
  match: Pick<MatchState, "status" | "hostPlayerId" | "durationMs">,
  players: readonly PlayerState[],
  requesterId: string,
  now: number,
): DomainResult<StartPlan> {
  if (match.hostPlayerId !== requesterId) {
    return rejected("not_host");
  }

  if (match.status === "active" || match.status === "ended") {
    return rejected("match_already_started");
  }

  if (players.length !== GAMEPLAY.maxPlayers || players.some((player) => !player.connected)) {
    return rejected("opponent_missing");
  }

  if (!canTransition(match.status, "active")) {
    return rejected("match_not_active");
  }

  return ok({
    matchPatch: {
      status: "active" as const,
      startedAt: now,
      endsAt: now + match.durationMs,
      updatedAt: now,
    },
    playerResetPatch: {
      lifeState: "alive",
      health: GAMEPLAY.startingHealth,
      ammo: GAMEPLAY.magazineSize,
      lastShotAt: null,
      respawnAt: null,
    },
  });
}
