import { DurableObject } from "cloudflare:workers";
import {
  LIMITS, parseClientMessage, validateTicketClaims,
  type AuthenticatedCommand, type CombatEvent,
  type CombatTicketClaims, type CommandEnvelope, type ServerEvent, type ServerMessage,
} from "@vkz/combat-protocol";
import { CombatSimulation } from "@vkz/combat-simulation";
import { canonicalJson } from "./canonical.js";
import { verifyBearerTicket } from "./auth.js";
import { Connection } from "./connection.js";
import { QueueFullError, SerialQueue } from "./serial-queue.js";
import { RoomStore, type ProcessedCommand } from "./store.js";
import { combatRoute } from "./routes.js";
import { MapTransfer } from "./maps.js";
import { ProjectionDelivery } from "./projection-delivery.js";
import { TickCadence } from "./cadence.js";

const INPUT_SILENCE_MS = 15_000;
const IDLE_RETENTION_MS = 24 * 60 * 60 * 1000;
const ALARM_CHECK_MS = 30_000;
const EVENTS_PER_MESSAGE = 16;
const encoder = new TextEncoder();
type PendingCommand = { command: AuthenticatedCommand; fingerprint: string };

/** One authoritative room. Convex owns admission; it never receives combat writes here. */
export class CombatRoom extends DurableObject<Env> {
  private readonly store: RoomStore;
  private readonly queue = new SerialQueue();
  private readonly connections = new Map<WebSocket, Connection>();
  private readonly maps: MapTransfer;
  private readonly delivery: ProjectionDelivery;
  private simulation: CombatSimulation | null = null;
  private bootstrap: string | null = null;
  private eventSequence = 0;
  private pending: PendingCommand[] = [];
  private timer: ReturnType<typeof setTimeout> | null = null;
  private readonly cadence = new TickCadence(performance.now());

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.store = new RoomStore(ctx.storage);
    this.maps = new MapTransfer(ctx.storage, this.queue, (claims, frameEpoch, upload) => this.authorizeMap(claims, frameEpoch, upload));
    this.delivery = new ProjectionDelivery(env, ctx.storage, this.queue, this.store.projections, () => this.failRoom());
    void ctx.blockConcurrencyWhile(async () => {
      this.store.initialize();
      const saved = this.store.load();
      if (saved !== null) {
        const checkpoint: unknown = JSON.parse(saved.checkpoint);
        const candidate = CombatSimulation.restore(checkpoint, {
          authorityEpoch: saved.authority_epoch + 1, frameEpoch: saved.frame_epoch,
        });
        this.bootstrap = saved.bootstrap;
        this.eventSequence = saved.event_sequence;
        await this.commitCandidate(candidate, candidate.takeRecoveryEvents(), []);
      }
      // Hibernated sockets belong to the old authority instance. Reconnect
      // supplies a fresh snapshot and prevents stale attachments from authorizing input.
      for (const socket of this.ctx.getWebSockets()) socket.close(1012, "authority-restarted");
      this.cadence.reset(performance.now());
    });
  }

  override async fetch(request: Request): Promise<Response> {
    const route = combatRoute(new URL(request.url));
    if (route === null) return new Response(null, { status: 404 });
    const claims = await verifyBearerTicket(request, this.env.COMBAT_TICKET_SECRET, Math.floor(Date.now() / 1000));
    if (claims === null || route.matchId !== claims.matchId) return new Response(null, { status: 401 });
    if (this.ctx.id.name !== undefined && this.ctx.id.name !== claims.matchId) return new Response(null, { status: 401 });
    if (route.kind === "map") {
      try { return await this.maps.fetch(request, claims, route.frameEpoch); }
      catch (error) {
        if (error instanceof QueueFullError) return new Response(null, { status: 503 });
        this.failRoom();
      }
    }
    if (request.method !== "GET" || request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return new Response(null, { status: 426 });
    return this.admitSocket(claims);
  }

  private authorizeMap(claims: CombatTicketClaims, frameEpoch: number, upload: boolean): Response | null {
    if (validateTicketClaims(claims, Math.floor(Date.now() / 1000)) === null) return new Response(null, { status: 401 });
    if (this.simulation === null) return new Response(null, { status: 404 });
    const snapshot = this.simulation.snapshot();
    const bootstrap = canonicalJson({ roster: [...claims.roster].sort((a, b) => a.playerId.localeCompare(b.playerId)), rules: claims.rules });
    if (claims.matchId !== snapshot.matchId || bootstrap !== this.bootstrap || claims.frameEpoch !== snapshot.frameEpoch || frameEpoch !== snapshot.frameEpoch || claims.authorityEpoch > snapshot.authorityEpoch) return new Response(null, { status: 409 });
    const member = snapshot.players.find((player) => player.playerId === claims.playerId);
    if (member === undefined || (upload && member.role !== "host")) return new Response(null, { status: 403 });
    this.ctx.storage.sql.exec("UPDATE room SET last_activity_ms = ? WHERE singleton = 1", Date.now());
    return null;
  }

  /** Revalidates the signed ticket; no public identity header is trusted. */
  private async admitSocket(claims: CombatTicketClaims): Promise<Response> {
    try {
      return await this.queue.run(async () => {
        const validated = validateTicketClaims(claims, Math.floor(Date.now() / 1000));
        if (validated === null) return new Response(null, { status: 401 });
        const bootstrap = canonicalJson({ roster: [...claims.roster].sort((a, b) => a.playerId.localeCompare(b.playerId)), rules: claims.rules });
        if (this.simulation === null) {
          // deleteAll removes SQL tables; this live instance can accept a new
          // authorized room after retention cleanup without relying on eviction.
          this.store.initialize();
          const candidate = CombatSimulation.create({
            matchId: claims.matchId, authorityEpoch: claims.authorityEpoch, frameEpoch: claims.frameEpoch,
            players: claims.roster, rules: claims.rules,
          });
          this.store.create(candidate.snapshot(), candidate.checkpoint({ includeTracking: false }), bootstrap, Date.now());
          await this.ctx.storage.sync();
          this.simulation = candidate;
          this.bootstrap = bootstrap;
          this.cadence.reset(performance.now());
        }
        const snapshot = this.simulation.snapshot();
        if (claims.matchId !== snapshot.matchId || this.bootstrap !== bootstrap) return new Response(null, { status: 409 });
        if (claims.authorityEpoch > snapshot.authorityEpoch || claims.frameEpoch !== snapshot.frameEpoch) return new Response(null, { status: 409 });
        if (snapshot.phase === "finished") return new Response(null, { status: 410 });
        if (!snapshot.players.some((player) => player.playerId === claims.playerId)) return new Response(null, { status: 403 });
        const existing = this.connectionFor(claims.playerId);
        if (existing === undefined && this.connections.size >= LIMITS.players) return Response.json({ error: "roomFull" }, { status: 409 });

        const candidate = this.simulation.fork();
        const events = existing === undefined ? [] : candidate.setConnected(claims.playerId, false);
        events.push(...candidate.setConnected(claims.playerId, true));
        const committed = await this.commitCandidate(candidate, events, []);
        if (this.connections.size === 0) this.cadence.reset(performance.now());
        if (existing !== undefined) {
          this.pending = this.pending.filter((item) => item.command.playerId !== claims.playerId);
          this.connections.delete(existing.socket);
          existing.close(4001, "connection-replaced");
        }
        const pair = new WebSocketPair();
        this.ctx.acceptWebSocket(pair[1], [claims.playerId]);
        const connection = new Connection(pair[1], claims.playerId, this.eventSequence, Date.now());
        this.connections.set(pair[1], connection);
        this.broadcast(committed);
        this.sendSnapshot(connection);
        await this.ctx.storage.setAlarm(Date.now() + ALARM_CHECK_MS);
        this.scheduleTick();
        return new Response(null, { status: 101, webSocket: pair[0] });
      });
    } catch (error) {
      if (!(error instanceof QueueFullError)) this.failRoom();
      return new Response(null, { status: 503 });
    }
  }

  override async webSocketMessage(socket: WebSocket, message: string | ArrayBuffer): Promise<void> {
    try {
      await this.queue.run(() => {
        const connection = this.connections.get(socket);
        if (connection === undefined || socket.readyState !== WebSocket.OPEN) return;
        if (typeof message !== "string" || message.length > LIMITS.messageBytes || encoder.encode(message).byteLength > LIMITS.messageBytes) {
          connection.close(1009, "message-too-large-or-binary");
          return;
        }
        if (!connection.admit(Date.now(), LIMITS.commandsPerSecond)) {
          connection.send({ type: "error", code: "rateLimited" });
          connection.close(4008, "input-rate-exceeded");
          return;
        }
        const parsed = parseClientMessage(message);
        if (parsed === null) {
          connection.send({ type: "error", code: "invalidMessage" });
          connection.close(1008, "invalid-message");
          return;
        }
        switch (parsed.type) {
          case "command": this.admitCommand(connection, parsed.envelope); break;
          case "received":
            if (!connection.acknowledge(parsed.eventSequence)) connection.close(1008, "invalid-receipt");
            break;
          case "resume": this.resume(connection, parsed.afterEventSequence); break;
          case "ping": {
            const now = this.logicalNow();
            connection.send({ type: "pong", nonce: parsed.nonce, clientSentAtMs: parsed.clientSentAtMs, serverReceivedAtMs: now, serverSentAtMs: this.logicalNow() });
            break;
          }
        }
      });
    } catch (error) {
      if (error instanceof QueueFullError) this.connections.get(socket)?.close(4008, "input-queue-full");
      else this.failRoom();
    }
  }

  override async webSocketClose(socket: WebSocket, code: number): Promise<void> {
    try {
      await this.queue.run(async () => {
        const connection = this.connections.get(socket);
        if (connection === undefined) return;
        connection.close(code === 1005 || code === 1006 ? 1000 : code, "closed");
        await this.disconnect(connection);
      });
    } catch { this.failRoom(); }
  }

  override async webSocketError(socket: WebSocket): Promise<void> {
    await this.webSocketClose(socket, 1011);
  }

  /** Maintenance only: alarms never advance projectile physics or combat time. */
  override async alarm(): Promise<void> {
    await this.queue.run(async () => {
      for (const connection of this.connections.values()) {
        if (Date.now() - connection.lastActivityAt >= INPUT_SILENCE_MS) {
          connection.close(1001, "heartbeat-timeout");
          await this.disconnect(connection);
        }
      }
      const saved = this.store.load();
      if (saved === null) return;
      const projectionPending = this.store.projections.hasPending();
      if (this.connections.size === 0 && !projectionPending && Date.now() - saved.last_activity_ms >= IDLE_RETENTION_MS) {
        this.stopTimer();
        await this.ctx.storage.deleteAll();
        this.simulation = null;
        this.bootstrap = null;
        this.pending = [];
        this.eventSequence = 0;
        return;
      }
      if (projectionPending) this.ctx.waitUntil(this.delivery.flush(Date.now()));
      await this.ctx.storage.setAlarm(this.connections.size > 0 || projectionPending ? Date.now() + ALARM_CHECK_MS : saved.last_activity_ms + IDLE_RETENTION_MS);
    });
  }

  private admitCommand(connection: Connection, envelope: CommandEnvelope): void {
    if (this.simulation === null) return;
    const snapshot = this.simulation.snapshot();
    const fingerprint = canonicalJson(envelope);
    const existing = this.store.findCommand(connection.playerId, envelope.commandId, envelope.clientSequence);
    if (existing !== null) {
      if (existing.command_id !== envelope.commandId || existing.client_sequence !== envelope.clientSequence || existing.fingerprint !== fingerprint) {
        this.error(connection, "idempotencyConflict", envelope.commandId);
        return;
      }
      connection.sendSerialized(`{"type":"events","events":[${existing.result_json}]}`);
      connection.send({ type: "ack", commandId: envelope.commandId, clientSequence: envelope.clientSequence, replayed: true, eventSequence: existing.event_sequence });
      return;
    }
    if (envelope.authorityEpoch !== snapshot.authorityEpoch || envelope.frameEpoch !== snapshot.frameEpoch) {
      this.error(connection, "epochMismatch", envelope.commandId);
      this.sendSnapshot(connection);
      return;
    }
    const samePending = this.pending.find((item) => item.command.playerId === connection.playerId && (item.command.clientSequence === envelope.clientSequence || item.command.commandId === envelope.commandId));
    if (samePending !== undefined) {
      if (samePending.fingerprint !== fingerprint) this.error(connection, "idempotencyConflict", envelope.commandId);
      return; // Original is awaiting its durable tick result.
    }
    const committedSequence = this.store.sequence(connection.playerId);
    const pendingSequence = this.pending.reduce((sequence, item) => item.command.playerId === connection.playerId ? Math.max(sequence, item.command.clientSequence) : sequence, committedSequence);
    if (envelope.clientSequence <= committedSequence) {
      this.error(connection, "replayExpired", envelope.commandId);
      return;
    }
    if (envelope.clientSequence !== pendingSequence + 1) {
      this.error(connection, "sequenceConflict", envelope.commandId);
      return;
    }
    if (this.pending.length >= LIMITS.commandsPerTick) {
      this.error(connection, "rateLimited", envelope.commandId);
      connection.close(4008, "command-queue-full");
      return;
    }
    this.pending.push({ command: { ...envelope, playerId: connection.playerId }, fingerprint });
    this.scheduleTick();
  }

  private async tick(): Promise<void> {
    if (this.simulation === null) return;
    for (const connection of this.connections.values()) {
      if (connection.socket.readyState !== WebSocket.OPEN || Date.now() - connection.lastActivityAt >= INPUT_SILENCE_MS) {
        connection.close(1001, "heartbeat-timeout");
        await this.disconnect(connection);
      }
    }
    if (this.connections.size === 0 && this.pending.length === 0) return;
    const now = performance.now();
    if (this.cadence.stalled(now)) {
      const snapshot = this.simulation.snapshot();
      const candidate = CombatSimulation.restore(this.simulation.checkpoint({ includeTracking: false }), { authorityEpoch: snapshot.authorityEpoch + 1, frameEpoch: snapshot.frameEpoch });
      const recoveryEvents = candidate.takeRecoveryEvents();
      for (const connection of this.connections.values()) recoveryEvents.push(...candidate.setConnected(connection.playerId, true));
      const events = await this.commitCandidate(candidate, recoveryEvents, []);
      this.pending = [];
      this.cadence.reset(now);
      this.broadcast(events);
      for (const connection of this.connections.values()) { this.error(connection, "epochMismatch"); this.sendSnapshot(connection); }
      this.scheduleTick();
      return;
    }
    const pending = this.pending;
    const candidate = this.simulation.fork();
    const events = candidate.advance(pending.map((item) => item.command));
    const committed = await this.commitCandidate(candidate, events, pending);
    this.pending = [];
    // Preserve the ideal cadence. Small scheduler delays are caught up with
    // bounded single steps; a large stall takes the explicit recovery path.
    this.cadence.committedTick();
    this.broadcast(committed);
    for (const item of pending) this.connectionFor(item.command.playerId)?.send({
      type: "ack", commandId: item.command.commandId, clientSequence: item.command.clientSequence,
      replayed: false, eventSequence: this.eventSequence,
    });
    const snapshot = candidate.snapshot();
    if (snapshot.tick % 5 === 0) for (const connection of this.connections.values()) this.sendSnapshot(connection);
    for (const player of snapshot.players) {
      if (!player.connected) {
        const connection = this.connectionFor(player.playerId);
        if (connection !== undefined) { this.connections.delete(connection.socket); connection.close(1000, "player-left"); }
      }
    }
    if (snapshot.phase === "finished") {
      for (const connection of this.connections.values()) { this.sendSnapshot(connection); connection.close(1000, "match-finished"); }
      this.stopTimer();
      return;
    }
    this.scheduleTick();
  }

  private async commitCandidate(candidate: CombatSimulation, events: readonly CombatEvent[], pending: readonly PendingCommand[]): Promise<ServerEvent[]> {
    const snapshot = candidate.snapshot();
    const wrapped: ServerEvent[] = events.map((event, index) => ({
      v: 1, matchId: snapshot.matchId, authorityEpoch: snapshot.authorityEpoch, frameEpoch: snapshot.frameEpoch,
      eventSequence: this.eventSequence + index + 1, tick: snapshot.tick, matchTimeMs: snapshot.matchTimeMs, event,
    }));
    const processed: ProcessedCommand[] = pending.map((item) => {
      const result = wrapped.find((event) => event.event.kind === "commandResult" && event.event.playerId === item.command.playerId && event.event.clientSequence === item.command.clientSequence && event.event.commandId === item.command.commandId);
      if (result === undefined) throw new Error("Simulation omitted terminal command result");
      return { ...item, result };
    });
    const sequence = this.eventSequence + wrapped.length;
    this.store.commit(snapshot, candidate.checkpoint({ includeTracking: false }), wrapped, processed, sequence, Date.now());
    await this.ctx.storage.sync();
    this.simulation = candidate;
    this.eventSequence = sequence;
    this.ctx.waitUntil(this.delivery.flush(Date.now(), events.some((event) => event.kind === "projectileTerminal" || (event.kind === "phaseChanged" && event.phase === "finished"))));
    return wrapped;
  }

  private async disconnect(connection: Connection): Promise<void> {
    if (!this.connections.delete(connection.socket) || this.simulation === null) return;
    const candidate = this.simulation.fork();
    const events = await this.commitCandidate(candidate, candidate.setConnected(connection.playerId, false), []);
    this.broadcast(events);
    if (this.connections.size === 0 && this.pending.length === 0) this.stopTimer();
  }

  private scheduleTick(): void {
    if (this.timer !== null || this.simulation === null || (this.connections.size === 0 && this.pending.length === 0)) return;
    const delay = this.cadence.delay(performance.now());
    this.timer = setTimeout(() => {
      this.timer = null;
      this.ctx.waitUntil(this.queue.run(() => this.tick()).catch(() => this.failRoom()));
    }, delay);
  }

  private stopTimer(): void {
    if (this.timer !== null) clearTimeout(this.timer);
    this.timer = null;
  }

  private logicalNow(): number {
    return this.cadence.interpolate(this.simulation?.snapshot().matchTimeMs ?? 0, performance.now());
  }

  private sendSnapshot(connection: Connection): void {
    if (this.simulation === null) return;
    connection.send({ type: "snapshot", snapshot: this.simulation.snapshot(), eventSequence: this.eventSequence, clientSequence: this.store.sequence(connection.playerId) }, this.eventSequence);
  }

  private broadcast(events: readonly ServerEvent[]): void {
    for (let offset = 0; offset < events.length; offset += EVENTS_PER_MESSAGE) {
      const batch = events.slice(offset, offset + EVENTS_PER_MESSAGE);
      const sequence = batch.at(-1)?.eventSequence;
      for (const connection of this.connections.values()) connection.send({ type: "events", events: batch }, sequence);
    }
  }

  private resume(connection: Connection, after: number): void {
    if (after > this.eventSequence) { this.error(connection, "sequenceConflict"); return; }
    const earliest = this.store.earliestEvent();
    if (earliest !== null && after < earliest - 1) { this.error(connection, "replayExpired"); this.sendSnapshot(connection); return; }
    let cursor = after;
    // Bounded by history, and the connection's receipt window cuts off slow readers.
    for (let page = 0; page < LIMITS.eventHistory / EVENTS_PER_MESSAGE; page += 1) {
      const rows = this.store.eventPage(cursor, this.eventSequence, EVENTS_PER_MESSAGE);
      if (rows.length === 0) break;
      cursor = rows.at(-1)?.sequence ?? cursor;
      if (!connection.sendSerialized(`{"type":"events","events":[${rows.map((row) => row.payload).join(",")}]}`, cursor)) return;
    }
    this.sendSnapshot(connection);
  }

  private connectionFor(playerId: string): Connection | undefined {
    return [...this.connections.values()].find((connection) => connection.playerId === playerId);
  }

  private error(connection: Connection, code: Extract<ServerMessage, { type: "error" }>["code"], commandId?: string): void {
    connection.send({ type: "error", code, ...(commandId === undefined ? {} : { commandId }) });
  }

  private failRoom(): never {
    this.stopTimer();
    console.error(JSON.stringify({ event: "combat_room_failed", recoverable: true }));
    this.ctx.abort("Combat room recovery required");
    throw new Error("Combat room recovery required");
  }
}
