import { describe, expect, it } from "vitest";
import { GAMEPLAY } from "../domain/config.js";
import { resolveFire } from "../domain/fire.js";
import { planCompleteReload, planStartReload } from "../domain/reload.js";
import { match, player, T0 } from "./factories.js";

describe("authoritative reload", () => {
  const shooter = player("host", { ammo: 3 });
  const reloadEndsAt = T0 + GAMEPLAY.reloadDurationMs;

  it("preserves rounds until the complete 1250ms duration has elapsed", () => {
    expect(planStartReload(match(), shooter, T0)).toEqual({
      ok: true,
      value: { ammo: 3, reloadEndsAt },
    });
    const reloading = { ...shooter, reloadEndsAt };
    expect(planCompleteReload(match(), reloading, reloadEndsAt, reloadEndsAt - 1)).toBeNull();
    expect(planCompleteReload(match(), reloading, reloadEndsAt, reloadEndsAt)).toEqual({
      ammo: GAMEPLAY.magazineSize,
      reloadEndsAt: null,
    });
  });

  it("refuses reloads outside the live, connected, alive, in-arena state", () => {
    expect(planStartReload(match({ phase: "lobby" }), shooter, T0)).toEqual({ ok: false, reason: "match_not_active" });
    expect(planStartReload(match(), shooter, T0 + GAMEPLAY.matchDurationMs)).toEqual({ ok: false, reason: "match_not_active" });
    expect(planStartReload(match(), { ...shooter, connected: false }, T0)).toEqual({ ok: false, reason: "shooter_disconnected" });
    expect(planStartReload(match(), shooter, T0 + GAMEPLAY.presenceTimeoutMs)).toEqual({ ok: false, reason: "shooter_disconnected" });
    expect(planStartReload(match(), { ...shooter, lifeState: "respawning" }, T0)).toEqual({ ok: false, reason: "player_not_alive" });
    expect(planStartReload(match(), shooter, T0, "out_of_arena")).toEqual({ ok: false, reason: "out_of_arena" });
    expect(planStartReload(match(), shooter, T0, "location_stale")).toEqual({ ok: false, reason: "location_stale" });
  });

  it("refuses full magazines and duplicate starts", () => {
    expect(planStartReload(match(), player("host"), T0)).toEqual({ ok: false, reason: "magazine_full" });
    expect(planStartReload(match(), { ...shooter, reloadEndsAt }, T0)).toEqual({ ok: false, reason: "already_reloading" });
    expect(planStartReload(match(), { ...shooter, reloadEndsAt }, reloadEndsAt + 1)).toEqual({ ok: false, reason: "already_reloading" });
  });

  it("keeps fire locked until delayed completion atomically grants ammo", () => {
    const plan = resolveFire(
      match(), { ...shooter, reloadEndsAt }, null,
      { shooterId: shooter.id, clientShotId: "after-reload-time", firedAtClient: reloadEndsAt },
      reloadEndsAt + 1,
    );
    expect(plan.result.rejectReason).toBe("reloading");
    expect(plan.shooterPatch).toBeNull();
    expect(plan.events).toHaveLength(0);
  });

  it("ignores stale, repeated, death, and post-match completion jobs", () => {
    const reloading = { ...shooter, reloadEndsAt };
    expect(planCompleteReload(match(), reloading, reloadEndsAt - 1, reloadEndsAt)).toBeNull();
    expect(planCompleteReload(match(), { ...reloading, reloadEndsAt: null }, reloadEndsAt, reloadEndsAt)).toBeNull();
    expect(planCompleteReload(match(), { ...reloading, lifeState: "respawning" }, reloadEndsAt, reloadEndsAt)).toBeNull();
    expect(planCompleteReload(match({ phase: "finished" }), reloading, reloadEndsAt, reloadEndsAt)).toBeNull();
    expect(planCompleteReload(match(), reloading, reloadEndsAt, T0 + GAMEPLAY.matchDurationMs)).toBeNull();
  });
});
