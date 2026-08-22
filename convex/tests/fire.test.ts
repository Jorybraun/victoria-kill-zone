import { describe, expect, it } from "vitest";
import {
  DEBUG_TORSO_DAMAGE,
  INITIAL_AMMO,
  INITIAL_HEALTH,
  PRESENCE_TIMEOUT_MS,
} from "../domain/contract.js";
import { replayShot, resolveDebugFire, type FireShooter, type FireTarget } from "../domain/fire.js";

const T0 = 1_760_000_000_000;
const CLIENT_SHOT_ID = "3f0c9a2e-shot-1";

const shooter: FireShooter = {
  id: "host",
  displayName: "VIC",
  role: "host",
  connected: true,
  lastSeenAt: T0,
  ammo: INITIAL_AMMO,
};

const target: FireTarget = {
  id: "guest",
  displayName: "JORY",
  connected: true,
  lastSeenAt: T0,
  health: INITIAL_HEALTH,
};

function fire(overrides: Partial<Parameters<typeof resolveDebugFire>[0]> = {}) {
  return resolveDebugFire({
    phase: "running",
    shooter,
    target,
    clientShotId: CLIENT_SHOT_ID,
    now: T0,
    ...overrides,
  });
}

describe("resolveDebugFire", () => {
  it("applies server-owned torso damage: ammo 8 → 7 and health 100 → 66", () => {
    const plan = fire();

    expect(plan.result).toEqual({
      accepted: true,
      outcome: "hit",
      clientShotId: CLIENT_SHOT_ID,
      replayed: false,
      damage: DEBUG_TORSO_DAMAGE,
      shooterAmmo: INITIAL_AMMO - 1,
      targetHealth: INITIAL_HEALTH - DEBUG_TORSO_DAMAGE,
    });
    expect(plan.ledger).toMatchObject({ zone: "torso", clientShotId: CLIENT_SHOT_ID, createdAt: T0 });
    expect(plan.event).toMatchObject({
      type: "hit",
      zone: "torso",
      damage: DEBUG_TORSO_DAMAGE,
      actorPlayerId: "host",
      targetPlayerId: "guest",
      message: "VIC HIT JORY • TORSO \u221234",
    });
  });

  it("is host only in this slice", () => {
    const plan = fire({ shooter: { ...shooter, id: "guest", role: "guest" } });

    expect(plan.result).toMatchObject({ accepted: false, rejectReason: "HOST_ONLY" });
    expect(plan.ledger).toBeUndefined();
    expect(plan.event).toBeUndefined();
  });

  it("never accepts a client-supplied damage value", () => {
    const plan = fire({ target: { ...target, health: 90 } });

    expect(plan.result.damage).toBe(DEBUG_TORSO_DAMAGE);
  });

  it("rejects before the duel is running and writes nothing", () => {
    for (const phase of ["lobby", "countdown", "finished", "cancelled"] as const) {
      const plan = fire({ phase });

      expect(plan.result).toMatchObject({
        accepted: false,
        outcome: "rejected",
        rejectReason: "MATCH_NOT_RUNNING",
        damage: 0,
        shooterAmmo: INITIAL_AMMO,
        targetHealth: INITIAL_HEALTH,
      });
      expect(plan.ledger).toBeUndefined();
      expect(plan.event).toBeUndefined();
    }
  });

  it("rejects a stale shooter or target connection", () => {
    expect(fire({ shooter: { ...shooter, connected: false } }).result.rejectReason).toBe(
      "CONNECTION_STALE",
    );
    expect(fire({ target: { ...target, connected: false } }).result.rejectReason).toBe(
      "CONNECTION_STALE",
    );
  });

  it("rejects a heartbeat that has aged out even while connected is still set", () => {
    const aged = T0 - PRESENCE_TIMEOUT_MS;

    expect(fire({ shooter: { ...shooter, lastSeenAt: aged } }).result).toMatchObject({
      accepted: false,
      rejectReason: "CONNECTION_STALE",
      shooterAmmo: INITIAL_AMMO,
      targetHealth: INITIAL_HEALTH,
    });
    expect(fire({ target: { ...target, lastSeenAt: aged } }).result.rejectReason).toBe(
      "CONNECTION_STALE",
    );
    expect(
      fire({ shooter: { ...shooter, lastSeenAt: aged + 1 } }).result.accepted,
    ).toBe(true);
  });

  it("rejects a solo lobby with the authoritative default target health", () => {
    const plan = fire({ phase: "lobby", target: null });

    expect(plan.result).toEqual({
      accepted: false,
      outcome: "rejected",
      clientShotId: CLIENT_SHOT_ID,
      replayed: false,
      damage: 0,
      shooterAmmo: INITIAL_AMMO,
      targetHealth: INITIAL_HEALTH,
      rejectReason: "MATCH_NOT_RUNNING",
    });
    expect(plan.ledger).toBeUndefined();
    expect(plan.event).toBeUndefined();
  });

  it("rejects an empty idempotency key without borrowing a credential code", () => {
    const plan = fire({ clientShotId: "  " });

    expect(plan.result).toEqual({
      accepted: false,
      outcome: "rejected",
      clientShotId: "  ",
      replayed: false,
      damage: 0,
      shooterAmmo: INITIAL_AMMO,
      targetHealth: INITIAL_HEALTH,
    });
    expect(plan.result.rejectReason).toBeUndefined();
    expect(plan.ledger).toBeUndefined();
  });

  it("rejects an empty magazine without changing state", () => {
    const plan = fire({ shooter: { ...shooter, ammo: 0 } });

    expect(plan.result).toMatchObject({ accepted: false, shooterAmmo: 0, targetHealth: INITIAL_HEALTH });
    expect(plan.ledger).toBeUndefined();
  });

  it("clamps damage at zero health and rejects a further shot", () => {
    const nearlyDead = fire({ target: { ...target, health: 10 } });

    expect(nearlyDead.result).toMatchObject({ damage: 10, targetHealth: 0 });
    expect(fire({ target: { ...target, health: 0 } }).result.accepted).toBe(false);
  });
});

describe("replayShot", () => {
  it("returns the stored outcome and consumes nothing", () => {
    const first = fire();
    const stored = {
      clientShotId: CLIENT_SHOT_ID,
      damage: first.result.damage,
      shooterAmmo: first.result.shooterAmmo,
      targetHealth: first.result.targetHealth,
      eventId: "event-1",
    };

    const replay = replayShot(stored);

    expect(replay.result).toEqual({
      accepted: true,
      outcome: "hit",
      clientShotId: CLIENT_SHOT_ID,
      replayed: true,
      damage: DEBUG_TORSO_DAMAGE,
      shooterAmmo: INITIAL_AMMO - 1,
      targetHealth: INITIAL_HEALTH - DEBUG_TORSO_DAMAGE,
      eventId: "event-1",
    });
    expect(replay.ledger).toBeUndefined();
    expect(replay.event).toBeUndefined();
  });
});
