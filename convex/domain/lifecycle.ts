import type { MatchPhase, MatchState, MatchStatus, PlayerState } from "./types.js";

/** Legal transitions of the explicit duel state machine. */
const TRANSITIONS: Readonly<Record<MatchStatus, readonly MatchStatus[]>> = {
  setup: ["waiting", "ended"],
  waiting: ["setup", "active", "ended"],
  active: ["ended"],
  ended: [],
};

export function canTransition(from: MatchStatus, to: MatchStatus): boolean {
  return TRANSITIONS[from].includes(to);
}

/**
 * Project the explicit status onto the frozen cross-workstream `MatchPhase`.
 * `setup` and `waiting` are both lobby states; a cancelled duel is an `ended`
 * match without a winner.
 */
export function phaseForStatus(match: Pick<MatchState, "status" | "endReason">): MatchPhase {
  switch (match.status) {
    case "setup":
    case "waiting":
      return "lobby";
    case "active":
      return "running";
    case "ended":
      return match.endReason === "abandoned" ? "cancelled" : "finished";
  }
}

/** A duel is joinable only while it is in `setup` and below the player limit. */
export function isJoinable(match: Pick<MatchState, "status">, playerCount: number, maxPlayers: number): boolean {
  return match.status === "setup" && playerCount < maxPlayers;
}

/**
 * True when an active duel has run past `endsAt`. Gameplay mutations use this to
 * reject late actions even if the scheduled finish job is delayed.
 */
export function hasExpired(match: Pick<MatchState, "status" | "endsAt">, now: number): boolean {
  return match.status === "active" && match.endsAt !== null && now >= match.endsAt;
}

/**
 * Winner resolution: most kills, then fewest deaths, then most damage dealt.
 * Returns `null` for a fully tied duel or a duel without two players.
 */
export function resolveWinner(players: readonly PlayerState[]): string | null {
  if (players.length < 2) {
    return null;
  }

  const ranked = [...players].sort(
    (a, b) => b.kills - a.kills || a.deaths - b.deaths || b.damageDealt - a.damageDealt,
  );

  const [leader, runnerUp] = ranked;
  if (leader === undefined || runnerUp === undefined) {
    return null;
  }

  const tied =
    leader.kills === runnerUp.kills &&
    leader.deaths === runnerUp.deaths &&
    leader.damageDealt === runnerUp.damageDealt;

  return tied ? null : leader.id;
}
