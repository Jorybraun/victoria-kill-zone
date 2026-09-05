import { LIMITS, type ServerMessage } from "@vkz/combat-protocol";

const encoder = new TextEncoder();
export const MAX_UNACKNOWLEDGED_EVENTS = 256;
const MAX_UNACKNOWLEDGED_BYTES = 256 * 1024;

export class Connection {
  receivedSequence: number;
  sentSequence: number;
  lastActivityAt: number;
  private tokens = 90;
  private refillAt: number;
  private outstandingBytes = 0;
  private readonly bytesBySequence = new Map<number, number>();
  private commandTokens = 90;
  private commandRefillAt: number;
  private pingTokens = 5;
  private pingRefillAt: number;

  constructor(readonly socket: WebSocket, readonly playerId: string, eventSequence: number, now: number) {
    this.receivedSequence = eventSequence;
    this.sentSequence = eventSequence;
    this.lastActivityAt = now;
    this.refillAt = now;
    this.commandRefillAt = now;
    this.pingRefillAt = now;
  }

  admitCommand(now: number): boolean {
    this.commandTokens = Math.min(90, this.commandTokens + Math.max(0, now - this.commandRefillAt) * LIMITS.commandsPerSecond / 1000);
    this.commandRefillAt = now;
    if (this.commandTokens < 1) return false;
    this.commandTokens -= 1;
    return true;
  }

  admitPing(now: number): boolean {
    this.pingTokens = Math.min(5, this.pingTokens + Math.max(0, now - this.pingRefillAt) * 2 / 1000);
    this.pingRefillAt = now;
    if (this.pingTokens < 1) return false;
    this.pingTokens -= 1;
    return true;
  }

  admit(now: number, perSecond: number): boolean {
    this.tokens = Math.min(90, this.tokens + Math.max(0, now - this.refillAt) * perSecond / 1000);
    this.refillAt = now;
    if (this.tokens < 1) return false;
    this.tokens -= 1;
    this.lastActivityAt = now;
    return true;
  }

  acknowledge(sequence: number): boolean {
    if (sequence < this.receivedSequence || sequence > this.sentSequence) return false;
    this.receivedSequence = sequence;
    for (const [through, bytes] of this.bytesBySequence) {
      if (through > sequence) break;
      this.outstandingBytes -= bytes;
      this.bytesBySequence.delete(through);
    }
    return true;
  }

  send(message: ServerMessage, eventSequence?: number): boolean {
    return this.sendSerialized(JSON.stringify(message), eventSequence);
  }

  sendSerialized(message: string, eventSequence?: number): boolean {
    if (this.socket.readyState !== WebSocket.OPEN) return false;
    const bytes = encoder.encode(message).byteLength;
    const sentThrough = Math.max(this.sentSequence, eventSequence ?? this.sentSequence);
    if (bytes > LIMITS.serverMessageBytes || this.outstandingBytes + bytes > MAX_UNACKNOWLEDGED_BYTES || sentThrough - this.receivedSequence > MAX_UNACKNOWLEDGED_EVENTS) {
      this.close(4008, "resume-required");
      return false;
    }
    try {
      this.socket.send(message);
      this.outstandingBytes += bytes;
      this.bytesBySequence.set(sentThrough, (this.bytesBySequence.get(sentThrough) ?? 0) + bytes);
      this.sentSequence = sentThrough;
      return true;
    } catch {
      this.close(1011, "socket-send-failed");
      return false;
    }
  }

  close(code: number, reason: string): void {
    try { this.socket.close(code, reason); } catch { /* Socket already detached. */ }
  }
}
