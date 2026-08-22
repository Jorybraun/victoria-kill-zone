import { PRESENCE_TIMEOUT_MS } from "./contract.js";

/**
 * Server-owned presence.
 *
 * `connected` is a stored fact, not a client claim: a phone renews it with
 * `players:heartbeat`, and a guarded scheduled expiry clears it once
 * {@link PRESENCE_TIMEOUT_MS} passes without a renewal. Rules therefore treat a
 * player as present only when the stored flag is set *and* the last heartbeat is
 * still inside the timeout, so a missed expiry job can never grant liveness.
 */
export interface PresenceState {
  readonly connected: boolean;
  readonly lastSeenAt: number;
}

export function isFresh(lastSeenAt: number, now: number): boolean {
  return now - lastSeenAt < PRESENCE_TIMEOUT_MS;
}

export function isPresent(player: PresenceState, now: number): boolean {
  return player.connected && isFresh(player.lastSeenAt, now);
}

/** Server time at which a heartbeat taken at `lastSeenAt` becomes stale. */
export function presenceExpiresAt(lastSeenAt: number): number {
  return lastSeenAt + PRESENCE_TIMEOUT_MS;
}

/**
 * Whether a scheduled expiry job may clear `connected`.
 *
 * The job carries the heartbeat it was scheduled for, so a newer heartbeat
 * (different `lastSeenAt`), an already-disconnected player, or an early run all
 * write nothing. Expiry is therefore idempotent and safe to run twice.
 */
export function shouldExpirePresence(
  player: PresenceState,
  expectedLastSeenAt: number,
  now: number,
): boolean {
  if (!player.connected || player.lastSeenAt !== expectedLastSeenAt) {
    return false;
  }

  return now >= presenceExpiresAt(expectedLastSeenAt);
}
