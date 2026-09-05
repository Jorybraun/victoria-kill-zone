import { LIMITS, type CombatCommand, type CombatPlayerState, type CombatSnapshot, type ServerEvent, type ServerMessage } from "@vkz/combat-protocol";

type Pending = {at: number; kind: CombatCommand["kind"]; shotId: string | null; measured: boolean; ack: boolean; result: boolean};
const count = (map: Record<string, number>, key: string): void => {map[key] = (map[key] ?? 0) + 1;};

/** Synthetic local driver. Samples measure client-observed delivery, never server CPU time. */
export class LoadClient {
  snapshot: CombatSnapshot | null = null;
  readonly players = new Map<string, CombatPlayerState>();
  readonly pending = new Map<string, Pending>();
  readonly errors: string[] = [];
  readonly accepted: Record<string, number> = {};
  readonly acceptedShotIds = new Set<string>();
  readonly refusals: Record<string, number> = {};
  readonly offered: Record<string, number> = {};
  readonly acknowledgmentMs: number[] = [];
  readonly resultMs: number[] = [];
  readonly tickDeliveries: {ticks: number; wallMs: number}[] = [];
  readonly poseSendIntervalsMs: number[] = [];
  readonly bulletEvents = new Map<number, string>();
  readonly terminalReasons: Record<string, number> = {};
  readonly projectiles = new Set<string>();
  readonly phaseWallMs: Record<string, number> = {};
  maximumProjectiles = 0;
  maximumInputBytes = 0;
  measuredInputBytes = 0;
  measuredOutputBytes = 0;
  totalSent = 0;
  totalAcknowledgments = 0;
  totalResults = 0;
  measuredAcknowledgments = 0;
  poseSequence = 0;
  latestEventSequence = 0;
  latestAuthorityTick = 0;
  duplicateEvents = 0;
  missingEvents = 0;
  snapshotHealedEvents = 0;
  phase: CombatSnapshot["phase"] = "calibrating";
  measuring = false;
  private sequence = 0;
  private lastTick = -1;
  private lastTickAt = 0;
  private phaseAt = 0;
  private lastPoseAt: number | null = null;
  private clockTime = 0;
  private clockAt = 0;
  private readonly pongs = new Map<string, (message: Extract<ServerMessage, {type: "pong"}>) => void>();
  private readonly encoder = new TextEncoder();

  constructor(readonly socket: WebSocket, readonly playerId: string) {
    socket.addEventListener("message", event => {
      if (typeof event.data !== "string") {this.errors.push("nonTextOutput"); return;}
      if (this.measuring) this.measuredOutputBytes += this.encoder.encode(event.data).byteLength;
      const message = JSON.parse(event.data) as ServerMessage;
      if (message.type === "snapshot") {
        if (this.snapshot !== null && message.eventSequence > this.latestEventSequence) {
          this.snapshotHealedEvents += message.eventSequence - this.latestEventSequence;
        }
        this.snapshot = message.snapshot;
        this.sequence = Math.max(this.sequence, message.clientSequence);
        this.setPhase(message.snapshot.phase);
        this.players.clear();
        for (const player of message.snapshot.players) this.players.set(player.playerId, player);
        this.projectiles.clear();
        for (const projectile of message.snapshot.projectiles) this.projectiles.add(projectile.projectileId);
        this.maximumProjectiles = Math.max(this.maximumProjectiles, this.projectiles.size);
        if (this.clockAt === 0) {this.clockTime = message.snapshot.matchTimeMs; this.clockAt = performance.now();}
        this.tick(message.snapshot.tick);
        this.latestEventSequence = Math.max(this.latestEventSequence, message.eventSequence);
        this.receipt();
      } else if (message.type === "events") {
        for (const event of message.events) this.event(event);
        this.receipt();
      } else if (message.type === "ack") {
        const pending = this.pending.get(message.commandId);
        if (!pending || pending.ack) {this.errors.push("unexpectedAck"); return;}
        pending.ack = true; this.totalAcknowledgments++;
        if (pending.measured) {this.acknowledgmentMs.push(performance.now() - pending.at); this.measuredAcknowledgments++;}
        this.settle(message.commandId, pending);
      } else if (message.type === "pong") {
        this.pongs.get(message.nonce)?.(message); this.pongs.delete(message.nonce);
      } else if (message.type === "error") this.errors.push(message.code);
    });
    socket.addEventListener("error", () => {this.errors.push("socketError");});
    socket.accept();
  }

  get matchTimeMs(): number {return this.clockTime + Math.max(0, performance.now() - this.clockAt);}

  async synchronizeClock(): Promise<void> {
    const nonce = crypto.randomUUID();
    await new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => {this.pongs.delete(nonce); reject(new Error("Clock sync timed out"));}, 3000);
      this.pongs.set(nonce, message => {
        clearTimeout(timeout);
        // Receive-side anchor deliberately underestimates by delivery time. This
        // local fixture does not claim the physical client's clock uncertainty.
        this.clockTime = message.serverSentAtMs; this.clockAt = performance.now(); resolve();
      });
      this.wire({type: "ping", nonce, clientSentAtMs: performance.now()});
    });
  }

  beginMeasurement(): void {
    this.measuring = true; this.phaseAt = performance.now(); this.lastTickAt = this.phaseAt;
    this.lastTick = -1; this.lastPoseAt = null;
  }
  endMeasurement(): void {this.recordPhase(); this.measuring = false;}

  send(command: CombatCommand): string {
    if (!this.snapshot || this.socket.readyState !== WebSocket.OPEN) throw new Error("Load socket unavailable");
    const commandId = crypto.randomUUID();
    const message = {type: "command", envelope: {v: 1, commandId, clientSequence: ++this.sequence,
      authorityEpoch: this.snapshot.authorityEpoch, frameEpoch: this.snapshot.frameEpoch, sentAtMs: this.matchTimeMs, command}};
    const data = JSON.stringify(message), bytes = this.encoder.encode(data).byteLength;
    if (bytes > LIMITS.messageBytes || this.pending.size >= 32) throw new Error("Synthetic driver exceeded native command bounds");
    this.maximumInputBytes = Math.max(this.maximumInputBytes, bytes);
    this.totalSent++;
    const now = performance.now();
    if (this.measuring) {
      count(this.offered, command.kind);
      if (command.kind === "pose") {
        if (this.lastPoseAt !== null) this.poseSendIntervalsMs.push(now - this.lastPoseAt);
        this.lastPoseAt = now;
      }
    }
    this.pending.set(commandId, {at: now, kind: command.kind, shotId: command.kind === "fire" ? command.shotId : null,
      measured: this.measuring, ack: false, result: false});
    this.wire(data);
    return commandId;
  }

  hasPending(kind: string): boolean {return [...this.pending.values()].some(item => item.kind === kind);}
  close(): void {if (this.socket.readyState === WebSocket.OPEN) this.socket.close(1000, "load-complete");}
  private wire(message: unknown): void {
    const data = typeof message === "string" ? message : JSON.stringify(message);
    if (this.measuring) this.measuredInputBytes += this.encoder.encode(data).byteLength;
    this.socket.send(data);
  }
  private settle(id: string, pending: Pending): void {if (pending.ack && pending.result) this.pending.delete(id);}
  private receipt(): void {this.wire({type: "received", eventSequence: this.latestEventSequence});}
  private recordPhase(): void {
    if (this.measuring) this.phaseWallMs[this.phase] = (this.phaseWallMs[this.phase] ?? 0) + performance.now() - this.phaseAt;
    this.phaseAt = performance.now();
  }
  private setPhase(phase: CombatSnapshot["phase"]): void {if (phase !== this.phase) {this.recordPhase(); this.phase = phase;}}
  private tick(tick: number): void {
    this.latestAuthorityTick = Math.max(this.latestAuthorityTick, tick);
    if (tick <= this.lastTick) return;
    const now = performance.now();
    if (this.measuring && this.lastTick >= 0) this.tickDeliveries.push({ticks: tick - this.lastTick, wallMs: now - this.lastTickAt});
    this.lastTick = tick; this.lastTickAt = now;
  }
  private event(wrapped: ServerEvent): void {
    if (this.snapshot !== null) {
      if (wrapped.eventSequence <= this.latestEventSequence) {this.duplicateEvents++; return;}
      if (wrapped.eventSequence !== this.latestEventSequence + 1) this.missingEvents += wrapped.eventSequence - this.latestEventSequence - 1;
    }
    this.latestEventSequence = wrapped.eventSequence;
    this.tick(wrapped.tick);
    const event = wrapped.event;
    if (event.kind === "playerChanged") this.players.set(event.player.playerId, event.player);
    if (event.kind === "phaseChanged") this.setPhase(event.phase);
    if (event.kind === "projectileSpawn" || event.kind === "projectileSegment" || event.kind === "projectileTerminal") {
      this.bulletEvents.set(wrapped.eventSequence, JSON.stringify(wrapped));
    }
    if (event.kind === "projectileSpawn") {
      this.projectiles.add(event.projectile.projectileId);
      this.maximumProjectiles = Math.max(this.maximumProjectiles, this.projectiles.size);
    }
    if (event.kind === "projectileTerminal") {this.projectiles.delete(event.projectileId); count(this.terminalReasons, event.reason);}
    if (event.kind === "commandResult" && event.playerId === this.playerId) {
      const pending = this.pending.get(event.commandId);
      if (!pending || pending.result) {this.errors.push("unexpectedCommandResult"); return;}
      pending.result = true; this.totalResults++;
      if (pending.measured) {
        if (event.accepted && pending.shotId !== null) this.acceptedShotIds.add(pending.shotId);
        this.resultMs.push(performance.now() - pending.at);
        count(event.accepted ? this.accepted : this.refusals, event.accepted ? pending.kind : `${pending.kind}:${event.reason ?? "unknown"}`);
      }
      this.settle(event.commandId, pending);
    }
  }
}

export const sleep = (milliseconds: number): Promise<void> => new Promise(resolve => setTimeout(resolve, milliseconds));
export async function until(predicate: () => boolean, timeout = 3000): Promise<void> {
  const deadline = performance.now() + timeout;
  while (!predicate() && performance.now() < deadline) await sleep(5);
  if (!predicate()) throw new Error("Load barrier did not converge");
}
export function percentiles(values: number[]): {samples: number; p50: number | null; p95: number | null; p99: number | null; max: number | null} {
  const sorted = [...values].sort((a, b) => a - b);
  const at = (q: number): number | null => sorted.length === 0 ? null : Math.round(sorted[Math.max(0, Math.ceil(sorted.length * q) - 1)]! * 100) / 100;
  return {samples: sorted.length, p50: at(0.5), p95: at(0.95), p99: at(0.99), max: at(1)};
}
