import type { MatchPhase } from "./contract.js";

/**
 * Authoritative phase resolution.
 *
 * The stored phase advances on write. `endsAt` is the one boundary a read may
 * resolve on its own, because a match whose end time has passed must never be
 * treated as playable even if its scheduled finish has not landed yet. The
 * countdown → running edge is deliberately *not* resolved on read: `running`
 * requires an `endsAt`, and only {@link planActivation} may issue one.
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

  return match.phase;
}

export interface ActivationPlan {
  readonly phase: "running";
  readonly endsAt: number;
  readonly message: string;
}

/**
 * What a scheduled activation may persist, or `null` when it must do nothing.
 *
 * The job carries the countdown it was scheduled for, so a duplicate run, a run
 * against a restarted or terminal match, or an early run writes nothing. The
 * duel length is measured from the activation itself, so a delayed job still
 * yields a full-length match.
 */
export function planActivation(
  match: MatchTiming & { readonly durationMs: number },
  expectedStartsAt: number,
  now: number,
): ActivationPlan | null {
  if (match.phase !== "countdown" || match.startsAt !== expectedStartsAt) {
    return null;
  }

  if (now < expectedStartsAt) {
    return null;
  }

  return { phase: "running", endsAt: now + match.durationMs, message: "DUEL STARTED" };
}

/**
 * Whether a scheduled finish may persist `finished`.
 *
 * Guarded by the `endsAt` the job was scheduled for, so a stale job from an
 * earlier end time, a terminal match, or an early run writes nothing.
 */
export function shouldFinish(
  match: MatchTiming,
  expectedEndsAt: number,
  now: number,
): boolean {
  if (isTerminal(match.phase) || match.endsAt !== expectedEndsAt) {
    return false;
  }

  return now >= expectedEndsAt;
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
