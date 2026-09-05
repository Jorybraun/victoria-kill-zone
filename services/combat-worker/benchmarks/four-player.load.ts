import { env } from "cloudflare:workers";
import { abortAllDurableObjects, runInDurableObject } from "cloudflare:test";
import { afterEach, expect, it } from "vitest";
import { DEFAULT_RULES, LIMITS, type BodyObservation, type CombatSnapshot, type Quaternion, type ServerEvent, type Vec3 } from "@vkz/combat-protocol";
import { claims, requestUpgrade } from "../tests/helpers.js";
import { LoadClient, percentiles, sleep, until } from "./load-client.js";
import { installRuntimeProfile } from "./runtime-profile.js";

declare const __VKZ_LOAD_MS__: number;
declare const __VKZ_PROFILE__: boolean;
const LOAD_MS = __VKZ_LOAD_MS__;
const round = (value: number): number => Math.round(value * 1000) / 1000;
const scenarios = ["miss-lanes", "opposing-combat"] as const;
afterEach(async () => {await abortAllDurableObjects();});

for (const scenario of scenarios) it(`four-player ${scenario}: measured input, gameplay and durable event convergence`, async ({annotate}) => {
  const mixed = scenario === "opposing-combat";
  const positions: Vec3[] = mixed ? [[-3, 1.3, 3], [-3, 1.3, -3], [3, 1.3, 3], [3, 1.3, -3]]
    : [[-6, 1.3, 0], [-2, 1.3, 0], [2, 1.3, 0], [6, 1.3, 0]];
  const roster = positions.map((_, index) => ({playerId: `load-${index}`, displayName: `Load ${index}`, role: index === 0 ? "host" as const : "player" as const}));
  const ticket = claims({playerId: roster[0]!.playerId, roster,
    rules: {...structuredClone(DEFAULT_RULES), durationMs: LOAD_MS + 15_000, geometry: "trackedBody"}});
  const clients: LoadClient[] = [];
  const pumpLateness: number[] = [];
  let pumping = true, shoot = false, missedPumpSlots = 0;
  let pump: Promise<void> | undefined;
  let profile: Awaited<ReturnType<typeof installRuntimeProfile>> | null = null;
  let clockSync = Promise.resolve(), clockSyncPending = false;
  let clockFailure: string | null = null;
  let nextClockSync = performance.now() + 1000;
  const observations = (index: number, capturedAtMs: number): BodyObservation[] => clients.flatMap((other, targetIndex) => {
    if (targetIndex === index) return [];
    const target = positions[targetIndex]!;
    return [{targetPlayerId: other.playerId, capturedAtMs, associationConfidence: 1, uncertaintyMeters: 0.01,
      colliders: Array.from({length: 32}, (_, bone) => ({kind: "capsule" as const, id: `bone-${bone}`, zone: "limbs" as const,
        a: [round(target[0] + (bone % 4) * 0.025), round(0.25 + bone * 0.035), target[2] - 0.03] as Vec3,
        b: [round(target[0] + (bone % 4) * 0.025), round(0.35 + bone * 0.035), target[2] + 0.03] as Vec3, radius: 0.035}))}];
  });
  try {
    for (const member of roster) {
      const response = await requestUpgrade({...ticket, playerId: member.playerId});
      expect(response.status).toBe(101);
      const client = new LoadClient(response.webSocket!, member.playerId); clients.push(client);
      await until(() => client.snapshot !== null);
      await client.synchronizeClock();
      client.send({kind: "frameReady", ready: true, residualMeters: 0.01, residualDegrees: 0.1, clockUncertaintyMs: 1});
    }
    if (__VKZ_PROFILE__) profile = await installRuntimeProfile(ticket.matchId);
    pump = (async () => {
      let due = performance.now();
      while (pumping) {
        const began = performance.now(), late = Math.max(0, began - due);
        if (shoot) {pumpLateness.push(late); missedPumpSlots += Math.floor(late / LIMITS.tickMs);}
        due += (Math.floor(late / LIMITS.tickMs) + 1) * LIMITS.tickMs;
        for (const [index, client] of clients.entries()) {
          const position = positions[index]!, reverse = mixed && index % 2 === 1;
          const orientation: Quaternion = reverse ? [0, 1, 0, 0] : [0, 0, 0, 1];
          const capturedAtMs = client.matchTimeMs;
          client.send({kind: "pose", pose: {sequence: ++client.poseSequence, capturedAtMs, position, orientation, tracking: "normal"}, observations: observations(index, capturedAtMs)});
          const player = client.players.get(client.playerId);
          if (!shoot || client.phase !== "running" || !player || player.health <= 0) continue;
          if (player.slowFieldReadyAtMs <= client.matchTimeMs && !client.hasPending("slowField")) client.send({kind: "slowField", poseSequence: client.poseSequence});
          if (mixed && index % 2 === 1 && player.shield.cooldownUntilMs <= client.matchTimeMs && !client.hasPending("shield")) {
            client.send({kind: "shield", active: true, poseSequence: client.poseSequence});
          }
          if (player.shield.activeUntilMs !== null || client.hasPending("shield")) continue;
          if (player.ammo === 0 && player.reloadEndsAtMs === null && !client.hasPending("reload")) client.send({kind: "reload"});
          else if (player.ammo > 0 && player.reloadEndsAtMs === null && !client.hasPending("fire")
            && (player.lastFireAtMs === null || client.matchTimeMs - player.lastFireAtMs >= ticket.rules.weapon.cooldownMs)) {
            client.send({kind: "fire", shotId: crypto.randomUUID(), poseSequence: client.poseSequence, origin: position, direction: reverse ? [0, 0, 1] : [0, 0, -1]});
          }
        }
        if (began >= nextClockSync && !clockSyncPending) {
          clockSyncPending = true; nextClockSync = began + 1000;
          // Clock replies must not stop the independent 20 Hz tracking pump.
          clockSync = Promise.all(clients.map(client => client.synchronizeClock()))
            .then(() => undefined)
            .catch(() => {clockFailure = "clockSyncFailed"; pumping = false;})
            .finally(() => {clockSyncPending = false;});
        }
        await sleep(Math.max(1, due - performance.now()));
      }
    })();
    void pump.catch(() => {pumping = false;});
    await until(() => clients.every(client => client.players.size === 4 && [...client.players.values()].every(player => player.frameReady)));
    clients[0]!.send({kind: "start"});
    await until(() => clients.every(client => client.phase === "running"));
    await sleep(500); // Warmup is excluded from the measurement window.
    await profile?.begin();
    const beganAt = performance.now(), beganMatchMs = clients[0]!.matchTimeMs;
    const beganAuthorityTick = clients[0]!.latestAuthorityTick;
    for (const client of clients) client.beginMeasurement();
    shoot = true;
    await sleep(LOAD_MS);
    const activeElapsedMs = performance.now() - beganAt;
    const estimatedClockElapsedMs = clients[0]!.matchTimeMs - beganMatchMs;
    const observedAuthorityElapsedMs = (clients[0]!.latestAuthorityTick - beganAuthorityTick) * LIMITS.tickMs;
    shoot = false;
    for (const client of clients) client.endMeasurement();
    const runtimeProfile = await profile?.read() ?? null;
    await profile?.stop();
    // Continue fresh tracking while every in-flight projectile reaches a terminal.
    await sleep(ticket.rules.weapon.lifetimeMs + 500);
    pumping = false; await pump; await clockSync;
    await until(() => clients.every(client => client.pending.size === 0));
    const durable = await runInDurableObject(env.COMBAT_ROOMS.getByName(ticket.matchId), (_instance, state) => {
      const row = state.storage.sql.exec<{checkpoint: string; authority_epoch: number; event_sequence: number}>("SELECT checkpoint, authority_epoch, event_sequence FROM room WHERE singleton = 1").one();
      const checkpoint = JSON.parse(row.checkpoint) as {snapshot: CombatSnapshot};
      return {epoch: row.authority_epoch, sequence: row.event_sequence, snapshot: checkpoint.snapshot,
        ledger: state.storage.sql.exec<{sequence: number; payload: string}>("SELECT sequence, payload FROM bullet_events ORDER BY sequence").toArray(),
        bullets: state.storage.sql.exec<{count: number}>("SELECT COUNT(*) AS count FROM bullets").one().count,
        unresolved: state.storage.sql.exec<{count: number}>("SELECT COUNT(*) AS count FROM bullets WHERE terminal_sequence IS NULL").one().count,
        commands: state.storage.sql.exec<{count: number}>("SELECT COUNT(*) AS count FROM commands").one().count,
        projectionRows: state.storage.sql.exec<{count: number}>("SELECT COUNT(*) AS count FROM projection_outbox").one().count,
        projectionProgress: state.storage.sql.exec<{queued_sequence: number; delivered_sequence: number}>("SELECT queued_sequence, delivered_sequence FROM projection_progress").one(),
        checkpointBytes: new TextEncoder().encode(row.checkpoint).byteLength, databaseBytes: state.storage.sql.databaseSize};
    });
    await until(() => clients.every(client => client.latestEventSequence >= durable.sequence));
    const ledgerMatches = clients.map(client => durable.ledger.length === client.bulletEvents.size && durable.ledger.every(row => client.bulletEvents.get(row.sequence) === row.payload));
    const expectedShots = clients.flatMap(client => [...client.acceptedShotIds].map(shotId => JSON.stringify([client.playerId, shotId]))).sort();
    const storedEvents = durable.ledger.map(row => (JSON.parse(row.payload) as ServerEvent).event);
    const spawnedShots = storedEvents.flatMap(event => event.kind === "projectileSpawn" ? [JSON.stringify([event.projectile.shooterId, event.projectile.shotId])] : []).sort();
    const terminalShots = storedEvents.flatMap(event => event.kind === "projectileTerminal" ? [JSON.stringify([event.shooterId, event.shotId])] : []).sort();
    const acceptedFireCount = clients.reduce((sum, client) => sum + (client.accepted.fire ?? 0), 0);
    const shotIdentityMatches = {acceptedFireCount, uniqueAcceptedShots: expectedShots.length,
      spawnsMatchAccepted: JSON.stringify(expectedShots) === JSON.stringify(spawnedShots),
      terminalsMatchAccepted: JSON.stringify(expectedShots) === JSON.stringify(terminalShots)};
    const result = {scenario, activeLoadMs: LOAD_MS, activeElapsedMs, estimatedClockElapsedMs, observedAuthorityElapsedMs, runtimeProfile,
      limitations: ["local synthetic workerd; no device or cloud latency", "maximum synthetic collider payload, not camera coverage evidence", "delivery intervals are not server tick execution or CPU", "projection endpoint disabled; outbox persistence only"],
      offeredPoseIntervalMs: LIMITS.tickMs, expectedPosesPerPlayer: LOAD_MS / LIMITS.tickMs, missedPumpSlots,
      pumpLatenessMs: percentiles(pumpLateness),
      maximumInputBytes: Math.max(...clients.map(client => client.maximumInputBytes)),
      activeInputBytesIncludingReceiptsAndPings: clients.reduce((sum, client) => sum + client.measuredInputBytes, 0),
      activeOutputBytes: clients.reduce((sum, client) => sum + client.measuredOutputBytes, 0),
      players: clients.map(client => ({playerId: client.playerId, offered: client.offered, accepted: client.accepted, refusals: client.refusals,
        acknowledgmentMs: percentiles(client.acknowledgmentMs), commandResultMs: percentiles(client.resultMs),
        poseSendIntervalMs: percentiles(client.poseSendIntervalsMs), poseCaptureIntervalMs: percentiles(client.poseCaptureIntervalsMs),
        poseAgeAtResultMs: percentiles(client.poseAgeAtResultMs), clockSamples: client.clockSamples,
        poseAnomalies: client.poseAnomalies, phaseChanges: client.phaseChanges, diagnosticDrops: client.diagnosticDrops,
        observedTickDeliveryMs: percentiles(client.tickDeliveries.map(item => item.wallMs)),
        tickGaps: client.tickDeliveries.filter(item => item.ticks > 1).length, phaseWallMs: client.phaseWallMs,
        maximumProjectiles: client.maximumProjectiles, terminalReasons: client.terminalReasons,
        missingEvents: client.missingEvents, duplicateEvents: client.duplicateEvents, snapshotHealedEvents: client.snapshotHealedEvents,
        commands: client.totalSent, acknowledgments: client.totalAcknowledgments, results: client.totalResults})),
      durable: {authorityEpoch: durable.epoch, eventWatermark: durable.sequence, bulletCount: durable.bullets, ledgerEvents: durable.ledger.length,
        exactLedgerMatches: ledgerMatches, shotIdentityMatches, unresolvedBullets: durable.unresolved, retainedCommands: durable.commands,
        checkpointBytes: durable.checkpointBytes, databaseBytes: durable.databaseBytes, projectionRows: durable.projectionRows, projectionProgress: durable.projectionProgress},
      errors: [...clients.flatMap(client => client.errors), ...(clockFailure === null ? [] : [clockFailure]) ]};
    await annotate(JSON.stringify(result), "vkz-load");
    expect(result.errors).toEqual([]);
    expect(durable.epoch).toBe(1);
    expect(ledgerMatches).toEqual([true, true, true, true]);
    expect(durable.bullets).toBe(acceptedFireCount);
    expect(expectedShots).toHaveLength(acceptedFireCount);
    expect(spawnedShots).toEqual(expectedShots);
    expect(terminalShots).toEqual(expectedShots);
    expect(durable.unresolved).toBe(0);
    expect(durable.commands).toBeLessThanOrEqual(4 * LIMITS.commandHistory);
    expect(durable.checkpointBytes).toBeLessThan(32_768);
    // Delivered authority ticks establish progress independently of the driver's clock.
    expect(Math.abs(observedAuthorityElapsedMs - activeElapsedMs)).toBeLessThan(3 * LIMITS.tickMs);
    for (const client of clients) {
      expect(client.totalAcknowledgments).toBe(client.totalSent);
      expect(client.totalResults).toBe(client.totalSent);
      expect(client.missingEvents + client.duplicateEvents + client.snapshotHealedEvents).toBe(0);
      expect(client.accepted.pose ?? 0).toBeGreaterThanOrEqual(LOAD_MS / LIMITS.tickMs * 0.98);
      expect(client.phaseWallMs.running ?? 0).toBeGreaterThanOrEqual(activeElapsedMs * 0.99);
      expect(client.accepted.fire ?? 0).toBeGreaterThanOrEqual(Math.floor(LOAD_MS / 1000 * (mixed ? 0.5 : 2.8)));
      expect(client.accepted.slowField ?? 0).toBeGreaterThan(0);
      if (!mixed) expect(client.accepted.reload ?? 0).toBeGreaterThan(0);
    }
    expect(clients[0]!.terminalReasons.cancelled ?? 0).toBe(0);
    if (mixed) {
      expect(clients[0]!.terminalReasons.bodyHit ?? 0).toBeGreaterThan(0);
      expect(clients[0]!.terminalReasons.shieldBlocked ?? 0).toBeGreaterThan(0);
      expect(durable.snapshot.players.reduce((sum, player) => sum + player.deaths, 0)).toBeGreaterThan(0);
      expect(clients[1]!.accepted.shield ?? 0).toBeGreaterThan(0);
    }
  } finally {
    pumping = false;
    if (pump) await pump.catch(() => undefined);
    await clockSync;
    await profile?.stop();
    for (const client of clients) client.close();
  }
});
