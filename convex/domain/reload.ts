import { GAMEPLAY } from "./config.js";
import type { FireLocationGate } from "./geofence.js";
import { hasExpired } from "./lifecycle.js";
import { ok, rejected, type DomainResult } from "./result.js";
import type { MatchState, PlayerState, StatePatch } from "./types.js";

type ReloadMatch = Pick<MatchState, "status" | "phase" | "endsAt">;

/** Reloads spend time on the server clock; the client cannot grant ammunition. */
export function planStartReload(
  match: ReloadMatch,
  player: PlayerState,
  now: number,
  locationGate: FireLocationGate | null = null,
): DomainResult<{ ammo: number; reloadEndsAt: number }> {
  if (match.status !== "active" || match.phase !== "running" || hasExpired(match, now)) {
    return rejected("match_not_active");
  }
  if (!player.connected || now - player.lastSeenAt >= GAMEPLAY.presenceTimeoutMs) {
    return rejected("shooter_disconnected");
  }
  if (player.lifeState !== "alive") {
    return rejected("player_not_alive");
  }
  if (locationGate !== null) {
    return rejected(locationGate);
  }
  if (player.reloadEndsAt !== null) {
    return rejected("already_reloading");
  }
  if (player.ammo >= GAMEPLAY.magazineSize) {
    return rejected("magazine_full");
  }
  return ok({ ammo: player.ammo, reloadEndsAt: now + GAMEPLAY.reloadDurationMs });
}

/** Early, superseded, repeated, death, and post-match completions are no-ops. */
export function planCompleteReload(
  match: ReloadMatch,
  player: Pick<PlayerState, "lifeState" | "reloadEndsAt">,
  expectedReloadEndsAt: number,
  now: number,
): StatePatch<PlayerState> | null {
  if (
    match.status !== "active" ||
    match.phase !== "running" ||
    hasExpired(match, now) ||
    player.lifeState !== "alive" ||
    player.reloadEndsAt !== expectedReloadEndsAt ||
    now < expectedReloadEndsAt
  ) {
    return null;
  }
  return { ammo: GAMEPLAY.magazineSize, reloadEndsAt: null };
}
