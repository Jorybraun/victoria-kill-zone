import {LIMITS, type AuthenticatedCommand, type CombatEvent, type CombatSnapshot} from "@vkz/combat-protocol";
import {CombatSimulation, type SimulationCheckpoint} from "@vkz/combat-simulation";
import {bodyAt, colliderPairs, phoneAt} from "../../../packages/combat-simulation/src/history.js";
import type {SerialQueue} from "../src/serial-queue.js";

export const TRACE_PREFIX = "VKZ_FIRST_PAUSE_V1 ";
export const ARM_PREFIX = "VKZ_PAUSE_TRACE_ARMED_V1 ";
const INPUT_LIMIT = 64, TICK_LIMIT = 8, LOG_BYTES = 32_768;
type Pending = {command: AuthenticatedCommand; tick: number};
export type ObservedRoom = {
  queue: Pick<SerialQueue, "run">;
  simulation: CombatSimulation | null;
  pending: readonly Pending[];
  cadence: {anchor: number};
};
type InputTiming = {
  playerId: string; clientSequence: number; kind: string;
  receivedAtMs: number; queueEnteredAtMs: number; admittedAtMs: number; queueDelayMs: number;
  sentAtMs: number; captureMs: number | null; poseSequence: number | null;
  plannedTick: number; consumedTick: number | null; accepted: boolean | null; refusal: string | null;
};
type TickTiming = {
  tick: number; matchTimeMs: number; enteredAtMs: number; cadenceAnchorMs: number; cadenceLagMs: number;
  pending: number; eligible: number; acceptedPoses: ReturnType<typeof acceptedPoses>;
};
export type FirstPauseTrace = {
  version: 1; units: "workerd monotonic milliseconds; client captures are logical match milliseconds";
  authorityEpoch: number; tick: number; matchTimeMs: number;
  reason: "spatialCoverageLost"; coverage: {fromMs: number; toMs: number; interval: boolean};
  failedPlayers: {playerId: string; connected: boolean; frameReady: boolean; health: number;
    phoneAtEnd: boolean; collidersCoverInterval: boolean;
    phoneSamples: {sequence: number; capturedAtMs: number; tracking: string}[];
    bodyHistories: {observerId: string; observerReady: boolean; observerPhoneAtEnd: boolean;
      coversFrom: boolean; coversTo: boolean; sampleTimesMs: number[]}[];
  }[];
  acceptedPoses: ReturnType<typeof acceptedPoses>;
  inputs: InputTiming[]; ticks: TickTiming[];
  commitSucceeded: boolean | null;
  droppedInputs: number; droppedTicks: number;
  limits: {inputs: number; ticks: number; logBytes: number};
};
export type TraceDiagnostics = {enabled: boolean; armed: boolean; traces: FirstPauseTrace[]; malformedRecords: number};

function stateOf(simulation: CombatSimulation): SimulationCheckpoint {
  return (simulation as unknown as {state: SimulationCheckpoint}).state;
}
function acceptedPoses(snapshot: CombatSnapshot) {
  return snapshot.phonePoses.slice(0, LIMITS.players).map(({playerId, pose}) => ({
    playerId, sequence: pose.sequence, capturedAtMs: pose.capturedAtMs, ageMs: snapshot.matchTimeMs - pose.capturedAtMs,
  }));
}

/** Read only metadata observers; production imports and entrypoints never install these. */
export function installFirstPauseTrace(room: ObservedRoom, emit: (record: FirstPauseTrace) => void) {
  const known = new WeakSet<object>();
  let armed = false, stopped = false, frozen = false;
  let inputs: InputTiming[] = [], ticks: TickTiming[] = [];
  let droppedInputs = 0, droppedTicks = 0;
  let first: FirstPauseTrace | null = null;
  const restorers: (() => void)[] = [];
  type Method = (this: unknown, ...args: unknown[]) => unknown;
  const wrap = (target: object, key: string, hooks: {
    eligible?: (receiver: unknown) => boolean;
    before?: (args: unknown[]) => void;
    after?: (args: unknown[], result: unknown, failed: boolean) => void;
  }) => {
    const original: unknown = Reflect.get(target, key);
    if (typeof original !== "function") throw new Error(`Trace method unavailable: ${key}`);
    const descriptor = Object.getOwnPropertyDescriptor(target, key), method = original as Method;
    const wrapper: Method = function (...args) {
      if (!armed || frozen || (hooks.eligible && !hooks.eligible(this))) return method.apply(this, args);
      hooks.before?.(args);
      let result: unknown;
      try {result = method.apply(this, args);}
      catch (error) {hooks.after?.(args, undefined, true); throw error;}
      if (result instanceof Promise) {
        // Preserve the exact original promise, including original failure behavior.
        void result.then(value => {hooks.after?.(args, value, false);}, () => {hooks.after?.(args, undefined, true);});
      } else hooks.after?.(args, result, false);
      return result;
    };
    Object.defineProperty(target, key, {configurable: true, writable: true, value: wrapper});
    restorers.push(() => {
      if (descriptor) Object.defineProperty(target, key, descriptor);
      else Reflect.deleteProperty(target, key);
    });
  };
  const eligible = (receiver: unknown) => receiver === room.simulation
    || (typeof receiver === "object" && receiver !== null && known.has(receiver));
  const prototype = CombatSimulation.prototype;
  wrap(prototype, "fork", {eligible, after: (_args, result, failed) => {
    if (!failed && typeof result === "object" && result !== null) known.add(result);
  }});
  let activeQueueEntry: number | null = null;
  wrap(room.queue, "run", {before: args => {
    const callback = args[0] as () => unknown;
    args[0] = () => {
      activeQueueEntry = performance.now();
      try {return callback();} finally {activeQueueEntry = null;}
    };
  }});
  let admittedAtMs = 0, queueEnteredAtMs = 0;
  wrap(room, "admitCommand", {before: () => {
    admittedAtMs = performance.now(); queueEnteredAtMs = activeQueueEntry ?? admittedAtMs;
  }, after: (args, _result, failed) => {
    if (failed) return;
    const command = args[1] as AuthenticatedCommand, receivedAtMs = args[2] as number;
    const pending = room.pending.at(-1);
    if (!pending || pending.command.commandId !== command.commandId
      || inputs.some(item => item.playerId === pending.command.playerId && item.clientSequence === command.clientSequence)) return;
    const pose = command.command.kind === "pose" ? command.command.pose : null;
    inputs.push({playerId: pending.command.playerId, clientSequence: command.clientSequence, kind: command.command.kind,
      receivedAtMs, queueEnteredAtMs, admittedAtMs, queueDelayMs: queueEnteredAtMs - receivedAtMs, sentAtMs: command.sentAtMs,
      captureMs: pose?.capturedAtMs ?? null, poseSequence: pose?.sequence ?? null,
      plannedTick: pending.tick, consumedTick: null, accepted: null, refusal: null});
    if (inputs.length > INPUT_LIMIT) {inputs.shift(); droppedInputs++;}
  }});
  wrap(room, "tick", {before: () => {
    if (!room.simulation) return;
    known.add(room.simulation);
    const snapshot = stateOf(room.simulation).snapshot, enteredAtMs = performance.now();
    ticks.push({tick: snapshot.tick + 1, matchTimeMs: snapshot.matchTimeMs + LIMITS.tickMs,
      enteredAtMs, cadenceAnchorMs: room.cadence.anchor, cadenceLagMs: enteredAtMs - room.cadence.anchor,
      pending: room.pending.length, eligible: room.pending.filter(item => item.tick <= snapshot.tick + 1).length,
      acceptedPoses: acceptedPoses(snapshot)});
    if (ticks.length > TICK_LIMIT) {ticks.shift(); droppedTicks++;}
  }});
  // Capture the exact failed invocation, before pause() clears projectiles.
  const coverageOriginal: unknown = Reflect.get(prototype, "coverage");
  if (typeof coverageOriginal !== "function") throw new Error("Trace coverage method unavailable");
  const coverageDescriptor = Object.getOwnPropertyDescriptor(prototype, "coverage");
  const coverage = coverageOriginal as Method;
  Object.defineProperty(prototype, "coverage", {configurable: true, writable: true, value: function (this: CombatSimulation, ...args: unknown[]) {
    const result = coverage.apply(this, args);
    if (!armed || frozen || first || result !== false || !eligible(this)) return result;
    const state = stateOf(this), snapshot = state.snapshot;
    if (snapshot.phase !== "running") return result;
    const [fromMs, toMs] = args as [number, number];
    const interval = args[2] === true, start = interval ? fromMs : toMs;
    const failedPlayers = snapshot.players.slice(0, LIMITS.players).flatMap(player => {
      const phoneAtEnd = phoneAt(state, player.playerId, toMs) !== null;
      const collidersCoverInterval = colliderPairs(state, player.playerId, start, toMs) !== null;
      if (player.connected && player.frameReady && (player.health <= 0 || (phoneAtEnd && collidersCoverInterval))) return [];
      return [{playerId: player.playerId, connected: player.connected, frameReady: player.frameReady, health: player.health,
        phoneAtEnd, collidersCoverInterval,
        phoneSamples: (state.phones.find(item => item.playerId === player.playerId)?.samples ?? []).slice(-16)
          .map(pose => ({sequence: pose.sequence, capturedAtMs: pose.capturedAtMs, tracking: pose.tracking})),
        bodyHistories: state.bodies.filter(history => history.targetId === player.playerId).slice(0, LIMITS.players - 1).map(history => {
          const observer = snapshot.players.find(item => item.playerId === history.observerId);
          return {observerId: history.observerId, observerReady: Boolean(observer?.connected && observer.frameReady),
            observerPhoneAtEnd: phoneAt(state, history.observerId, snapshot.matchTimeMs) !== null,
            coversFrom: bodyAt(history, start) !== null, coversTo: bodyAt(history, toMs) !== null,
            sampleTimesMs: history.samples.slice(-16).map(sample => sample.capturedAtMs)};
        })}];
    });
    first = {version: 1, units: "workerd monotonic milliseconds; client captures are logical match milliseconds",
      authorityEpoch: snapshot.authorityEpoch, tick: snapshot.tick, matchTimeMs: snapshot.matchTimeMs,
      reason: "spatialCoverageLost", coverage: {fromMs, toMs, interval}, failedPlayers,
      acceptedPoses: acceptedPoses(snapshot), inputs: [], ticks: [], commitSucceeded: null,
      droppedInputs, droppedTicks, limits: {inputs: INPUT_LIMIT, ticks: TICK_LIMIT, logBytes: LOG_BYTES}};
    return result;
  }});
  restorers.push(() => {
    if (coverageDescriptor) Object.defineProperty(prototype, "coverage", coverageDescriptor);
  });
  wrap(room, "commitCandidate", {before: args => {
    const candidate = args[0] as CombatSimulation, events = args[1] as readonly CombatEvent[];
    const tick = stateOf(candidate).snapshot.tick;
    for (const event of events) if (event.kind === "commandResult") {
      const input = inputs.find(item => item.playerId === event.playerId && item.clientSequence === event.clientSequence);
      if (input) {input.consumedTick = tick; input.accepted = event.accepted; input.refusal = event.reason;}
    }
  }, after: (args, _result, failed) => {
    if (!first || first.tick !== stateOf(args[0] as CombatSimulation).snapshot.tick) return;
    const events = args[1] as readonly CombatEvent[];
    if (!events.some(event => event.kind === "phaseChanged" && event.phase === "paused" && event.reason === "spatialCoverageLost")) return;
    first.inputs = structuredClone(inputs); first.ticks = structuredClone(ticks); first.commitSucceeded = !failed;
    first.droppedInputs = droppedInputs; first.droppedTicks = droppedTicks;
    // A single bounded log record cannot contain geometry, envelopes or credentials.
    const bytes = () => new TextEncoder().encode(JSON.stringify(first)).byteLength;
    while (bytes() > LOG_BYTES && first.inputs.length) {first.inputs.shift(); first.droppedInputs++;}
    while (bytes() > LOG_BYTES && first.ticks.length) {first.ticks.shift(); first.droppedTicks++;}
    frozen = true; emit(first);
  }});
  return {
    begin() {
      if (stopped) throw new Error("Trace already stopped");
      armed = true; frozen = false; first = null; inputs = []; ticks = []; droppedInputs = 0; droppedTicks = 0;
      if (room.simulation) known.add(room.simulation);
    },
    stop() {if (stopped) return; stopped = true; armed = false; for (const restore of restorers.reverse()) restore();},
  };
}

/** Parse only our bounded diagnostic records, never forward arbitrary harness logs. */
export function collectTraceLogs(logs: readonly {message: string}[]): TraceDiagnostics {
  const traces: FirstPauseTrace[] = [];
  let armed = false, malformedRecords = 0;
  for (const {message} of logs) {
    if (message.startsWith(ARM_PREFIX)) armed = true;
    if (!message.startsWith(TRACE_PREFIX)) continue;
    try {
      if (new TextEncoder().encode(message.slice(TRACE_PREFIX.length)).byteLength > LOG_BYTES) throw new Error("Trace too large");
      const value: unknown = JSON.parse(message.slice(TRACE_PREFIX.length));
      if (!value || typeof value !== "object" || !("version" in value) || value.version !== 1
        || !("reason" in value) || value.reason !== "spatialCoverageLost") throw new Error("Invalid trace");
      if (traces.length < 1) traces.push(value as FirstPauseTrace);
    } catch {malformedRecords++;}
  }
  return {enabled: true, armed, traces, malformedRecords};
}
