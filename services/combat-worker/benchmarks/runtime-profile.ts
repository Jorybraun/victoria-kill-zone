import { env } from "cloudflare:workers";
import { runInDurableObject } from "cloudflare:test";
import { LIMITS, type AuthenticatedCommand, type CombatEvent, type CombatSnapshot } from "@vkz/combat-protocol";
import type { CombatSimulation } from "@vkz/combat-simulation";
import type { SerialQueue } from "../src/serial-queue.js";
import type { RoomStore } from "../src/store.js";

const BUCKETS_MS = [0, 0.25, 0.5, 1, 2, 4, 8, 16, 32, 64, 100, 128, 250, 500, 1000] as const;
const MAX_PAUSES = 64;
type Method = (this: unknown, ...args: unknown[]) => unknown;
type Pending = { command: AuthenticatedCommand };
type Room = {
  queue: Pick<SerialQueue, "run">;
  store: RoomStore;
  simulation: CombatSimulation | null;
  pending: readonly Pending[];
  cadence: { anchor: number };
};
type SimulationView = { state: { snapshot: CombatSnapshot } };

export type RuntimeTiming = {
  calls: number;
  completed: number;
  failures: number;
  sumMs: number;
  maxMs: number;
  /** Fixed buckets count every completed call, including the open-ended final bucket. */
  histogram: { upperBoundMs: number | null; count: number }[];
};
type PoseTiming = {
  playerId: string;
  sequence: number;
  capturedAtMs: number;
  ageMs: number;
  envelopeAgeMs: number;
};
type TickInputs = {
  tick: number;
  matchTimeMs: number;
  commands: number;
  poses: PoseTiming[];
};
export type CoveragePauseProfile = {
  tick: number;
  matchTimeMs: number;
  reason: string;
  cadenceLagMs: number;
  activeProjectilesBeforeTick: number;
  inputs: TickInputs;
  priorTick: TickInputs | null;
  latestAdmittedPoses: PoseTiming[];
  latestAcceptedPoses: { playerId: string; sequence: number; capturedAtMs: number; ageMs: number }[];
  commitSucceeded: boolean;
};
export type RuntimeProfileReport = {
  units: "local elapsed wall milliseconds, not CPU or cloud latency";
  clockProbe: {
    iterationsPerBatch: number;
    performanceDeltasMs: number[];
    dateDeltasMs: number[];
    smallestObservedPositiveStepMs: number | null;
    advancesDuringSynchronousWork: boolean;
    checksum: number;
  };
  timings: Record<string, RuntimeTiming>;
  coveragePauseCount: number;
  coveragePauses: CoveragePauseProfile[];
  coveragePausesOmitted: number;
  limits: { pauseRecords: number; posesPerTickRecord: number; rawDurationSamples: 0 };
};
export type RuntimeProfile = {
  begin(): Promise<void>;
  read(): Promise<RuntimeProfileReport>;
  stop(): Promise<void>;
};

function clockProbe(): RuntimeProfileReport["clockProbe"] {
  const iterationsPerBatch = 250_000;
  const performanceDeltasMs: number[] = [], dateDeltasMs: number[] = [];
  let checksum = 1, smallestObservedPositiveStepMs: number | null = null;
  for (let batch = 0; batch < 4; batch++) {
    const start = performance.now(), dateStart = Date.now();
    let previous = start;
    for (let index = 0; index < iterationsPerBatch; index++) {
      checksum = (Math.imul(checksum, 1_664_525) + 1_013_904_223) >>> 0;
      if (index % 4096 === 0) {
        const now = performance.now(), delta = now - previous;
        if (delta > 0) smallestObservedPositiveStepMs = Math.min(smallestObservedPositiveStepMs ?? delta, delta);
        previous = now;
      }
    }
    performanceDeltasMs.push(performance.now() - start);
    dateDeltasMs.push(Date.now() - dateStart);
  }
  return { iterationsPerBatch, performanceDeltasMs, dateDeltasMs, smallestObservedPositiveStepMs,
    advancesDuringSynchronousWork: performanceDeltasMs.some(value => value > 0), checksum };
}

/**
 * Benchmark-only observers: no timer, cadence, command, storage, or simulation changes.
 * Install after admission. The bounded synchronous clock probe runs before measurement.
 * Async wrappers return the original promise; synchronous wrappers add no await.
 * Prototype observers only include this room's simulation and its forked candidates.
 */
export async function installRuntimeProfile(matchId: string): Promise<RuntimeProfile> {
  const stub = env.COMBAT_ROOMS.getByName(matchId);
  const restorers: (() => void)[] = [];
  const simulations = new WeakSet<object>();
  const timings: Record<string, RuntimeTiming> = {};
  const admitted = new Map<string, { sequence: number; capturedAtMs: number; sentAtMs: number }>();
  let enabled = false, stopped = false, generation = 0, pauseCount = 0;
  let pauses: CoveragePauseProfile[] = [], priorTick: TickInputs | null = null;
  let tickLagMs = 0, activeProjectilesBeforeTick = 0;
  let probe: RuntimeProfileReport["clockProbe"];
  let room: Room;

  const metric = (name: string): RuntimeTiming => timings[name] ??= {
    calls: 0, completed: 0, failures: 0, sumMs: 0, maxMs: 0,
    histogram: [...BUCKETS_MS.map(upperBoundMs => ({ upperBoundMs, count: 0 })), { upperBoundMs: null, count: 0 }],
  };
  const duration = (name: string, elapsed: number, failed = false): void => {
    const value = Math.max(0, elapsed), target = metric(name);
    target.completed++; target.failures += Number(failed); target.sumMs += value; target.maxMs = Math.max(target.maxMs, value);
    const bucket = target.histogram.find(item => item.upperBoundMs === null || value <= item.upperBoundMs);
    if (bucket) bucket.count++;
  };
  const stateOf = (simulation: unknown): CombatSnapshot => (simulation as SimulationView).state.snapshot;
  const summarize = (snapshot: CombatSnapshot, pending: readonly Pending[]): TickInputs => ({
    tick: snapshot.tick, matchTimeMs: snapshot.matchTimeMs, commands: pending.length,
    poses: pending.slice(0, LIMITS.commandsPerTick).flatMap(({ command }) => command.command.kind === "pose" ? [{
      playerId: command.playerId, sequence: command.command.pose.sequence, capturedAtMs: command.command.pose.capturedAtMs,
      ageMs: snapshot.matchTimeMs - command.command.pose.capturedAtMs, envelopeAgeMs: snapshot.matchTimeMs - command.sentAtMs,
    }] : []),
  });
  const observeCommit = (args: unknown[]): CoveragePauseProfile[] => {
    const candidate = args[0] as CombatSimulation;
    simulations.add(candidate);
    if (!enabled) return [];
    const events = args[1] as readonly CombatEvent[], pending = args[2] as readonly Pending[];
    const snapshot = stateOf(candidate), inputs = summarize(snapshot, pending);
    const records: CoveragePauseProfile[] = [];
    for (const event of events) {
      if (event.kind !== "phaseChanged" || event.phase !== "paused" || event.reason !== "spatialCoverageLost") continue;
      pauseCount++;
      if (pauses.length >= MAX_PAUSES) continue;
      const record: CoveragePauseProfile = {
        tick: snapshot.tick, matchTimeMs: snapshot.matchTimeMs, reason: event.reason, cadenceLagMs: tickLagMs,
        activeProjectilesBeforeTick, inputs, priorTick, commitSucceeded: false,
        latestAdmittedPoses: [...admitted].slice(0, LIMITS.players).map(([playerId, pose]) => ({
          playerId, sequence: pose.sequence, capturedAtMs: pose.capturedAtMs,
          ageMs: snapshot.matchTimeMs - pose.capturedAtMs, envelopeAgeMs: snapshot.matchTimeMs - pose.sentAtMs,
        })),
        latestAcceptedPoses: snapshot.phonePoses.slice(0, LIMITS.players).map(({ playerId, pose }) => ({
          playerId, sequence: pose.sequence, capturedAtMs: pose.capturedAtMs, ageMs: snapshot.matchTimeMs - pose.capturedAtMs,
        })),
      };
      pauses.push(record); records.push(record);
    }
    if (priorTick === null || snapshot.tick > priorTick.tick) priorTick = inputs;
    return records;
  };

  type Hooks = {
    eligible?: (receiver: unknown) => boolean;
    before?: (receiver: unknown, args: unknown[]) => unknown;
    after?: (receiver: unknown, args: unknown[], result: unknown, context: unknown, failed: boolean) => void;
  };
  const wrap = (target: object, key: string, name: string, hooks: Hooks = {}): void => {
    const original: unknown = Reflect.get(target, key);
    if (typeof original !== "function") throw new Error(`Profiling method unavailable: ${name}`);
    const method = original as Method, descriptor = Object.getOwnPropertyDescriptor(target, key);
    const wrapper: Method = function (...args) {
      if (hooks.eligible && !hooks.eligible(this)) return method.apply(this, args);
      const measured = enabled, startedGeneration = generation;
      const context = hooks.before?.(this, args), start = performance.now();
      if (measured) metric(name).calls++;
      const complete = (result: unknown, failed: boolean): void => {
        if (measured && generation === startedGeneration) duration(name, performance.now() - start, failed);
        hooks.after?.(this, args, result, context, failed);
      };
      let result: unknown;
      try { result = method.apply(this, args); }
      catch (error) { complete(undefined, true); throw error; }
      if (result instanceof Promise) {
        // Observe settlement without changing promise identity or adding an await.
        void result.then(value => { complete(value, false); }, () => { complete(undefined, true); });
      } else complete(result, false);
      return result;
    };
    Object.defineProperty(target, key, { configurable: true, writable: true, value: wrapper });
    restorers.push(() => {
      if (Reflect.get(target, key) !== wrapper) throw new Error(`Profiling method changed before teardown: ${name}`);
      if (descriptor) Object.defineProperty(target, key, descriptor);
      else Reflect.deleteProperty(target, key);
    });
  };

  await runInDurableObject(stub, async instance => {
    room = instance as unknown as Room;
    await room.queue.run(() => {
      if (room.simulation === null) throw new Error("Install runtime profile after client admission");
      probe = clockProbe();
      simulations.add(room.simulation);
      try {
        wrap(room, "tick", "room.tick", { before: () => {
          if (room.simulation !== null) simulations.add(room.simulation);
          if (!enabled || room.simulation === null) return;
          tickLagMs = Math.max(0, performance.now() - room.cadence.anchor);
          activeProjectilesBeforeTick = stateOf(room.simulation).projectiles.length;
          metric("tick.cadenceLag").calls++; duration("tick.cadenceLag", tickLagMs);
        } });
        wrap(room, "admitCommand", "room.admitCommand", {
          before: () => room.pending.length,
          after: (_receiver, _args, _result, before, failed) => {
            if (failed || room.pending.length !== Number(before) + 1) return;
            const envelope = room.pending.at(-1)?.command;
            if (envelope?.command.kind !== "pose" || (!admitted.has(envelope.playerId) && admitted.size >= LIMITS.players)) return;
            admitted.set(envelope.playerId, { sequence: envelope.command.pose.sequence,
              capturedAtMs: envelope.command.pose.capturedAtMs, sentAtMs: envelope.sentAtMs });
          },
        });
        wrap(room, "commitCandidate", "room.commitCandidate", {
          before: (_receiver, args) => observeCommit(args),
          after: (_receiver, _args, _result, context, failed) => {
            if (!failed) for (const record of context as CoveragePauseProfile[]) record.commitSucceeded = true;
          },
        });
        wrap(room, "broadcast", "room.broadcast");
        for (const key of ["findCommand", "sequence", "commit"]) wrap(room.store, key, `store.${key}`);
        wrap(room.store.projections, "append", "projection.append");
        const prototype = Object.getPrototypeOf(room.simulation) as object;
        for (const key of ["fork", "advance", "checkpoint", "snapshot"]) wrap(prototype, key, `simulation.${key}`, {
          eligible: receiver => typeof receiver === "object" && receiver !== null && simulations.has(receiver),
          after: (_receiver, _args, result, _context, failed) => {
            if (key === "fork" && !failed && typeof result === "object" && result !== null) simulations.add(result);
          },
        });
      } catch (error) {
        for (const restore of restorers.reverse()) restore();
        throw error;
      }
    });
  });

  const inRoom = async <T>(action: () => T): Promise<T> => runInDurableObject(stub, instance => {
    if ((instance as unknown) !== room) throw new Error("Profiled authority instance was replaced");
    return room.queue.run(action);
  });
  return {
    begin: () => inRoom(() => {
      if (stopped) throw new Error("Runtime profile already stopped");
      generation++; for (const key of Object.keys(timings)) delete timings[key];
      pauseCount = 0; pauses = []; priorTick = null; enabled = true;
    }),
    read: () => inRoom(() => structuredClone({
      units: "local elapsed wall milliseconds, not CPU or cloud latency" as const,
      clockProbe: probe, timings, coveragePauseCount: pauseCount, coveragePauses: pauses,
      coveragePausesOmitted: pauseCount - pauses.length,
      limits: { pauseRecords: MAX_PAUSES, posesPerTickRecord: LIMITS.commandsPerTick, rawDurationSamples: 0 as const },
    })),
    stop: () => inRoom(() => {
      if (stopped) return;
      enabled = false; generation++; stopped = true;
      for (const restore of restorers.reverse()) restore();
    }),
  };
}
