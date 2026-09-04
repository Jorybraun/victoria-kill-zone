import { describe, expect, it } from "vitest";
import { GAMEPLAY, ZONE_DAMAGE } from "../domain/config.js";
import {
  fireClaimFingerprint,
  replayResult,
  resolveDebugFire,
  resolveFire,
  type FireRequest,
} from "../domain/fire.js";
import type { FireLocationGate } from "../domain/geofence.js";
import type { PlayerState } from "../domain/types.js";
import { match, player, T0 } from "./factories.js";

/** Overrides may explicitly clear an optional claim with `undefined`. */
type RequestOverrides = { [Key in keyof FireRequest]?: FireRequest[Key] | undefined };

function request(overrides: RequestOverrides = {}): FireRequest {
  const merged: Record<string, unknown> = {
    shooterId: "host",
    clientShotId: "shot-1",
    targetId: "guest",
    zone: "torso",
    poseConfidence: 0.9,
    firedAtClient: T0,
    ...overrides,
  };

  for (const [key, value] of Object.entries(merged)) {
    if (value === undefined) {
      delete merged[key];
    }
  }

  return merged as unknown as FireRequest;
}

function fire(
  overrides: {
    shooter?: Partial<PlayerState>;
    target?: Partial<PlayerState>;
    matchOverrides?: Parameters<typeof match>[0];
    request?: RequestOverrides;
    now?: number;
  } = {},
) {
  const shooter = player("host", overrides.shooter);
  const target = player("guest", overrides.target);
  return resolveFire(
    match(overrides.matchOverrides),
    shooter,
    target,
    request(overrides.request),
    overrides.now ?? T0 + 1_000,
  );
}

describe("debugFire authority", () => {
  it("applies server-owned zone damage and ignores any client claim", () => {
    const torso = fire({ request: { zone: "torso" } });
    expect(torso.result).toMatchObject({
      accepted: true,
      outcome: "hit",
      damage: ZONE_DAMAGE.torso,
      targetHealth: GAMEPLAY.startingHealth - ZONE_DAMAGE.torso,
      shooterAmmo: GAMEPLAY.magazineSize - 1,
    });

    // A client cannot supply damage: the argument shape has no damage field, and
    // an extra property is ignored by the resolver.
    const spoofed = fire({
      request: { zone: "limbs", ...({ damage: 999 } as unknown as RequestOverrides) },
    });
    expect(spoofed.result.damage).toBe(ZONE_DAMAGE.limbs);
    expect(spoofed.shot.damage).toBe(ZONE_DAMAGE.limbs);
  });

  it("charges ammunition and stamps the cooldown for a miss", () => {
    const plan = fire({ request: { targetId: undefined, zone: undefined, poseConfidence: undefined } });

    expect(plan.result).toEqual({
      accepted: true,
      outcome: "miss",
      damage: 0,
      shooterAmmo: GAMEPLAY.magazineSize - 1,
    });
    expect(plan.targetPatch).toBeNull();
    expect(plan.shooterPatch).toMatchObject({ lastShotAt: T0 + 1_000, shotsFired: 1 });
  });

  it("rejects fire before the duel is active and after it expires", () => {
    expect(fire({ matchOverrides: { status: "setup" } }).result.rejectReason).toBe("match_not_active");
    expect(fire({ matchOverrides: { status: "waiting" } }).result.rejectReason).toBe("match_not_active");
    expect(fire({ matchOverrides: { status: "ended" } }).result.rejectReason).toBe("match_not_active");
    expect(fire({ now: T0 + GAMEPLAY.matchDurationMs }).result.rejectReason).toBe("match_expired");
  });

  it("never lets ammunition go negative", () => {
    const plan = fire({ shooter: { ammo: 0 } });

    expect(plan.result).toMatchObject({ accepted: false, rejectReason: "out_of_ammo", shooterAmmo: 0 });
    expect(plan.shooterPatch).toBeNull();

    const lastRound = fire({ shooter: { ammo: 1 } });
    expect(lastRound.result.shooterAmmo).toBe(0);
    expect(lastRound.shooterPatch?.ammo).toBe(0);
  });

  it("enforces the fire cooldown", () => {
    const now = T0 + 10_000;
    expect(
      fire({ shooter: { lastShotAt: now - (GAMEPLAY.fireCooldownMs - 1) }, now }).result.rejectReason,
    ).toBe("cooldown_active");
    expect(fire({ shooter: { lastShotAt: now - GAMEPLAY.fireCooldownMs }, now }).result.accepted).toBe(
      true,
    );
  });

  it("rejects a dead or disconnected shooter", () => {
    expect(fire({ shooter: { lifeState: "dead" } }).result.rejectReason).toBe("shooter_not_alive");
    expect(fire({ shooter: { lifeState: "respawning" } }).result.rejectReason).toBe("shooter_not_alive");
    expect(fire({ shooter: { connected: false } }).result.rejectReason).toBe("shooter_disconnected");
  });

  it("rejects a hit claim against anyone but the live opponent", () => {
    expect(fire({ request: { targetId: "someone-else" } }).result.rejectReason).toBe("invalid_target");
    expect(fire({ request: { targetId: "host" } }).result.rejectReason).toBe("invalid_target");
    expect(fire({ target: { lifeState: "dead" } }).result.rejectReason).toBe("target_not_alive");
    expect(
      resolveFire(match(), player("host"), null, request(), T0 + 1_000).result.rejectReason,
    ).toBe("invalid_target");
  });

  it("resolves an elimination atomically and schedules the respawn", () => {
    const now = T0 + 5_000;
    const plan = fire({ request: { zone: "head" }, target: { health: 40, deaths: 1 }, now });

    expect(plan.result).toMatchObject({
      accepted: true,
      outcome: "kill",
      damage: 40,
      targetHealth: 0,
      targetLifeState: "respawning",
    });
    expect(plan.shooterPatch).toMatchObject({
      kills: 1,
      shotsHit: 1,
      headshots: 1,
      damageDealt: 40,
      ammo: GAMEPLAY.magazineSize - 1,
    });
    expect(plan.targetPatch).toEqual({
      health: 0,
      lifeState: "respawning",
      deaths: 2,
      respawnAt: now + GAMEPLAY.respawnDelayMs,
    });
    expect(plan.respawnAt).toBe(now + GAMEPLAY.respawnDelayMs);
    expect(plan.events.map((event) => event.type)).toEqual(["eliminated"]);
    expect(plan.shot).toMatchObject({ outcome: "kill", zone: "head", damage: 40 });
  });

  it("clamps overkill damage to the target's remaining health", () => {
    const plan = fire({ request: { zone: "head" }, target: { health: 10 } });
    expect(plan.result.damage).toBe(10);
    expect(plan.shooterPatch?.damageDealt).toBe(10);
  });

  it("ledgers every rejection without mutating player state", () => {
    const plan = fire({ matchOverrides: { status: "waiting" } });

    expect(plan.shooterPatch).toBeNull();
    expect(plan.targetPatch).toBeNull();
    expect(plan.events).toHaveLength(0);
    expect(plan.shot).toMatchObject({
      outcome: "rejected",
      rejectReason: "match_not_active",
      damage: 0,
      clientShotId: "shot-1",
    });
  });

  it("identifies an exact retry and preserves the original result", () => {
    const first = fire();
    const replay = replayResult(first.result);

    expect(replay).toEqual(first.result);
    expect(fireClaimFingerprint(request())).toBe(fireClaimFingerprint(request()));
    expect(fireClaimFingerprint(request())).not.toBe(
      fireClaimFingerprint(request({ zone: "head" })),
    );
    expect(fireClaimFingerprint(request())).not.toBe(
      fireClaimFingerprint(request({ impact: [1, 2, 3] })),
    );
  });

  it("drains a magazine to exactly zero over eight accepted shots", () => {
    let shooter = player("host");
    let target = player("guest", { health: 10_000 });
    let now = T0;

    for (let round = 0; round < GAMEPLAY.magazineSize; round += 1) {
      const plan = resolveFire(
        match(),
        shooter,
        target,
        request({ clientShotId: `shot-${round}` }),
        now,
      );
      expect(plan.result.accepted).toBe(true);
      shooter = { ...shooter, ...plan.shooterPatch };
      target = { ...target, ...plan.targetPatch };
      now += GAMEPLAY.fireCooldownMs;
    }

    expect(shooter.ammo).toBe(0);
    expect(shooter.shotsFired).toBe(GAMEPLAY.magazineSize);
    expect(target.health).toBe(10_000 - GAMEPLAY.magazineSize * ZONE_DAMAGE.torso);

    const dry = resolveFire(match(), shooter, target, request({ clientShotId: "shot-9" }), now);
    expect(dry.result.rejectReason).toBe("out_of_ammo");
  });
});

describe("geofence fire gate", () => {
  const now = T0 + 1_000;

  function gatedFire(gate: FireLocationGate | null, overrides: Parameters<typeof fire>[0] = {}) {
    return resolveFire(
      match(overrides.matchOverrides),
      player("host", overrides.shooter),
      player("guest", overrides.target),
      request(overrides.request),
      overrides.now ?? now,
      gate,
    );
  }

  it("rejects out-of-arena and stale shooters with zero gameplay change", () => {
    for (const [gate, reason] of [
      ["out_of_arena", "out_of_arena"],
      ["location_stale", "location_stale"],
    ] as const) {
      const plan = gatedFire(gate);

      expect(plan.result).toMatchObject({
        accepted: false,
        outcome: "rejected",
        damage: 0,
        rejectReason: reason,
        shooterAmmo: GAMEPLAY.magazineSize,
      });
      // Zero gameplay mutation: no player patches, no gameplay events, no
      // respawn scheduling; only the idempotency ledger row is recorded.
      expect(plan.shooterPatch).toBeNull();
      expect(plan.targetPatch).toBeNull();
      expect(plan.events).toHaveLength(0);
      expect(plan.respawnAt).toBeNull();
      expect(plan.shot).toMatchObject({ outcome: "rejected", rejectReason: reason, damage: 0 });
    }
  });

  it("is deterministic on retry: identical inputs produce the identical plan", () => {
    const first = gatedFire("out_of_arena");
    const second = gatedFire("out_of_arena");
    expect(second).toEqual(first);
    expect(replayResult(first.result)).toEqual(first.result);
  });

  it("orders the gate per contract: after presence/life, before ammo and cooldown", () => {
    expect(gatedFire("out_of_arena", { matchOverrides: { status: "waiting" } }).result.rejectReason).toBe(
      "match_not_active",
    );
    expect(gatedFire("out_of_arena", { shooter: { lifeState: "dead" } }).result.rejectReason).toBe(
      "shooter_not_alive",
    );
    expect(gatedFire("out_of_arena", { shooter: { connected: false } }).result.rejectReason).toBe(
      "shooter_disconnected",
    );
    expect(gatedFire("location_stale", { shooter: { ammo: 0 } }).result.rejectReason).toBe(
      "location_stale",
    );
    expect(
      gatedFire("out_of_arena", { shooter: { lastShotAt: now - 1 } }).result.rejectReason,
    ).toBe("out_of_arena");
  });

  it("gates debugFire identically on an arena-centered match", () => {
    const plan = resolveDebugFire(
      match(),
      player("host"),
      player("guest"),
      request(),
      now,
      "location_stale",
    );
    expect(plan.result).toMatchObject({
      accepted: false,
      outcome: "rejected",
      damage: 0,
      rejectReason: "location_stale",
    });
    expect(plan.shooterPatch).toBeNull();
    expect(plan.targetPatch).toBeNull();
    expect(plan.events).toHaveLength(0);
  });

  it("keeps legacy centerless debugFire ungated (existing iOS clients send no location)", () => {
    // Compatibility: the adapter passes a null gate when the match has no
    // recorded arenaCenter, so today's playable build fires exactly as before.
    const plan = resolveDebugFire(match(), player("host"), player("guest"), request(), now, null);
    expect(plan.result).toMatchObject({
      accepted: true,
      outcome: "hit",
      damage: ZONE_DAMAGE.torso,
    });
  });

  it("keeps centerless fire ungated (null gate accepted)", () => {
    const plan = resolveFire(
      match(),
      player("host"),
      player("guest"),
      request(),
      now,
      null,
    );
    expect(plan.result).toMatchObject({
      accepted: true,
      outcome: "hit",
      damage: ZONE_DAMAGE.torso,
    });
  });
});
