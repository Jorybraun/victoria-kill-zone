import {env} from "cloudflare:workers";
import {abortAllDurableObjects, runInDurableObject} from "cloudflare:test";
import {afterEach, expect, it, vi} from "vitest";
import type {AuthenticatedCommand, CombatSnapshot, CommandEnvelope, ServerEvent} from "@vkz/combat-protocol";
import type {CombatSimulation} from "@vkz/combat-simulation";
import type {Connection} from "../src/connection.js";
import type {SerialQueue} from "../src/serial-queue.js";
import {claims, connect, phoneInput, type SocketInbox} from "./helpers.js";

type Room = {
  queue: SerialQueue;
  simulation: CombatSimulation | null;
  pending: {command: AuthenticatedCommand}[];
  connections: Map<WebSocket, Connection>;
  cadence: {anchor: number};
  stopTimer(): void;
  scheduleTick(): void;
  tick(): Promise<void>;
  webSocketMessage(socket: WebSocket, message: string | ArrayBuffer): Promise<void>;
  webSocketClose(socket: WebSocket, code: number): Promise<void>;
  admitCommand(connection: Connection, command: CommandEnvelope, receivedAtMs: number): void;
};

afterEach(async () => {vi.restoreAllMocks(); await abortAllDurableObjects();});

it("assigns queued poses to their arrival intervals during bounded catch-up", async ({annotate}) => {
  // The timer and monotonic clock follow a deterministic authority schedule. Socket delivery,
  // admission queue, simulation validation, SQLite commit and acknowledgments run.
  let now = 0;
  vi.spyOn(performance, "now").mockImplementation(() => now);
  let wallOrigin = performance.now();
  const at = async (logicalMs: number) => {
    now = logicalMs;
    await Promise.resolve();
  };
  const ticket = claims({roster: ["host", "second", "third", "fourth"].map((playerId, i) => ({
    playerId, displayName: playerId, role: i === 0 ? "host" : "player",
  }))});
  const stub = env.COMBAT_ROOMS.getByName(ticket.matchId);
  const arrivals = new Map<string, {sequence: number; capturedAtMs: number; receivedAtMs: number; admittedAtMs: number | null}>();
  await runInDurableObject(stub, instance => {
    const room = instance as unknown as Room;
    room.stopTimer(); room.scheduleTick = () => {};
    const admit = room.admitCommand.bind(room);
    room.admitCommand = function (connection, envelope, receivedAtMs) {
      const arrival = arrivals.get(envelope.commandId);
      if (arrival) arrival.admittedAtMs = performance.now() - wallOrigin;
      return admit(connection, envelope, receivedAtMs);
    };
  });
  const sockets: SocketInbox[] = [];
  const inputs = [];
  const tick = async (): Promise<CombatSnapshot> => runInDurableObject(stub, instance => {
    const room = instance as unknown as Room;
    return room.queue.run(async () => {await room.tick(); return room.simulation!.snapshot();});
  });
  const admitted = async () => Promise.all(sockets.map(async socket => {
    const nonce = crypto.randomUUID();
    socket.socket.send(JSON.stringify({type: "ping", nonce, clientSentAtMs: now}));
    await socket.next("pong", pong => pong.nonce === nonce);
  }));
  try {
    for (let index = 0; index < ticket.roster.length; index++) {
      const socket = await connect({...ticket, playerId: ticket.roster[index]!.playerId});
      sockets.push(socket);
      inputs.push(phoneInput(socket, await socket.next("snapshot"), [index * 10, 0, 0], () => now));
    }
    now = 20;
    for (const input of inputs) {
      input.send({kind: "frameReady", ready: true, residualMeters: 0.01, residualDegrees: 0.1, clockUncertaintyMs: 1});
      input.sample();
    }
    inputs[0]!.send({kind: "start"});
    await admitted(); now = 50;
    expect((await tick()).phase).toBe("running");
    now = 70;
    for (const input of inputs) input.sample();
    const fire = inputs[0]!.send({kind: "fire", shotId: "catch-up-fixture", poseSequence: inputs[0]!.poseSequence,
      origin: [0, 0, 0], direction: [0, 0, -1]});
    await admitted(); now = 100;
    expect((await tick()).projectiles).toHaveLength(1);
    expect((await sockets[0]!.result(fire)).event.accepted).toBe(true);

    const pending: CommandEnvelope[] = [];
    await runInDurableObject(stub, async instance => {
      const room = instance as unknown as Room;
      wallOrigin = performance.now() - 100;
      room.cadence.anchor = wallOrigin + 100;
      let release!: () => void;
      const hold = new Promise<void>(resolve => {release = resolve;});
      const blocked = room.queue.run(() => hold);
      const received: Promise<void>[] = [];
      try {
        for (const [batch, logicalMs] of [120, 170, 220].entries()) {
          await at(logicalMs);
          for (let index = 0; index < ticket.roster.length; index++) {
            const member = ticket.roster[index]!;
            const connection = [...room.connections.values()].find(item => item.playerId === member.playerId)!;
            const envelope: CommandEnvelope = {v: 1, commandId: crypto.randomUUID(),
              clientSequence: (index === 0 ? 6 : 4) + batch, authorityEpoch: 1, frameEpoch: 1,
              sentAtMs: logicalMs, command: {kind: "pose", observations: [], pose: {
                sequence: batch + 3, capturedAtMs: logicalMs, position: [index * 10, 0, 0], orientation: [0, 0, 0, 1], tracking: "normal",
              }}};
            pending.push(envelope);
            arrivals.set(envelope.commandId, {sequence: batch + 3, capturedAtMs: logicalMs,
              receivedAtMs: performance.now() - wallOrigin, admittedAtMs: null});
            // Inject at the actual handler boundary on an authenticated socket.
            // Keeping every pending handler in this callback avoids cross-context
            // unresolved test promises; the network leg is not timed here.
            received.push(room.webSocketMessage(connection.socket, JSON.stringify({type: "command", envelope})));
          }
        }
      } finally {await at(230); release();}
      await blocked;
      await Promise.all(received);
    });
    await admitted();
    const before = await runInDurableObject(stub, instance => {
      const room = instance as unknown as Room;
      return {tick: room.simulation!.snapshot().tick, cadenceLagMs: performance.now() - room.cadence.anchor, pending: room.pending.length};
    });
    const ticks: {atMs: number; matchTimeMs: number; pending: number; phase: string; projectiles: number}[] = [];
    for (const logicalMs of [230, 231, 250]) {
      await at(logicalMs); const snapshot = await tick();
      ticks.push({atMs: performance.now() - wallOrigin, matchTimeMs: snapshot.matchTimeMs, phase: snapshot.phase, projectiles: snapshot.projectiles.length,
        pending: await runInDurableObject(stub, instance => (instance as unknown as Room).pending.length)});
    }
    const outcomes = await Promise.all(pending.map(async (command, index) => {
      const result = await sockets[index % 4]!.result(command);
      await sockets[index % 4]!.next("ack", ack => ack.commandId === command.commandId);
      const arrival = arrivals.get(command.commandId)!;
      return {...arrival, queueResidenceMs: arrival.admittedAtMs! - arrival.receivedAtMs,
        processedAtMs: result.matchTimeMs, reason: result.event.reason};
    }));
    const durable = await runInDurableObject(stub, (_instance, state) => ({
      commands: state.storage.sql.exec<{result_json: string}>("SELECT result_json FROM commands WHERE command_id IN (" + pending.map(() => "?").join(",") + ")", ...pending.map(item => item.commandId)).toArray().map(row => JSON.parse(row.result_json) as ServerEvent),
      terminals: state.storage.sql.exec<{payload: string}>("SELECT payload FROM bullet_events WHERE kind = 'projectileTerminal'").toArray().map(row => JSON.parse(row.payload) as ServerEvent),
    }));
    await annotate(JSON.stringify({clock: "controlled monotonic milliseconds and queue hold; authenticated handler injection; network leg excluded", before, outcomes, ticks,
      durableCommands: durable.commands.length, terminalReasons: durable.terminals.map(item => item.event.kind === "projectileTerminal" ? item.event.reason : null)}), "vkz-load");
    expect(before).toMatchObject({tick: 2, pending: 12});
    expect(before.cadenceLagMs).toBeGreaterThanOrEqual(130);
    expect(before.cadenceLagMs).toBeLessThan(200);
    expect(outcomes.every(item => item.receivedAtMs >= item.capturedAtMs && item.admittedAtMs! >= item.receivedAtMs)).toBe(true);
    expect(durable.commands).toHaveLength(12);
    expect(outcomes.map(item => item.reason)).toEqual(Array.from({length: 12}, () => null));
    expect(ticks.map(item => item.pending)).toEqual([8, 4, 0]);
    expect(ticks.every(item => item.phase === "running" && item.projectiles === 1)).toBe(true);
    expect(durable.terminals).toEqual([]);
  } finally {for (const socket of sockets) socket.close();}
});

it("refuses a forged future timestamp on the next tick instead of reserving distant authority time", async () => {
  vi.spyOn(performance, "now").mockReturnValue(0);
  const ticket = claims(), stub = env.COMBAT_ROOMS.getByName(ticket.matchId);
  await runInDurableObject(stub, instance => {
    const room = instance as unknown as Room;
    room.stopTimer(); room.scheduleTick = () => {};
  });
  const socket = await connect(ticket);
  await socket.next("snapshot");
  const envelope: CommandEnvelope = {v: 1, commandId: crypto.randomUUID(), clientSequence: 1,
    authorityEpoch: 1, frameEpoch: 1, sentAtMs: 1_000_000,
    command: {kind: "pose", observations: [], pose: {sequence: 1, capturedAtMs: 1_000_000,
      position: [0, 0, 0], orientation: [0, 0, 0, 1], tracking: "normal"}}};
  try {
    await runInDurableObject(stub, async instance => {
      const room = instance as unknown as Room;
      room.cadence.anchor = performance.now();
      const connection = [...room.connections.values()][0]!;
      await room.webSocketMessage(connection.socket, JSON.stringify({type: "command", envelope}));
      // Pending duplicates and sequence reservations remain intact before commit.
      await room.webSocketMessage(connection.socket, JSON.stringify({type: "command", envelope}));
      await room.webSocketMessage(connection.socket, JSON.stringify({type: "command", envelope: {
        ...envelope, commandId: crypto.randomUUID(), clientSequence: 3,
      }}));
      expect(room.pending).toHaveLength(1);
      await room.queue.run(() => room.tick());
      expect(room.pending).toHaveLength(0);
      expect(room.simulation!.snapshot().tick).toBe(1);
    });
    expect(await socket.next("error")).toMatchObject({code: "sequenceConflict"});
    expect((await socket.result(envelope)).event).toMatchObject({accepted: false, reason: "futureInput"});
    const ack = await socket.next("ack");
    expect(ack).toMatchObject({clientSequence: 1, replayed: false});
    socket.send(envelope);
    expect(await socket.next("ack")).toEqual({...ack, replayed: true});
    expect(await runInDurableObject(stub, (_instance, state) => state.storage.sql.exec<{count: number}>("SELECT COUNT(*) AS count FROM commands").one().count)).toBe(1);
  } finally {socket.close();}
});

it("preserves pending sequence order through a last-socket reconnect and resets only after idle", async () => {
  let now = 0;
  vi.spyOn(performance, "now").mockImplementation(() => now);
  const ticket = claims(), stub = env.COMBAT_ROOMS.getByName(ticket.matchId);
  await runInDurableObject(stub, instance => {
    const room = instance as unknown as Room;
    room.stopTimer(); room.scheduleTick = () => {};
  });
  const first = await connect(ticket);
  await first.next("snapshot");
  const input = (clientSequence: number): CommandEnvelope => ({v: 1, commandId: crypto.randomUUID(), clientSequence,
    authorityEpoch: 1, frameEpoch: 1, sentAtMs: 120,
    command: {kind: "frameReady", ready: true, residualMeters: 0.01, residualDegrees: 0.1, clockUncertaintyMs: 1}});
  now = 120;
  const earlier = input(1), later = input(2);
  await runInDurableObject(stub, async instance => {
    const room = instance as unknown as Room, connection = [...room.connections.values()][0]!;
    await room.webSocketMessage(connection.socket, JSON.stringify({type: "command", envelope: earlier}));
    expect(room.pending).toHaveLength(1);
    await room.webSocketClose(connection.socket, 1000);
    expect(room.connections.size).toBe(0);
    expect(room.pending).toHaveLength(1);
  });
  await first.closed;
  const replacement = await connect(ticket);
  await replacement.next("snapshot");
  try {
    await runInDurableObject(stub, async (instance, state) => {
      const room = instance as unknown as Room, connection = [...room.connections.values()][0]!;
      expect(room.cadence.anchor).toBe(0);
      await room.webSocketMessage(connection.socket, JSON.stringify({type: "command", envelope: later}));
      now = 150;
      for (let tick = 1; tick <= 3; tick++) {
        await room.queue.run(() => room.tick());
        const sequences = state.storage.sql.exec<{client_sequence: number}>("SELECT client_sequence FROM commands ORDER BY client_sequence").toArray().map(row => row.client_sequence);
        expect(sequences).toEqual(tick < 3 ? [] : [1, 2]);
      }
      expect(room.pending).toHaveLength(0);
    });
    for (const envelope of [earlier, later]) {
      expect((await replacement.result(envelope)).event.accepted).toBe(true);
      expect(await replacement.next("ack", ack => ack.commandId === envelope.commandId)).toMatchObject({replayed: false});
    }
    await runInDurableObject(stub, async instance => {
      const room = instance as unknown as Room;
      await room.webSocketClose([...room.connections.keys()][0]!, 1000);
    });
    await replacement.closed;
    now = 1000;
    const idle = await connect(ticket);
    await idle.next("snapshot");
    try {
      expect(await runInDurableObject(stub, instance => (instance as unknown as Room).cadence.anchor)).toBe(1000);
    } finally {idle.close();}
  } finally {first.close(); replacement.close();}
});
