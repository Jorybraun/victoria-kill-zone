import { describe, expect, it } from "vitest";
import { GAMEPLAY, ZONE_DAMAGE } from "../domain/config.js";
import {
  resolveFire,
  resolveVerdictRecord,
  verdictFingerprint,
  verdictGate,
  type ShotVerdictRecord,
} from "../domain/fire.js";
import type { Doc, Id } from "../functions/lib/server.js";
import { match, player, T0 } from "./factories.js";

const ids = {
  match: "match-1" as Id<"matches">,
  host: "host" as Id<"players">,
  guest: "guest" as Id<"players">,
};

function record(overrides: Partial<ShotVerdictRecord> = {}): ShotVerdictRecord {
  return {
    clientShotId: "shot-1",
    shooterPlayerId: ids.guest,
    targetPlayerId: ids.host,
    zone: "torso",
    damage: ZONE_DAMAGE.torso,
    rewindMs: 80,
    verdict: "hit",
    rejectionReason: null,
    origin: [0, 0, 0],
    direction: [0, 0, 1],
    impact: [0, 0, 1],
    firedAtClient: T0,
    adjudicatedBy: ids.host,
    targetConfirmed: null,
    ...overrides,
  };
}

function resolve(overrides: Partial<ShotVerdictRecord> = {}, options: {
  shooter?: Partial<ReturnType<typeof player>>;
  target?: Partial<ReturnType<typeof player>>;
  now?: number;
} = {}) {
  return resolveVerdictRecord(
    player("guest", options.shooter),
    player("host", options.target),
    record(overrides),
    options.now ?? T0 + 1_000,
  );
}

describe("host verdict domain", () => {
  it("gates host and lifecycle authority in order", () => {
    expect(verdictGate(match(), "guest", T0)).toBe("not_host");
    expect(verdictGate(match({ phase: "lobby" }), "host", T0)).toBe("match_not_active");
    expect(verdictGate(match({ status: "ended" }), "host", T0)).toBe("match_not_active");
    expect(verdictGate(match(), "host", T0 + GAMEPLAY.matchDurationMs)).toBe("match_expired");
    expect(verdictGate(match(), "host", T0)).toBeNull();
  });

  it("applies torso and head hits through the shared terminal rules", () => {
    const torso = resolve();
    expect(torso.result).toMatchObject({
      accepted: true,
      outcome: "hit",
      damage: ZONE_DAMAGE.torso,
      targetHealth: 100 - ZONE_DAMAGE.torso,
    });
    expect(torso.shooterPatch).toMatchObject({ ammo: 7, shotsHit: 1 });
    expect(torso.events).toHaveLength(1);

    const head = resolve({ zone: "head" });
    expect(head.shooterPatch).toMatchObject({ headshots: 1 });
    expect(head.result.damage).toBe(ZONE_DAMAGE.head);
  });

  it("eliminates and schedules respawn using server-owned timing", () => {
    const now = T0 + 5_000;
    const plan = resolve({ zone: "head" }, {
      target: { health: 1, deaths: 2 },
      now,
    });
    expect(plan.result.outcome).toBe("kill");
    expect(plan.targetPatch).toMatchObject({
      health: 0,
      lifeState: "respawning",
      deaths: 3,
      respawnAt: now + GAMEPLAY.respawnDelayMs,
    });
  });

  it("records misses without rechecking ammo, and rejected host verdicts without patches", () => {
    const miss = resolve({ verdict: "miss", zone: null, targetPlayerId: null }, {
      shooter: { ammo: 0 },
      target: { health: 42 },
    });
    expect(miss.result).toMatchObject({ accepted: true, outcome: "miss", shooterAmmo: 0 });
    expect(miss.targetPatch).toBeNull();
    expect(miss.events[0]?.type).toBe("shot");

    const rejected = resolve({ verdict: "rejected", rejectionReason: "spatial-hit.v1:no-line-of-sight" });
    expect(rejected.result).toMatchObject({
      accepted: false,
      outcome: "rejected",
      rejectReason: "host_rejected",
    });
    expect(rejected.shooterPatch).toBeNull();
    expect(rejected.events).toHaveLength(0);
    expect(rejected.shot.rejectReason).toBe("host_rejected");
  });

  it("rechecks target and shooter liveness only", () => {
    expect(resolve({}, { target: { lifeState: "respawning" } }).result.rejectReason).toBe("target_not_alive");
    expect(resolve({ targetPlayerId: "other" }).result.rejectReason).toBe("invalid_target");
    expect(resolve({}, { shooter: { lifeState: "dead" } }).result.rejectReason).toBe("shooter_not_alive");
  });

  it("fingerprints adjudication fields but not receiver confirmation", () => {
    expect(verdictFingerprint(record())).toBe(verdictFingerprint(record()));
    expect(verdictFingerprint(record())).toBe(
      verdictFingerprint(record({ targetConfirmed: true })),
    );
    expect(verdictFingerprint(record())).not.toBe(verdictFingerprint(record({ damage: 1 })));
    expect(verdictFingerprint(record())).not.toBe(
      verdictFingerprint(record({ targetPlayerId: ids.guest })),
    );
  });

  it("shares application output with a client fire claim", () => {
    const shooter = player("host");
    const target = player("guest");
    const client = resolveFire(
      match(),
      shooter,
      target,
      {
        shooterId: shooter.id,
        clientShotId: "shot-1",
        targetId: target.id,
        zone: "torso",
        poseConfidence: 0.9,
        firedAtClient: T0,
      },
      T0 + 1_000,
    );
    const host = resolveVerdictRecord(
      shooter,
      target,
      record({ shooterPlayerId: shooter.id, targetPlayerId: target.id }),
      T0 + 1_000,
    );
    expect(host.result.damage).toBe(client.result.damage);
    expect(host.targetPatch).toEqual(client.targetPatch);
    expect(host.events).toEqual(client.events);
  });
});

const legacyShot = {
  _id: "shot-legacy" as Id<"shots">,
  _creationTime: T0,
  matchId: ids.match,
  shooterId: ids.host,
  targetId: ids.guest,
  clientShotId: "legacy",
  zone: "torso" as const,
  damage: 34,
  outcome: "hit" as const,
  rejectReason: null,
  poseConfidence: 0.9,
  firedAtClient: T0,
  createdAt: T0,
} satisfies Doc<"shots">;

const verdictShot = {
  ...legacyShot,
  mode: "verdict" as const,
  claimFingerprint: "fingerprint",
  rewindMs: 80,
  hostDamage: 34,
  verdict: "hit",
  hostRejectionReason: null,
  adjudicatedBy: ids.host,
  targetConfirmed: true,
} satisfies Doc<"shots">;

void legacyShot;
void verdictShot;
