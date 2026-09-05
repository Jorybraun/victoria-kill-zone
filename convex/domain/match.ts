import { GAMEPLAY, normalizeArenaRadius, normalizeDisplayName } from "./config.js";
import { isJoinable } from "./lifecycle.js";
import { ok, rejected, type DomainResult } from "./result.js";
import type {
  ArenaState,
  MatchState,
  MatchStatus,
  PlayerRole,
  PlayerState,
  StatePatch,
} from "./types.js";

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
  /** True only when a validated phase0 arenaCenter sample was captured. */
  hasArenaCenter?: boolean;
  radiusMeters?: number;
  now: number;
}

export interface NewMatch {
  match: {
    code: string;
    status: "setup";
    phase: "lobby";
    centerLatitude: number;
    centerLongitude: number;
    arenaCenterAt: number | null;
    radiusMeters: number;
    maxPlayers: number;
    durationMs: number;
    startsAt: null;
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
      phase: "lobby" as const,
      centerLatitude: input.centerLatitude,
      centerLongitude: input.centerLongitude,
      arenaCenterAt: input.hasArenaCenter === true ? input.now : null,
      radiusMeters: normalizeArenaRadius(input.radiusMeters),
      maxPlayers: GAMEPLAY.maxPlayers,
      durationMs: GAMEPLAY.matchDurationMs,
      startsAt: null,
      endsAt: null,
      winnerPlayerId: null,
      endReason: null,
      createdAt: input.now,
      updatedAt: input.now,
    },
    host: newPlayer(
      normalizeDisplayName(input.displayName, "Host"),
      "host",
      input.now,
      initialArenaState(input.hasArenaCenter === true),
    ),
  };
}

/**
 * phase0.v1: a player in a geofenced match starts `uncertain` with omitted
 * location fields until a trusted fresh sample establishes authoritative state.
 * A legacy centerless (G2 create shape) match has no enforceable fence, so its
 * players keep the pre-geofence `inside` behavior exactly as today.
 */
export function initialArenaState(hasArenaCenter: boolean): ArenaState {
  return hasArenaCenter ? "uncertain" : "inside";
}

/** Server-owned starting state for a player record. */
export function newPlayer(
  displayName: string,
  role: PlayerRole,
  now: number,
  arenaState: ArenaState = "inside",
): Omit<PlayerState, "id"> {
  return {
    displayName,
    role,
    ready: false,
    connected: true,
    lifeState: "alive",
    arenaState,
    health: GAMEPLAY.startingHealth,
    ammo: GAMEPLAY.magazineSize,
    kills: 0,
    deaths: 0,
    damageDealt: 0,
    shotsFired: 0,
    shotsHit: 0,
    headshots: 0,
    lastShotAt: null,
    reloadEndsAt: null,
    respawnAt: null,
    lastSeenAt: now,
    joinedAt: now,
    latitude: null,
    longitude: null,
    headingDegrees: null,
    locationAccuracyMeters: null,
    locationAt: null,
    outsideStreak: 0,
  };
}

export interface JoinMatchInput {
  displayName: string;
  /** True when the match records a validated arenaCenter (see create). */
  hasArenaCenter?: boolean;
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
    guest: newPlayer(
      normalizeDisplayName(input.displayName, "Challenger"),
      "guest",
      input.now,
      initialArenaState(input.hasArenaCenter === true),
    ),
    matchPatch: { status: "waiting" as const, updatedAt: input.now },
  });
}

export interface StartPlan {
  matchPatch: {
    status: "waiting";
    phase: "countdown";
    startsAt: number;
    endsAt: null;
    updatedAt: number;
  };
}

/**
 * Host-only start. Requires exactly two ready, connected players and enters the
 * server-owned countdown. Activation owns the running window.
 */
export function planStartMatch(
  match: Pick<MatchState, "status" | "phase" | "hostPlayerId" | "durationMs">,
  players: readonly PlayerState[],
  requesterId: string,
  now: number,
): DomainResult<StartPlan> {
  if (match.hostPlayerId !== requesterId) {
    return rejected("not_host");
  }

  if (match.phase !== "lobby" || match.status === "active" || match.status === "ended") {
    return rejected("match_already_started");
  }

  if (players.length !== GAMEPLAY.maxPlayers) {
    return rejected("opponent_missing");
  }

  if (players.some((player) => !player.connected)) {
    return rejected("players_not_connected");
  }

  if (players.some((player) => !player.ready)) {
    return rejected("players_not_ready");
  }

  if (match.status !== "waiting") {
    return rejected("match_not_active");
  }

  return ok({
    matchPatch: {
      status: "waiting" as const,
      phase: "countdown" as const,
      startsAt: now + GAMEPLAY.countdownMs,
      endsAt: null,
      updatedAt: now,
    },
  });
}

export interface ActivatePlan {
  matchPatch: {
    status: "active";
    phase: "running";
    startsAt: number;
    endsAt: number;
    updatedAt: number;
  };
  playerResetPatch: StatePatch<PlayerState>;
}

/** Guarded countdown activation; stale or early scheduled jobs are no-ops. */
export function planActivateMatch(
  match: Pick<MatchState, "status" | "phase" | "startsAt" | "durationMs">,
  expectedStartsAt: number,
  now: number,
): ActivatePlan | null {
  if (
    match.status !== "waiting" ||
    match.phase !== "countdown" ||
    match.startsAt !== expectedStartsAt ||
    now < expectedStartsAt
  ) {
    return null;
  }

  return {
    matchPatch: {
      status: "active",
      phase: "running",
      startsAt: expectedStartsAt,
      endsAt: now + match.durationMs,
      updatedAt: now,
    },
    playerResetPatch: {
      lifeState: "alive",
      health: GAMEPLAY.startingHealth,
      ammo: GAMEPLAY.magazineSize,
      lastShotAt: null,
      reloadEndsAt: null,
      respawnAt: null,
    },
  };
}
