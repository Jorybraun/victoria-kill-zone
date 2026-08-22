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

/**
 * Phase a scheduled transition is allowed to persist, or `null` when it must do
 * nothing.
 *
 * Scheduled work can fire early, fire late, or fire against a match that moved
 * on, so the target is only written when server time already resolves to it and
 * the record does not already say so. That makes every scheduled transition
 * idempotent and safe to run twice.
 */
export function scheduledTransition(
  match: MatchTiming,
  target: Extract<MatchPhase, "running" | "finished">,
  now: number,
): MatchPhase | null {
  if (isTerminal(match.phase) || match.phase === target) {
    return null;
  }

  return resolvePhase(match, now) === target ? target : null;
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
