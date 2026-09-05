import { env, exports as workerExports } from "cloudflare:workers";
import { runInDurableObject } from "cloudflare:test";
import { DEFAULT_RULES, LIMITS, type CombatTicketClaims, type CommandEnvelope, type ServerEvent, type ServerMessage, type Vec3 } from "@vkz/combat-protocol";
import type { CombatSimulation } from "@vkz/combat-simulation";
import type { SerialQueue } from "../src/serial-queue.js";

export function claims(overrides: Partial<CombatTicketClaims> = {}): CombatTicketClaims {
  const now = Math.floor(Date.now() / 1000);
  return {
    v: 1, iss: "vkz-lobby", aud: "vkz-combat", matchId: crypto.randomUUID(), playerId: "host",
    roster: [{ playerId: "host", displayName: "Host", role: "host" }, { playerId: "guest", displayName: "Guest", role: "player" }],
    authorityEpoch: 1, frameEpoch: 1,
    rules: { ...DEFAULT_RULES, geometry: "phoneProxy" }, iat: now, exp: now + 120, nonce: crypto.randomUUID(),
    ...overrides,
  };
}

function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

export async function token(payload: CombatTicketClaims, header: { alg: string; typ: string } = { alg: "HS256", typ: "JWT" }): Promise<string> {
  const encoder = new TextEncoder();
  const content = `${base64url(encoder.encode(JSON.stringify(header)))}.${base64url(encoder.encode(JSON.stringify(payload)))}`;
  const key = await crypto.subtle.importKey("raw", encoder.encode(env.COMBAT_TICKET_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(content));
  return `${content}.${base64url(new Uint8Array(signature))}`;
}

export async function requestUpgrade(payload: CombatTicketClaims, options: { bearer?: string; pathMatchId?: string; query?: string } = {}): Promise<Response> {
  const bearer = options.bearer ?? await token(payload);
  return workerExports.default.fetch(new Request(`https://combat.test/v1/matches/${encodeURIComponent(options.pathMatchId ?? payload.matchId)}/connect${options.query ?? ""}`, {
    headers: { Upgrade: "websocket", Authorization: `Bearer ${bearer}` },
  }));
}

export class SocketInbox {
  readonly messages: ServerMessage[] = [];
  readonly closed: Promise<number>;
  private readonly listeners = new Set<() => void>();
  private highestReceived = 0;
  private closing = false;

  constructor(readonly socket: WebSocket, autoReceipt = true) {
    this.closed = new Promise((resolve) => socket.addEventListener("close", (event) => {
      this.closing = true;
      resolve(event.code);
    }));
    socket.addEventListener("message", (event) => {
      if (typeof event.data !== "string") throw new Error("Worker emitted non-text protocol data");
      // Server output under test; individual tests assert its declared wire shape.
      const message = JSON.parse(event.data) as ServerMessage;
      this.messages.push(message);
      if (autoReceipt && !this.closing && socket.readyState === WebSocket.OPEN) {
        const sequence = message.type === "events" ? message.events.at(-1)?.eventSequence : message.type === "snapshot" ? message.eventSequence : undefined;
        if (sequence !== undefined) {
          this.highestReceived = Math.max(sequence, this.highestReceived);
          socket.send(JSON.stringify({ type: "received", eventSequence: this.highestReceived }));
        }
      }
      for (const listener of this.listeners) listener();
    });
    socket.accept();
  }

  next<Type extends ServerMessage["type"]>(type: Type, where?: (message: Extract<ServerMessage, { type: Type }>) => boolean): Promise<Extract<ServerMessage, { type: Type }>> {
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => { this.listeners.delete(check); reject(new Error(`Timed out waiting for ${type}`)); }, 3000);
      const check = () => {
        const index = this.messages.findIndex((message) => message.type === type && (where === undefined || where(message as Extract<ServerMessage, { type: Type }>)));
        if (index < 0) return;
        const message = this.messages.splice(index, 1)[0];
        if (message === undefined) return;
        clearTimeout(timeout);
        this.listeners.delete(check);
        resolve(message as Extract<ServerMessage, { type: Type }>);
      };
      this.listeners.add(check);
      check();
    });
  }

  send(envelope: CommandEnvelope): void {
    this.socket.send(JSON.stringify({ type: "command", envelope }));
  }

  /** Inspect the result without consuming the batch that may also contain a spawn. */
  result(envelope: CommandEnvelope): Promise<ServerEvent & { event: Extract<ServerEvent["event"], { kind: "commandResult" }> }> {
    return new Promise((resolve, reject) => {
      const label = `${envelope.command.kind} sequence ${envelope.clientSequence}`;
      const timeout = setTimeout(() => {
        this.listeners.delete(check);
        reject(new Error(`Timed out waiting for commandResult: ${label}`));
      }, 3000);
      const check = () => {
        for (const message of this.messages) {
          if (message.type === "error" && (message.commandId === undefined || message.commandId === envelope.commandId)) {
            clearTimeout(timeout); this.listeners.delete(check);
            reject(new Error(`${label} transport refusal: ${message.code}`));
            return;
          }
          if (message.type !== "events") continue;
          const result = message.events.find((item) => item.event.kind === "commandResult"
            && item.event.commandId === envelope.commandId && item.event.clientSequence === envelope.clientSequence);
          if (result?.event.kind !== "commandResult") continue;
          clearTimeout(timeout); this.listeners.delete(check);
          resolve({ ...result, event: result.event });
          return;
        }
      };
      this.listeners.add(check);
      check();
    });
  }

  close(): void {
    this.closing = true;
    if (this.socket.readyState === WebSocket.OPEN) this.socket.close(1000, "test-complete");
  }
}

export async function connect(payload: CombatTicketClaims, autoReceipt = true): Promise<SocketInbox> {
  const response = await requestUpgrade(payload);
  if (response.status !== 101 || response.webSocket === null) throw new Error(`Upgrade returned ${response.status}`);
  return new SocketInbox(response.webSocket, autoReceipt);
}

export function command(snapshot: Extract<ServerMessage, { type: "snapshot" }>, clientSequence: number, payload: CommandEnvelope["command"], commandId = crypto.randomUUID()): CommandEnvelope {
  return {
    v: 1, commandId, clientSequence, authorityEpoch: snapshot.snapshot.authorityEpoch,
    frameEpoch: snapshot.snapshot.frameEpoch, sentAtMs: snapshot.snapshot.matchTimeMs, command: payload,
  };
}

/** Stationary phone commands stamped by the test's current authority tick. */
export function phoneInput(socket: SocketInbox, initial: Extract<ServerMessage, { type: "snapshot" }>, position: Vec3, now: () => number) {
  let clientSequence = initial.clientSequence;
  let poseSequence = 0;
  const send = (payload: CommandEnvelope["command"]): CommandEnvelope => {
    const envelope = { ...command(initial, ++clientSequence, payload), sentAtMs: now() };
    socket.send(envelope);
    return envelope;
  };
  const sample = (): CommandEnvelope => send({ kind: "pose", observations: [], pose: {
    sequence: ++poseSequence, capturedAtMs: now(), position, orientation: [0, 0, 0, 1], tracking: "normal",
  } });
  return {
    send, sample,
    get poseSequence() { return poseSequence; },
  };
}

type ScheduledRoom = {
  queue: Pick<SerialQueue, "run">;
  cadence: { reset(now: number): void };
  simulation: Pick<CombatSimulation, "snapshot"> | null;
  pending: readonly { command: CommandEnvelope }[];
  stopTimer(): void;
  scheduleTick(): void;
  tick(): Promise<void>;
};

/**
 * Confines private scheduler access to one isolated test object, before admission.
 * Real authenticated WebSockets, SerialQueue, simulation, commit/sync and broadcasts
 * remain in use. Cadence and real scheduling are covered by cadence/load suites;
 * this fixture advances logical time explicitly, without changing freshness gates.
 */
export async function manuallyScheduledRoom(matchId: string) {
  const stub = env.COMBAT_ROOMS.getByName(matchId);
  await runInDurableObject(stub, async (instance) => {
    const room = instance as unknown as ScheduledRoom;
    await room.queue.run(() => {
      if (room.simulation !== null) throw new Error("Install the fixture scheduler before connecting phones");
      room.stopTimer();
      room.scheduleTick = () => {};
    });
  });
  let matchTimeMs = 0;
  return {
    get matchTimeMs() { return matchTimeMs; },
    async tick(sockets: readonly SocketInbox[] = [], inputs: readonly CommandEnvelope[] = []) {
      // A pong sent after this socket's commands crosses its real admission queue.
      // Wait for every participating socket, then require the exact admitted batch.
      await Promise.all(sockets.map(async (socket) => {
        const nonce = crypto.randomUUID();
        socket.socket.send(JSON.stringify({ type: "ping", nonce, clientSentAtMs: performance.now() }));
        await socket.next("pong", (message) => message.nonce === nonce);
        const refusal = socket.messages.find((message) => message.type === "error");
        if (refusal?.type === "error") throw new Error(`Fixture admission failed: ${refusal.code}`);
      }));
      const snapshot = await runInDurableObject(stub, async (instance) => {
        const room = instance as unknown as ScheduledRoom;
        return room.queue.run(async () => {
          const actual = room.pending.map((item) => item.command.commandId).sort();
          const expected = inputs.map((input) => input.commandId).sort();
          if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error("Fixture tick did not receive the exact WebSocket command batch");
          const before = room.simulation?.snapshot();
          if (before === undefined) throw new Error("Fixture requires admitted phones");
          // CI wall-clock delays must not masquerade as a simulated authority stall.
          room.cadence.reset(performance.now());
          await room.tick();
          const after = room.simulation?.snapshot();
          if (after === undefined || after.matchTimeMs !== before.matchTimeMs + LIMITS.tickMs) throw new Error("Fixture did not commit exactly one authority tick");
          return after;
        });
      });
      matchTimeMs = snapshot.matchTimeMs;
      return snapshot;
    },
  };
}
