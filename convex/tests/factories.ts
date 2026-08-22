import { GAMEPLAY } from "../domain/config.js";
import { newPlayer } from "../domain/match.js";
import type { MatchState, PlayerState } from "../domain/types.js";

export const T0 = 1_700_000_000_000;

export function match(overrides: Partial<MatchState> = {}): MatchState {
  return {
    status: "active",
    hostPlayerId: "host",
    radiusMeters: GAMEPLAY.defaultArenaRadiusMeters,
    durationMs: GAMEPLAY.matchDurationMs,
    startedAt: T0,
    endsAt: T0 + GAMEPLAY.matchDurationMs,
    winnerPlayerId: null,
    endReason: null,
    ...overrides,
  };
}

export function player(id: string, overrides: Partial<PlayerState> = {}): PlayerState {
  return {
    id,
    ...newPlayer(id === "host" ? "Host" : "Challenger", id === "host" ? "host" : "guest", T0),
    ...overrides,
  };
}
