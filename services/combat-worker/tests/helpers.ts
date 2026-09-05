import { env, exports as workerExports } from "cloudflare:workers";
import { DEFAULT_RULES, LIMITS, type CombatTicketClaims, type CommandEnvelope, type ServerEvent, type ServerMessage, type Vec3 } from "@vkz/combat-protocol";

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

  constructor(readonly socket: WebSocket, autoReceipt = true) {
    this.closed = new Promise((resolve) => socket.addEventListener("close", (event) => resolve(event.code)));
    socket.addEventListener("message", (event) => {
      if (typeof event.data !== "string") throw new Error("Worker emitted non-text protocol data");
      // Server output under test; individual tests assert its declared wire shape.
      const message = JSON.parse(event.data) as ServerMessage;
      this.messages.push(message);
      if (autoReceipt) {
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

/** A bounded stationary phone feed using a live authority clock, never admission time. */
export async function phoneInput(socket: SocketInbox, initial: Extract<ServerMessage, { type: "snapshot" }>, position: Vec3) {
  const nonce = crypto.randomUUID();
  socket.socket.send(JSON.stringify({ type: "ping", nonce, clientSentAtMs: performance.now() }));
  const pong = await socket.next("pong", (message) => message.nonce === nonce);
  const receivedAt = performance.now();
  const now = () => pong.serverSentAtMs + Math.max(0, performance.now() - receivedAt);
  let clientSequence = initial.clientSequence;
  let poseSequence = 0;
  let timer: ReturnType<typeof setInterval> | null = null;
  const send = (payload: CommandEnvelope["command"]): CommandEnvelope => {
    const envelope = { ...command(initial, ++clientSequence, payload), sentAtMs: now() };
    socket.send(envelope);
    return envelope;
  };
  const sample = (): CommandEnvelope => send({ kind: "pose", observations: [], pose: {
    sequence: ++poseSequence, capturedAtMs: now(), position, orientation: [0, 0, 0, 1], tracking: "normal",
  } });
  const stopTracking = (): void => { if (timer !== null) clearInterval(timer); timer = null; };
  return {
    send, sample, stopTracking,
    get poseSequence() { return poseSequence; },
    startTracking(): CommandEnvelope {
      stopTracking();
      let remaining = 60;
      const first = sample();
      // Match the authority's 20 Hz cadence; stop even if a failed assertion skips cleanup.
      timer = setInterval(() => {
        if (--remaining === 0 || socket.socket.readyState !== WebSocket.OPEN) { stopTracking(); return; }
        sample();
      }, LIMITS.tickMs);
      return first;
    },
  };
}
