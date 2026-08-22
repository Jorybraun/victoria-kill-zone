import { describe, expect, it } from "vitest";
import { GAMEPLAY } from "../domain/config.js";
import { planRespawn } from "../domain/respawn.js";
import { player, T0 } from "./factories.js";

describe("guarded respawn", () => {
  const respawnAt = T0 + GAMEPLAY.respawnDelayMs;
  const eliminated = player("guest", {
    health: 0,
    ammo: 3,
    lifeState: "respawning",
    respawnAt,
    deaths: 1,
  });

  it("restores health, ammo, and life exactly at the expected server time", () => {
    expect(planRespawn("running", eliminated, respawnAt, respawnAt)).toEqual({
      health: GAMEPLAY.startingHealth,
      ammo: GAMEPLAY.magazineSize,
      lifeState: "alive",
      respawnAt: null,
      lastShotAt: null,
    });
  });

  it("ignores early, stale, repeated, and post-match jobs", () => {
    expect(planRespawn("running", eliminated, respawnAt, respawnAt - 1)).toBeNull();
    expect(planRespawn("running", eliminated, respawnAt + 1, respawnAt + 1)).toBeNull();
    expect(planRespawn("finished", eliminated, respawnAt, respawnAt)).toBeNull();
    expect(
      planRespawn("running", { lifeState: "alive", respawnAt: null }, respawnAt, respawnAt),
    ).toBeNull();
  });
});
