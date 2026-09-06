import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { GAMEPLAY } from "../domain/config.js";
import { completeReload, startReload } from "../functions/players.js";
import { matchSnapshot, spectatorSnapshot } from "../functions/queries.js";
import { debugFire, fire, recordVerdict } from "../functions/shots.js";
import { mutationContext, mutationHandler, queryHandler, storedMatch, storedPlayer, testIds } from "./mutation-context.js";
import { T0 } from "./factories.js";

const fireHandler = mutationHandler(fire);
const verdictHandler = mutationHandler(recordVerdict);
const debugHandler = mutationHandler(debugFire);
const reloadHandler = mutationHandler(startReload);
const completeHandler = mutationHandler(completeReload);
const matchSnapshotHandler = queryHandler(matchSnapshot);
const spectatorSnapshotHandler = queryHandler(spectatorSnapshot);

function setup() {
  const backend = mutationContext();
  const host = storedPlayer(testIds.host);
  const guest = storedPlayer(testIds.guest);
  backend.seed("matches", storedMatch());
  backend.seed("players", host.doc);
  backend.seed("players", guest.doc);
  const hostAuth = { matchId: testIds.match, playerId: testIds.host, sessionSecret: host.sessionSecret };
  const fireArgs = {
    matchId: testIds.match,
    shooterId: testIds.host,
    sessionSecret: host.sessionSecret,
    clientShotId: "shot-1",
    firedAtClient: T0 + 1_000,
  };
  const recordArgs = {
    ...hostAuth,
    record: {
      clientShotId: "shot-1",
      shooterPlayerId: testIds.guest,
      targetPlayerId: null,
      zone: null,
      damage: 0,
      rewindMs: 0,
      verdict: "miss" as const,
      rejectionReason: null,
      origin: [0, 0, 0],
      direction: [0, 0, -1],
      impact: [0, 0, -25],
      firedAtClient: T0 + 1_000,
      adjudicatedBy: testIds.host,
    },
  };
  return { ...backend, host, guest, hostAuth, fireArgs, recordArgs };
}

beforeEach(() => vi.spyOn(Date, "now").mockReturnValue(T0 + 1_000));
afterEach(() => vi.restoreAllMocks());

describe("shot mutation boundary", () => {
  it("records a miss with no player-list dependency and replays without extra writes", async () => {
    const b = setup();
    const first = await fireHandler(b.ctx, b.fireArgs);
    expect(first).toMatchObject({ accepted: true, outcome: "miss", shooterAmmo: 7, replayed: false });
    expect(b.reads).toEqual([testIds.host, testIds.match]);
    expect(b.indexes).toEqual([{ table: "shots", name: "by_shooter_and_client_shot_id" }]);
    const writes = b.writes.length;
    const retry = await fireHandler(b.ctx, b.fireArgs);
    expect(retry).toEqual({ ...first, replayed: true });
    expect(b.writes).toHaveLength(writes);

    const phone = await matchSnapshotHandler(b.ctx, b.hostAuth);
    const spectator = await spectatorSnapshotHandler(b.ctx, { code: "ABCDEF" });
    for (const snapshot of [phone, spectator]) {
      expect(snapshot?.events).toHaveLength(1);
      expect(snapshot?.events[0]).toMatchObject({
        type: "shot",
        clientShotId: b.fireArgs.clientShotId,
        actorPlayerId: testIds.host,
      });
    }
  });

  it.each(["hit", "kill"] as const)("correlates %s events with the accepted shot identity", async (outcome) => {
    const b = setup();
    if (outcome === "kill") b.seed("players", { ...b.guest.doc, health: 1 });
    const result = await fireHandler(b.ctx, { ...b.fireArgs, targetId: testIds.guest, zone: "torso", poseConfidence: 1 });
    expect(result.outcome).toBe(outcome);
    const snapshot = await matchSnapshotHandler(b.ctx, b.hostAuth);
    expect(snapshot.events[0]).toMatchObject({
      type: outcome === "kill" ? "eliminated" : "hit",
      clientShotId: b.fireArgs.clientShotId,
      actorPlayerId: testIds.host,
    });
  });

  it("targets the named same-match member without scanning or touching other players", async () => {
    const b = setup();
    b.seed("players", storedPlayer(testIds.third).doc);
    const result = await fireHandler(b.ctx, {
      ...b.fireArgs, targetId: testIds.third, zone: "torso", poseConfidence: 0.9,
    });
    expect(result).toMatchObject({ accepted: true, damage: 34, targetHealth: 66 });
    expect(b.readPlayer(testIds.guest)?.health).toBe(100);
    expect(b.reads).not.toContain(testIds.guest);
    expect(b.indexes.every((index) => index.table === "shots")).toBe(true);
  });

  it("rejects cross-match targets without damaging them", async () => {
    const b = setup();
    b.seed("players", storedPlayer(testIds.third, { matchId: testIds.otherMatch }).doc);
    const result = await fireHandler(b.ctx, {
      ...b.fireArgs, targetId: testIds.third, zone: "torso", poseConfidence: 0.9,
    });
    expect(result.rejectReason).toBe("INVALID_TARGET");
    expect(b.readPlayer(testIds.third)?.health).toBe(100);
    expect(b.writes.filter((write) => write.kind === "patch")).toHaveLength(0);
  });

  it("allows distinct shooters to use the same shot sequence id and replays after finish", async () => {
    const b = setup();
    const first = await verdictHandler(b.ctx, b.recordArgs);
    const second = await verdictHandler(b.ctx, {
      ...b.recordArgs,
      record: { ...b.recordArgs.record, shooterPlayerId: testIds.host },
    });
    expect(first).toMatchObject({ accepted: true, replayed: false });
    expect(second).toMatchObject({ accepted: true, replayed: false });
    expect(b.writes.filter((write) => write.table === "shots")).toHaveLength(2);
    b.seed("matches", storedMatch({ status: "ended", phase: "finished" }));
    const writes = b.writes.length;
    expect(await verdictHandler(b.ctx, b.recordArgs)).toEqual({ ...first, replayed: true });
    expect(b.writes).toHaveLength(writes);
    await expect(verdictHandler(b.ctx, {
      ...b.recordArgs, record: { ...b.recordArgs.record, clientShotId: "new-after-finish" },
    })).rejects.toMatchObject({ data: { code: "MATCH_NOT_RUNNING" } });
  });

  it("binds adjudicatedBy to the authenticated host before any write", async () => {
    const b = setup();
    await expect(verdictHandler(b.ctx, {
      ...b.recordArgs, record: { ...b.recordArgs.record, adjudicatedBy: testIds.guest },
    })).rejects.toMatchObject({ data: { code: "INVALID_TARGET" } });
    await expect(verdictHandler(b.ctx, {
      ...b.recordArgs, playerId: testIds.guest, sessionSecret: b.guest.sessionSecret,
    })).rejects.toMatchObject({ data: { code: "HOST_ONLY" } });
    expect(b.writes).toHaveLength(0);
  });

  it("rejects a changed verdict or cross-mode key instead of returning a false hit", async () => {
    const b = setup();
    await fireHandler(b.ctx, b.fireArgs);
    const writes = b.writes.length;
    const debug = await debugHandler(b.ctx, { ...b.hostAuth, clientShotId: b.fireArgs.clientShotId });
    expect(debug).toMatchObject({ accepted: false, outcome: "rejected", rejectReason: "IDEMPOTENCY_CONFLICT" });
    const host = await verdictHandler(b.ctx, {
      ...b.recordArgs, record: { ...b.recordArgs.record, shooterPlayerId: testIds.host },
    });
    expect(host.rejectReason).toBe("IDEMPOTENCY_CONFLICT");
    expect(b.writes).toHaveLength(writes);
  });

  it("does not persist non-finite timestamps or host numeric evidence", async () => {
    const b = setup();
    for (const firedAtClient of [NaN, Infinity, -1]) {
      expect(await fireHandler(b.ctx, { ...b.fireArgs, firedAtClient })).toMatchObject({ accepted: false });
    }
    for (const fields of [{ damage: NaN }, { damage: -1 }, { rewindMs: Infinity }, { rewindMs: -1 }]) {
      expect(await verdictHandler(b.ctx, {
        ...b.recordArgs, record: { ...b.recordArgs.record, ...fields },
      })).toMatchObject({ accepted: false });
    }
    for (const poseConfidence of [NaN, Infinity, -1, 1.1]) {
      expect(await fireHandler(b.ctx, { ...b.fireArgs, poseConfidence })).toMatchObject({ accepted: false });
    }
    expect(b.writes).toHaveLength(0);
  });

  it("replays the original debug rejection even after the target health changes", async () => {
    const b = setup();
    b.seed("players", { ...b.host.doc, ammo: 0 });
    b.seed("players", { ...b.guest.doc, health: 42 });
    const args = { ...b.hostAuth, clientShotId: "dry-debug" };
    const first = await debugHandler(b.ctx, args);
    expect(first).toMatchObject({ accepted: false, targetHealth: 42 });
    b.seed("players", { ...b.guest.doc, health: 100 });
    const writes = b.writes.length;
    expect(await debugHandler(b.ctx, args)).toEqual({ ...first, replayed: true });
    expect(b.writes).toHaveLength(writes);
  });

  it("enforces 150ms between shots independently of client timestamps", async () => {
    const b = setup();
    await fireHandler(b.ctx, b.fireArgs);
    vi.mocked(Date.now).mockReturnValue(T0 + 1_149);
    expect(await fireHandler(b.ctx, { ...b.fireArgs, clientShotId: "early", firedAtClient: T0 + 100_000 })).toMatchObject({
      accepted: false, rejectReason: "FIRE_COOLDOWN", shooterAmmo: 7,
    });
    vi.mocked(Date.now).mockReturnValue(T0 + 1_150);
    expect(await fireHandler(b.ctx, { ...b.fireArgs, clientShotId: "ready" })).toMatchObject({ accepted: true, shooterAmmo: 6 });
  });

  it("refuses stale presence even when the stored connected flag is true", async () => {
    const b = setup();
    vi.mocked(Date.now).mockReturnValue(T0 + GAMEPLAY.presenceTimeoutMs);
    expect(await fireHandler(b.ctx, b.fireArgs)).toMatchObject({ accepted: false, rejectReason: "CONNECTION_STALE" });
    expect(b.writes.filter((write) => write.kind === "patch")).toHaveLength(0);
  });
});

describe("reload mutation boundary", () => {
  it("starts one guarded job, blocks fire, grants ammo once, then fires again", async () => {
    const b = setup();
    b.seed("players", { ...b.host.doc, ammo: 3 });
    const result = await reloadHandler(b.ctx, b.hostAuth);
    expect(result).toEqual({ ammo: 3, reloadEndsAt: T0 + 2_250 });
    expect(b.jobs).toEqual([{ when: result.reloadEndsAt, args: { playerId: testIds.host, expectedReloadEndsAt: result.reloadEndsAt } }]);
    await expect(reloadHandler(b.ctx, b.hostAuth)).rejects.toMatchObject({ data: { code: "ALREADY_RELOADING" } });
    expect(b.jobs).toHaveLength(1);
    expect(await fireHandler(b.ctx, b.fireArgs)).toMatchObject({ accepted: false, rejectReason: "RELOADING", shooterAmmo: 3 });
    const job = { playerId: testIds.host, expectedReloadEndsAt: result.reloadEndsAt };
    await completeHandler(b.ctx, job);
    expect(b.readPlayer(testIds.host)?.ammo).toBe(3);
    vi.mocked(Date.now).mockReturnValue(result.reloadEndsAt);
    await completeHandler(b.ctx, job);
    expect(b.readPlayer(testIds.host)).toMatchObject({ ammo: 8, reloadEndsAt: null });
    const writes = b.writes.length;
    await completeHandler(b.ctx, job);
    expect(b.writes).toHaveLength(writes);
    expect(await fireHandler(b.ctx, { ...b.fireArgs, clientShotId: "after-completion" })).toMatchObject({ accepted: true, shooterAmmo: 7 });
  });

  it("cancels an in-progress reload on elimination and ignores its stale completion", async () => {
    const b = setup();
    b.seed("players", { ...b.guest.doc, health: 1, ammo: 0, reloadEndsAt: T0 + 1_250 });
    const result = await fireHandler(b.ctx, { ...b.fireArgs, targetId: testIds.guest, zone: "torso", poseConfidence: 1 });
    expect(result.outcome).toBe("kill");
    expect(b.readPlayer(testIds.guest)).toMatchObject({ ammo: 0, reloadEndsAt: null, lifeState: "respawning" });
    vi.mocked(Date.now).mockReturnValue(T0 + 1_250);
    await completeHandler(b.ctx, { playerId: testIds.guest, expectedReloadEndsAt: T0 + 1_250 });
    expect(b.readPlayer(testIds.guest)?.ammo).toBe(0);
  });
});
