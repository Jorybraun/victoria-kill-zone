import {afterEach, beforeEach, describe, expect, it, vi} from "vitest";
import {CombatSimulation} from "@vkz/combat-simulation";
import type {ClientMessage, CombatEvent, CombatSnapshot, CombatTicketClaims, ServerMessage} from "@vkz/combat-protocol";
import {LoadClient, type LoadSocket} from "../benchmarks/load-client.js";
import type {DurableLoadState, LoadRuntime} from "../benchmarks/load-runtime.js";
import {runLoadScenario} from "../benchmarks/load-scenario.js";
import type {RuntimeProfile} from "../benchmarks/runtime-profile.js";

type InterruptedReport = {
  activeLoadMs: number;
  activeElapsedMs: number | null;
  interruptedBeforeReconciliation: boolean;
  failure: string;
  players: {phaseWallMs: Record<string, number>}[];
};

beforeEach(() => {vi.useFakeTimers({toFake: ["setTimeout", "clearTimeout", "Date", "performance"]});});
afterEach(() => {vi.useRealTimers(); vi.restoreAllMocks();});

describe("load scenario lifecycle", () => {
  for (const duration of [30_000, 180_000]) {
    for (const failure of ["clock", "abort"] as const) {
      it(`clears the ${duration} ms active timer and finalizes phase time after ${failure} failure`, async () => {
        const fixture = lifecycleRuntime();
        const controller = new AbortController();
        const failureCallbacks: ((error: Error) => void)[] = [];
        vi.spyOn(LoadClient.prototype, "bootstrapClock").mockImplementation(onFailure => {
          if (onFailure) failureCallbacks.push(onFailure);
          return Promise.resolve();
        });
        const begins = vi.spyOn(LoadClient.prototype, "beginMeasurement");
        const ends = vi.spyOn(LoadClient.prototype, "endMeasurement");
        const removeListener = vi.spyOn(controller.signal, "removeEventListener");
        const reports: InterruptedReport[] = [];
        const completed = runLoadScenario("miss-lanes", duration, fixture.runtime, message => {
          reports.push(JSON.parse(message) as InterruptedReport);
          return Promise.resolve();
        }, controller.signal).then(() => null, (error: unknown) => error);

        await vi.advanceTimersByTimeAsync(600);
        expect(begins).toHaveBeenCalledTimes(4);
        expect(reports).toHaveLength(0);
        for (const socket of fixture.sockets) socket.phase("paused");
        await vi.advanceTimersByTimeAsync(40);
        const message = failure === "clock" ? "Clock quality lost" : "Load cancelled";
        if (failure === "clock") {
          expect(failureCallbacks).toHaveLength(4);
          failureCallbacks[0]!(new Error(message));
        } else controller.abort();
        // Teardown may await the final 50 ms pose-pump slot, never the active window.
        await vi.advanceTimersByTimeAsync(50);
        expect(await completed).toEqual(new Error(message));
        expect(reports).toHaveLength(1);
        expect(reports[0]).toMatchObject({activeLoadMs: duration, activeElapsedMs: 140,
          interruptedBeforeReconciliation: true, failure: message});
        for (const player of reports[0]!.players) expect(player.phaseWallMs).toEqual({running: 100, paused: 40});
        expect(ends).toHaveBeenCalledTimes(4);
        expect(fixture.readDurable).not.toHaveBeenCalled();
        expect(fixture.sockets.every(socket => socket.closeCount === 1 && socket.readyState === 3)).toBe(true);
        expect(removeListener).toHaveBeenCalledWith("abort", expect.any(Function));
        expect(vi.getTimerCount()).toBe(0);

        const sends = fixture.sockets.map(socket => socket.sent);
        const evidence = JSON.stringify(reports);
        await vi.advanceTimersByTimeAsync(duration + 5_000);
        expect(fixture.sockets.map(socket => socket.sent)).toEqual(sends);
        expect(JSON.stringify(reports)).toBe(evidence);
        expect(ends).toHaveBeenCalledTimes(4);
        expect(vi.getTimerCount()).toBe(0);
      });
    }
  }

  it("does not admit clients or invent elapsed time when already cancelled", async () => {
    const fixture = lifecycleRuntime();
    const upgrade = vi.spyOn(fixture.runtime, "upgrade");
    const controller = new AbortController();
    controller.abort();
    const reports: InterruptedReport[] = [];
    await expect(runLoadScenario("miss-lanes", 180_000, fixture.runtime, message => {
      reports.push(JSON.parse(message) as InterruptedReport);
      return Promise.resolve();
    }, controller.signal)).rejects.toThrow("Load cancelled");
    expect(upgrade).not.toHaveBeenCalled();
    expect(reports).toHaveLength(1);
    expect(reports[0]).toMatchObject({activeElapsedMs: null, interruptedBeforeReconciliation: true, players: []});
    expect(vi.getTimerCount()).toBe(0);
  });

  it("clears warmup on cancellation without starting measurement", async () => {
    const fixture = lifecycleRuntime();
    vi.spyOn(LoadClient.prototype, "bootstrapClock").mockResolvedValue(undefined);
    const begins = vi.spyOn(LoadClient.prototype, "beginMeasurement");
    const ends = vi.spyOn(LoadClient.prototype, "endMeasurement");
    const controller = new AbortController();
    const reports: InterruptedReport[] = [];
    const completed = runLoadScenario("miss-lanes", 180_000, fixture.runtime, message => {
      reports.push(JSON.parse(message) as InterruptedReport);
      return Promise.resolve();
    }, controller.signal).then(() => null, (error: unknown) => error);
    await vi.advanceTimersByTimeAsync(100);
    expect(fixture.sockets).toHaveLength(4);
    controller.abort();
    await vi.advanceTimersByTimeAsync(50);
    expect(await completed).toEqual(new Error("Load cancelled"));
    expect(begins).not.toHaveBeenCalled();
    expect(ends).not.toHaveBeenCalled();
    expect(reports[0]).toMatchObject({activeElapsedMs: null, interruptedBeforeReconciliation: true});
    expect(reports[0]!.players.every(player => Object.keys(player.phaseWallMs).length === 0)).toBe(true);
    expect(fixture.sockets.every(socket => socket.closeCount === 1)).toBe(true);
    expect(vi.getTimerCount()).toBe(0);
  });

  it("rejects cancellation before an outstanding upgrade resolves and ignores its late response", async () => {
    const fixture = lifecycleRuntime();
    const admission = deferred<Awaited<ReturnType<LoadRuntime["upgrade"]>>>();
    const upgrade = vi.spyOn(fixture.runtime, "upgrade").mockReturnValue(admission.promise);
    const bootstrap = vi.spyOn(LoadClient.prototype, "bootstrapClock");
    const controller = new AbortController();
    const reports: InterruptedReport[] = [];
    let outcome: unknown = "pending";
    const completed = runLoadScenario("miss-lanes", 180_000, fixture.runtime, message => {
      reports.push(JSON.parse(message) as InterruptedReport);
      return Promise.resolve();
    }, controller.signal).then(() => {outcome = "resolved";}, (error: unknown) => {outcome = error;});
    await vi.advanceTimersByTimeAsync(0);
    expect(upgrade).toHaveBeenCalledTimes(1);
    controller.abort();
    await vi.advanceTimersByTimeAsync(0);
    expect(outcome).toEqual(new Error("Load cancelled"));
    expect(reports).toHaveLength(1);
    expect(reports[0]).toMatchObject({activeElapsedMs: null, players: [], interruptedBeforeReconciliation: true});
    expect(vi.getTimerCount()).toBe(0);

    const lateSocket = new LifecycleSocket(upgrade.mock.calls[0]![0]);
    admission.resolve({status: 101, webSocket: lateSocket});
    await vi.advanceTimersByTimeAsync(180_000);
    await completed;
    expect(upgrade).toHaveBeenCalledTimes(1);
    expect(bootstrap).not.toHaveBeenCalled();
    expect(lateSocket.readyState).toBe(3);
    expect(lateSocket.closeCount).toBe(1);
    expect(lateSocket.sent).toBe(0);
    expect(reports).toHaveLength(1);
    expect(outcome).toEqual(new Error("Load cancelled"));
    expect(vi.getTimerCount()).toBe(0);
  });

  it("cancels unresolved durable inspection and does not reconcile its late result", async () => {
    const fixture = lifecycleRuntime();
    const inspection = deferred<DurableLoadState>();
    fixture.readDurable.mockReturnValue(inspection.promise);
    vi.spyOn(LoadClient.prototype, "bootstrapClock").mockResolvedValue(undefined);
    const ends = vi.spyOn(LoadClient.prototype, "endMeasurement");
    const controller = new AbortController();
    const reports: InterruptedReport[] = [];
    let outcome: unknown = "pending";
    // This lifecycle fixture shortens only the active window; it performs no load acceptance claim.
    const completed = runLoadScenario("miss-lanes", 50, fixture.runtime, message => {
      reports.push(JSON.parse(message) as InterruptedReport);
      return Promise.resolve();
    }, controller.signal).then(() => {outcome = "resolved";}, (error: unknown) => {outcome = error;});
    await vi.advanceTimersByTimeAsync(5_200);
    expect(fixture.readDurable).toHaveBeenCalledTimes(1);
    expect(reports).toHaveLength(0);
    controller.abort();
    await vi.advanceTimersByTimeAsync(0);
    expect(outcome).toEqual(new Error("Load cancelled"));
    expect(reports).toHaveLength(1);
    expect(reports[0]).toMatchObject({activeElapsedMs: 50, interruptedBeforeReconciliation: true});
    for (const player of reports[0]!.players) expect(player.phaseWallMs).toEqual({running: 50});
    expect(ends).toHaveBeenCalledTimes(4);
    expect(fixture.sockets.every(socket => socket.closeCount === 1)).toBe(true);
    expect(vi.getTimerCount()).toBe(0);
    const sends = fixture.sockets.map(socket => socket.sent);
    const evidence = JSON.stringify(reports);

    inspection.resolve({epoch: 1, sequence: 0, snapshot: fixture.sockets[0]!.snapshot,
      ledger: [], bullets: 0, unresolved: 0, commands: 0, projectionRows: 0,
      projectionProgress: {queued_sequence: 0, delivered_sequence: 0}, checkpointBytes: 0, databaseBytes: null});
    await vi.advanceTimersByTimeAsync(180_000);
    await completed;
    expect(outcome).toEqual(new Error("Load cancelled"));
    expect(JSON.stringify(reports)).toBe(evidence);
    expect(fixture.sockets.map(socket => socket.sent)).toEqual(sends);
    expect(ends).toHaveBeenCalledTimes(4);
    expect(vi.getTimerCount()).toBe(0);
  });

  it("stops a profile that finishes installing after cancellation without starting measurement", async () => {
    const fixture = lifecycleRuntime();
    const installation = deferred<RuntimeProfile>();
    const installProfile = vi.fn(() => installation.promise);
    fixture.runtime.installProfile = installProfile;
    vi.spyOn(LoadClient.prototype, "bootstrapClock").mockResolvedValue(undefined);
    const begins = vi.spyOn(LoadClient.prototype, "beginMeasurement");
    const controller = new AbortController();
    const reports: InterruptedReport[] = [];
    let outcome: unknown = "pending";
    const completed = runLoadScenario("miss-lanes", 180_000, fixture.runtime, message => {
      reports.push(JSON.parse(message) as InterruptedReport);
      return Promise.resolve();
    }, controller.signal).then(() => {outcome = "resolved";}, (error: unknown) => {outcome = error;});
    await vi.advanceTimersByTimeAsync(0);
    expect(installProfile).toHaveBeenCalledTimes(1);
    controller.abort();
    await vi.advanceTimersByTimeAsync(0);
    expect(outcome).toEqual(new Error("Load cancelled"));
    expect(reports[0]).toMatchObject({activeElapsedMs: null, interruptedBeforeReconciliation: true});
    expect(fixture.sockets.every(socket => socket.closeCount === 1)).toBe(true);
    expect(vi.getTimerCount()).toBe(0);

    const removal = deferred<void>();
    let installed = true;
    const profile = {begin: vi.fn(() => Promise.resolve()),
      read: vi.fn(() => Promise.reject(new Error("Late profile must not be read"))),
      stop: vi.fn(() => removal.promise.then(() => {installed = false;}))};
    installation.resolve(profile);
    await vi.advanceTimersByTimeAsync(0);
    expect(profile.stop).toHaveBeenCalledTimes(1);
    removal.resolve();
    await vi.advanceTimersByTimeAsync(180_000);
    await completed;
    expect(installed).toBe(false);
    expect(profile.begin).not.toHaveBeenCalled();
    expect(profile.read).not.toHaveBeenCalled();
    expect(begins).not.toHaveBeenCalled();
    expect(reports).toHaveLength(1);
    expect(vi.getTimerCount()).toBe(0);
  });
});

function deferred<T>(): {promise: Promise<T>; resolve(value: T): void} {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(accept => {resolve = accept;});
  return {promise, resolve};
}

/** A lifecycle fixture only: immediate admission/results avoid timing a real authority. */
function lifecycleRuntime(): {runtime: LoadRuntime; sockets: LifecycleSocket[]; readDurable: ReturnType<typeof vi.fn>} {
  const sockets: LifecycleSocket[] = [];
  const readDurable = vi.fn(() => Promise.reject(new Error("Interrupted loads must not reconcile")));
  const runtime: LoadRuntime = {
    environment: "workerd-test-client", clockMode: "receiveAnchor", readDurable,
    upgrade: ticket => {
      const socket = new LifecycleSocket(ticket);
      sockets.push(socket);
      return Promise.resolve({status: 101, webSocket: socket});
    },
  };
  return {runtime, sockets, readDurable};
}

class LifecycleSocket implements LoadSocket {
  readyState = 1;
  sent = 0;
  closeCount = 0;
  private sequence = 0;
  readonly snapshot: CombatSnapshot;
  private readonly messageListeners: ((event: {data: unknown}) => void)[] = [];
  private readonly closeListeners: ((event: {code: number}) => void)[] = [];

  constructor(private readonly ticket: CombatTicketClaims) {
    this.snapshot = CombatSimulation.create({matchId: ticket.matchId, authorityEpoch: ticket.authorityEpoch,
      frameEpoch: ticket.frameEpoch, players: ticket.roster, rules: ticket.rules}).snapshot();
    this.snapshot.phase = "running";
    for (const player of this.snapshot.players) {player.frameReady = true; player.connected = true;}
  }

  addEventListener(type: "message", listener: (event: {data: unknown}) => void): void;
  addEventListener(type: "error", listener: () => void): void;
  addEventListener(type: "close", listener: (event: {code: number}) => void): void;
  addEventListener(type: "message" | "error" | "close", listener: ((event: {data: unknown}) => void) | (() => void) | ((event: {code: number}) => void)): void {
    if (type === "message") this.messageListeners.push(listener as (event: {data: unknown}) => void);
    if (type === "close") this.closeListeners.push(listener as (event: {code: number}) => void);
  }

  accept(): void {this.deliver({type: "snapshot", snapshot: this.snapshot, eventSequence: 0, clientSequence: 0});}
  close(code = 1000): void {
    this.closeCount++; this.readyState = 3;
    for (const listener of this.closeListeners) listener({code});
  }
  send(data: string): void {
    if (this.readyState !== 1) throw new Error("Send after fixture close");
    this.sent++;
    const message = JSON.parse(data) as ClientMessage;
    if (message.type === "command") {
      const envelope = message.envelope;
      this.deliver({type: "ack", commandId: envelope.commandId, clientSequence: envelope.clientSequence,
        replayed: false, eventSequence: this.sequence});
      this.event({kind: "commandResult", commandId: envelope.commandId, clientSequence: envelope.clientSequence,
        playerId: this.ticket.playerId, accepted: true, reason: null});
    } else if (message.type === "ping") {
      this.deliver({type: "pong", nonce: message.nonce, clientSentAtMs: message.clientSentAtMs,
        serverReceivedAtMs: performance.now(), serverSentAtMs: performance.now()});
    }
  }
  phase(phase: CombatSnapshot["phase"]): void {this.event({kind: "phaseChanged", phase, reason: "lifecycle-fixture"});}
  private event(event: CombatEvent): void {
    this.deliver({type: "events", events: [{v: 1, matchId: this.ticket.matchId, authorityEpoch: 1, frameEpoch: 1,
      eventSequence: ++this.sequence, tick: Math.floor(performance.now() / 50), matchTimeMs: performance.now(), event}]});
  }
  private deliver(message: ServerMessage): void {
    for (const listener of this.messageListeners) listener({data: JSON.stringify(message)});
  }
}
