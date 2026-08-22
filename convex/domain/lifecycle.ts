import type { MatchPhase } from "./contract.js";

/**
 * Authoritative phase resolution.
 *
 * The stored phase advances on write, but the countdown → running and
 * running → finished edges are time based, so every read and every rule
 * resolves the phase from server time instead of trusting a stale record.
 */
export interface MatchTiming {
  readonly phase: MatchPhase;
  readonly startsAt?: number;
  readonly endsAt?: number;
}

const TERMINAL_PHASES: readonly MatchPhase[] = ["finished", "cancelled"];

export function isTerminal(phase: MatchPhase): boolean {
  return TERMINAL_PHASES.includes(phase);
}

export function resolvePhase(match: MatchTiming, now: number): MatchPhase {
  if (isTerminal(match.phase)) {
    return match.phase;
  }

  if (match.endsAt !== undefined && now >= match.endsAt) {
    return "finished";
  }

  if (match.phase === "countdown" && match.startsAt !== undefined && now >= match.startsAt) {
    return "running";
  }

  return match.phase;
}

/** Only a `lobby` match accepts a second player. */
export function isJoinable(phase: MatchPhase): boolean {
  return phase === "lobby";
}

/** Countdown remaining in milliseconds; zero once the duel is running. */
export function countdownRemainingMs(match: MatchTiming, now: number): number {
  if (match.startsAt === undefined || resolvePhase(match, now) !== "countdown") {
    return 0;
  }

  return Math.max(0, match.startsAt - now);
}
