import { GAMEPLAY } from "./config.js";
import type { MatchPhase, PlayerState, StatePatch } from "./types.js";

/** Guarded respawn plan used by the scheduled internal mutation. */
export function planRespawn(
  phase: MatchPhase,
  player: Pick<PlayerState, "lifeState" | "respawnAt">,
  expectedRespawnAt: number,
  now: number,
): StatePatch<PlayerState> | null {
  if (
    phase !== "running" ||
    player.lifeState !== "respawning" ||
    player.respawnAt !== expectedRespawnAt ||
    now < expectedRespawnAt
  ) {
    return null;
  }

  return {
    health: GAMEPLAY.startingHealth,
    ammo: GAMEPLAY.magazineSize,
    lifeState: "alive",
    respawnAt: null,
    lastShotAt: null,
  };
}
