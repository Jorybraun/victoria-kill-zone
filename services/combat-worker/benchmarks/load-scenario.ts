import {expect} from "vitest";
import {DEFAULT_RULES, LIMITS, type BodyObservation, type CombatTicketClaims, type Quaternion, type ServerEvent, type Vec3} from "@vkz/combat-protocol";
import {LoadClient, percentiles, sleep, until} from "./load-client.js";
import type {LoadRuntime} from "./load-runtime.js";
import type {RuntimeProfile} from "./runtime-profile.js";

const round = (value: number): number => Math.round(value * 1000) / 1000;
export const loadScenarios = ["miss-lanes", "opposing-combat"] as const;

/** Both process layouts execute exactly this gameplay workload and acceptance matrix. */
export async function runLoadScenario(scenario: typeof loadScenarios[number], LOAD_MS: number, runtime: LoadRuntime,
  annotate: (message: string, type: string) => Promise<unknown>, signal?: AbortSignal): Promise<void> {
  const mixed = scenario === "opposing-combat";
  const positions: Vec3[] = mixed ? [[-3, 1.3, 3], [-3, 1.3, -3], [3, 1.3, 3], [3, 1.3, -3]]
    : [[-6, 1.3, 0], [-2, 1.3, 0], [2, 1.3, 0], [6, 1.3, 0]];
  const roster = positions.map((_, index) => ({playerId: `load-${index}`, displayName: `Load ${index}`, role: index === 0 ? "host" as const : "player" as const}));
  const issuedAt = Math.floor(Date.now() / 1000);
  const ticket: CombatTicketClaims = {v: 1, iss: "vkz-lobby", aud: "vkz-combat", matchId: crypto.randomUUID(),
    playerId: roster[0]!.playerId, roster, authorityEpoch: 1, frameEpoch: 1, iat: issuedAt, exp: issuedAt + 120, nonce: crypto.randomUUID(),
    rules: {...structuredClone(DEFAULT_RULES), durationMs: LOAD_MS + 15_000, geometry: "trackedBody"}};
  const clients: LoadClient[] = [];
  const pumpLateness: number[] = [];
  let pumping = true, shoot = false, missedPumpSlots = 0;
  let pump: Promise<void> | undefined;
  let profile: RuntimeProfile | null = null;
  let annotated = false;
  let measurementStartedAt: number | null = null, measuredElapsedMs: number | null = null;
  let rejectDriver!: (error: Error) => void;
  const driverFailed = new Promise<never>((_resolve, reject) => {rejectDriver = reject;});
  void driverFailed.catch(() => undefined);
  let driverError: Error | null = null;
  const failDriver = (error: Error): void => {
    if (driverError !== null) return;
    driverError = error; pumping = false; rejectDriver(error);
  };
  const abort = (): void => {failDriver(new Error("Load cancelled"));};
  signal?.addEventListener("abort", abort, {once: true});
  if (signal?.aborted) abort();
  const guard = <T>(operation: Promise<T>): Promise<T> => Promise.race([operation, driverFailed]);
  const wait = async (milliseconds: number): Promise<void> => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {await Promise.race([new Promise<void>(resolve => {timer = setTimeout(resolve, milliseconds);}), driverFailed]);}
    finally {clearTimeout(timer);}
  };
  const barrier = (predicate: () => boolean): Promise<void> => until(() => {
    if (driverError !== null) throw driverError;
    return predicate();
  });
  const endMeasurement = (): void => {
    shoot = false;
    if (measurementStartedAt === null || measuredElapsedMs !== null) return;
    measuredElapsedMs = performance.now() - measurementStartedAt;
    for (const client of clients) client.endMeasurement();
  };
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
    if (signal?.aborted) throw new Error("Load cancelled");
    for (const member of roster) {
      const response = await guard(runtime.upgrade({...ticket, playerId: member.playerId}).then(upgraded => {
        if (driverError !== null && upgraded.webSocket?.readyState === 1) {
          upgraded.webSocket.accept(); upgraded.webSocket.close(1000, "load-cancelled");
        }
        return upgraded;
      }));
      expect(response.status).toBe(101);
      const client = new LoadClient(response.webSocket!, member.playerId, runtime.clockMode); clients.push(client);
      await barrier(() => client.snapshot !== null);
      await guard(client.bootstrapClock(failDriver));
      client.send({kind: "frameReady", ready: true, residualMeters: 0.01, residualDegrees: 0.1, clockUncertaintyMs: client.clockUncertaintyMs});
    }
    profile = await guard((async () => {
      const installed = await runtime.installProfile?.(ticket.matchId) ?? null;
      if (driverError !== null) {await installed?.stop(); throw new Error("Load interrupted during profile installation");}
      return installed;
    })());
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
        if (runtime.clockMode === "receiveAnchor" && began >= nextClockSync && !clockSyncPending) {
          clockSyncPending = true; nextClockSync = began + 1000;
          // Clock replies must not stop the independent 20 Hz tracking pump.
          clockSync = Promise.all(clients.map(client => client.synchronizeClock()))
            .then(() => undefined)
            .catch(() => {clockFailure = "clockSyncFailed"; failDriver(new Error("Clock synchronization failed"));})
            .finally(() => {clockSyncPending = false;});
        }
        await sleep(Math.max(1, due - performance.now()));
      }
    })();
    void pump.catch(error => {failDriver(error instanceof Error ? error : new Error("Tracking driver stopped"));});
    await barrier(() => clients.every(client => client.players.size === 4 && [...client.players.values()].every(player => player.frameReady)));
    clients[0]!.send({kind: "start"});
    await barrier(() => clients.every(client => client.phase === "running"));
    await wait(500); // Warmup is excluded from the measurement window.
    await guard(profile?.begin() ?? Promise.resolve());
    await guard(runtime.beginDiagnostics?.(ticket.matchId) ?? Promise.resolve());
    const beganAt = performance.now(), beganMatchMs = clients[0]!.matchTimeMs;
    measurementStartedAt = beganAt;
    const beganAuthorityTick = clients[0]!.latestAuthorityTick;
    for (const client of clients) client.beginMeasurement();
    shoot = true;
    await wait(LOAD_MS);
    const activeElapsedMs = performance.now() - beganAt;
    const estimatedClockElapsedMs = clients[0]!.matchTimeMs - beganMatchMs;
    const observedAuthorityElapsedMs = (clients[0]!.latestAuthorityTick - beganAuthorityTick) * LIMITS.tickMs;
    endMeasurement();
    const runtimeProfile = await guard(profile?.read() ?? Promise.resolve(null));
    await guard(profile?.stop() ?? Promise.resolve());
    // Continue fresh tracking while every in-flight projectile reaches a terminal.
    await wait(ticket.rules.weapon.lifetimeMs + 500);
    pumping = false; await pump; await clockSync;
    await barrier(() => clients.every(client => client.pending.size === 0));
    const durable = await guard(runtime.readDurable(ticket.matchId));
    await barrier(() => clients.every(client => client.latestEventSequence >= durable.sequence));
    const ledgerMatches = clients.map(client => durable.ledger.length === client.bulletEvents.size && durable.ledger.every(row => client.bulletEvents.get(row.sequence) === row.payload));
    const expectedShots = clients.flatMap(client => [...client.acceptedShotIds].map(shotId => JSON.stringify([client.playerId, shotId]))).sort();
    const storedEvents = durable.ledger.map(row => (JSON.parse(row.payload) as ServerEvent).event);
    const spawnedShots = storedEvents.flatMap(event => event.kind === "projectileSpawn" ? [JSON.stringify([event.projectile.shooterId, event.projectile.shotId])] : []).sort();
    const terminalShots = storedEvents.flatMap(event => event.kind === "projectileTerminal" ? [JSON.stringify([event.shooterId, event.shotId])] : []).sort();
    const acceptedFireCount = clients.reduce((sum, client) => sum + (client.accepted.fire ?? 0), 0);
    const shotIdentityMatches = {acceptedFireCount, uniqueAcceptedShots: expectedShots.length,
      spawnsMatchAccepted: JSON.stringify(expectedShots) === JSON.stringify(spawnedShots),
      terminalsMatchAccepted: JSON.stringify(expectedShots) === JSON.stringify(terminalShots)};
    const result = {scenario, environment: runtime.environment, clockMode: runtime.clockMode, activeLoadMs: LOAD_MS, activeElapsedMs, estimatedClockElapsedMs, observedAuthorityElapsedMs, runtimeProfile,
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
    await annotate(JSON.stringify(result), "vkz-load"); annotated = true;
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
  } catch (error) {
    pumping = false;
    endMeasurement();
    if (!annotated) await annotate(JSON.stringify({scenario, environment: runtime.environment, clockMode: runtime.clockMode,
      activeLoadMs: LOAD_MS, activeElapsedMs: measuredElapsedMs, interruptedBeforeReconciliation: true,
      failure: error instanceof Error ? error.message : "Load interrupted",
      players: clients.map(client => ({playerId: client.playerId, errors: client.errors, offered: client.offered,
        accepted: client.accepted, refusals: client.refusals, pendingCommands: client.pending.size,
        clockSamples: client.clockSamples, clockUncertaintyMs: Number.isFinite(client.clockUncertaintyMs) ? client.clockUncertaintyMs : null,
        phaseChanges: client.phaseChanges, phaseWallMs: client.phaseWallMs, terminalReasons: client.terminalReasons})),
    }), "vkz-load");
    throw error;
  } finally {
    signal?.removeEventListener("abort", abort);
    pumping = false;
    endMeasurement();
    for (const client of clients) client.close();
    if (pump) await pump.catch(() => undefined);
    await clockSync;
    await profile?.stop();
  }
}
