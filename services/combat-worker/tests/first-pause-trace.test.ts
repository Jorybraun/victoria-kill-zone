import {afterEach, describe, expect, it, vi} from "vitest";
import {DEFAULT_RULES, type AuthenticatedCommand, type CombatEvent, type CommandEnvelope} from "@vkz/combat-protocol";
import {CombatSimulation} from "@vkz/combat-simulation";
import {SerialQueue} from "../src/serial-queue.js";
import {ARM_PREFIX, TRACE_PREFIX, collectTraceLogs, installFirstPauseTrace, type FirstPauseTrace} from "../benchmarks/first-pause-trace.js";

afterEach(() => {vi.restoreAllMocks();});

function command(playerId: string, clientSequence: number, payload: CommandEnvelope["command"]): AuthenticatedCommand {
  return {v: 1, playerId, clientSequence, commandId: `${playerId}-${clientSequence}`, authorityEpoch: 1, frameEpoch: 1,
    sentAtMs: 0, command: payload};
}
function fixture() {
  const simulation = CombatSimulation.create({matchId: "trace-test", authorityEpoch: 1, frameEpoch: 1,
    rules: {...DEFAULT_RULES, geometry: "phoneProxy"}, players: [
      {playerId: "host", displayName: "Host", role: "host"}, {playerId: "guest", displayName: "Guest", role: "player"},
    ]});
  for (const id of ["host", "guest"]) simulation.setConnected(id, true);
  const setup = ["host", "guest"].flatMap((id, index) => [
    command(id, 1, {kind: "frameReady", ready: true, residualMeters: 0.01, residualDegrees: 0.1, clockUncertaintyMs: 1}),
    command(id, 2, {kind: "pose", observations: [], pose: {sequence: 1, capturedAtMs: 0,
      position: [index * 10, 0, 0], orientation: [0, 0, 0, 1], tracking: "normal"}}),
  ]);
  simulation.advance([...setup, command("host", 3, {kind: "start"})]);
  expect(simulation.snapshot().phase).toBe("running");
  return {
    simulation, pending: [] as {command: AuthenticatedCommand; tick: number}[],
    queue: new SerialQueue(), cadence: {anchor: 50},
    admitCommand(_connection: unknown, envelope: AuthenticatedCommand, _receivedAtMs: number) {
      void _receivedAtMs;
      this.pending.push({command: envelope, tick: this.simulation.snapshot().tick + 1});
    },
    tick() {
      const candidate = this.simulation.fork(), events = candidate.advance(this.pending.map(item => item.command));
      return this.commitCandidate(candidate, events, this.pending).then(() => {this.pending = [];});
    },
    commitCandidate(candidate: CombatSimulation, _events: readonly CombatEvent[], _pending: readonly {command: AuthenticatedCommand; tick: number}[]) {
      void _events; void _pending;
      this.simulation = candidate;
      return Promise.resolve();
    },
  };
}

describe("benchmark first-pause observer", () => {
  it("preserves simulation behavior and records queue delay, consumed tick and expired coverage", async () => {
    const room = fixture(), baseline = fixture(), reports: FirstPauseTrace[] = [];
    const original = Reflect.get(room, "tick") as unknown;
    const observer = installFirstPauseTrace(room, record => {reports.push(record);});
    try {
      observer.begin();
      vi.spyOn(performance, "now").mockReturnValue(91);
      const input = command("host", 4, {kind: "reload"});
      await room.queue.run(() => {
        vi.spyOn(performance, "now").mockReturnValue(94);
        room.admitCommand(null, input, 70);
      });
      baseline.admitCommand(null, input, 70);
      await room.tick(); await baseline.tick();
      expect(room.simulation.snapshot()).toEqual(baseline.simulation.snapshot());
      expect(reports).toEqual([]);
      vi.spyOn(performance, "now").mockReturnValue(151);
      await room.tick(); await baseline.tick();
      expect(room.simulation.snapshot()).toEqual(baseline.simulation.snapshot());
      expect(reports).toHaveLength(1);
      expect(reports[0]).toMatchObject({tick: 3, matchTimeMs: 150, commitSucceeded: true,
        coverage: {fromMs: 100, toMs: 150, interval: false},
        inputs: [{receivedAtMs: 70, queueEnteredAtMs: 91, admittedAtMs: 94, queueDelayMs: 21,
          plannedTick: 2, consumedTick: 2, accepted: false}],
        failedPlayers: [{playerId: "guest", phoneAtEnd: false}, {playerId: "host", phoneAtEnd: false}]});
      expect(reports[0]!.acceptedPoses.every(pose => pose.ageMs === 150)).toBe(true);
      const serialized = JSON.stringify(reports);
      expect(serialized).not.toContain('"position"');
      expect(serialized).not.toContain('"orientation"');
      await room.tick();
      expect(JSON.stringify(reports)).toBe(serialized);
    } finally {observer.stop();}
    expect(Reflect.get(room, "tick")).toBe(original);
  });

  it("ignores warmup and bounds the retained input and tick histories", async () => {
    const warmup = fixture(), warmupReports: FirstPauseTrace[] = [];
    const warmupObserver = installFirstPauseTrace(warmup, record => {warmupReports.push(record);});
    try {await warmup.tick(); await warmup.tick(); expect(warmupReports).toEqual([]);}
    finally {warmupObserver.stop();}
    const room = fixture(), reports: FirstPauseTrace[] = [];
    const observer = installFirstPauseTrace(room, record => {reports.push(record);});
    try {
      observer.begin();
      for (let sequence = 4; sequence < 44; sequence++) room.admitCommand(null, command("host", sequence, {kind: "reload"}), 70);
      await room.tick();
      for (let sequence = 44; sequence < 84; sequence++) room.admitCommand(null, command("host", sequence, {kind: "reload"}), 120);
      await room.tick();
      expect(reports).toHaveLength(1);
      expect(reports[0]!.inputs).toHaveLength(64);
      expect(reports[0]!.droppedInputs).toBe(16);
      expect(new TextEncoder().encode(JSON.stringify(reports[0])).byteLength).toBeLessThanOrEqual(32_768);
    } finally {observer.stop();}
  });

  it("retains only the latest eight ticks before the first pause", async () => {
    const room = fixture(), reports: FirstPauseTrace[] = [];
    const observer = installFirstPauseTrace(room, record => {reports.push(record);});
    try {
      observer.begin();
      for (let tick = 2; tick <= 11; tick++) {
        for (const [index, id] of ["host", "guest"].entries()) {
          const input = command(id, tick + 2, {kind: "pose", observations: [], pose: {sequence: tick,
            capturedAtMs: (tick - 1) * 50, position: [index * 10, 0, 0], orientation: [0, 0, 0, 1], tracking: "normal"}});
          input.sentAtMs = (tick - 1) * 50;
          room.admitCommand(null, input, (tick - 1) * 50);
        }
        await room.tick();
      }
      await room.tick(); await room.tick();
      expect(reports).toHaveLength(1);
      expect(reports[0]!.ticks).toHaveLength(8);
      expect(reports[0]!.droppedTicks).toBe(4);
    } finally {observer.stop();}
  });

  it("returns the original durable commit promise and records its rejection", async () => {
    const room = fixture(), reports: FirstPauseTrace[] = [];
    let reject!: (error: Error) => void;
    const commit = new Promise<void>((_resolve, no) => {reject = no;});
    room.commitCandidate = () => commit;
    const observer = installFirstPauseTrace(room, record => {reports.push(record);});
    try {
      observer.begin();
      const candidate = room.simulation.fork();
      candidate.advance([]);
      const events = candidate.advance([]);
      const actual = room.commitCandidate(candidate, events, []);
      expect(actual).toBe(commit);
      const failure = new Error("fixture commit failed");
      reject(failure);
      await expect(actual).rejects.toBe(failure);
      expect(reports).toHaveLength(1);
      expect(reports[0]!.commitSucceeded).toBe(false);
    } finally {observer.stop();}
  });

  it("collects only bounded trace logs while preserving an explicit unarmed/malformed result", () => {
    expect(collectTraceLogs([{message: "unrelated runtime log"}])).toEqual({enabled: true, armed: false, traces: [], malformedRecords: 0});
    expect(collectTraceLogs([{message: ARM_PREFIX + "{}"}, {message: TRACE_PREFIX + "not-json"},
      {message: TRACE_PREFIX + "x".repeat(32_769)}])).toEqual({enabled: true, armed: true, traces: [], malformedRecords: 2});
  });
});
