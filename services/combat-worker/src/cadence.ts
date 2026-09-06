import { LIMITS } from "@vkz/combat-protocol";

/** Monotonic timer scheduling, independent of persisted logical match time. */
export class TickCadence {
  constructor(private anchor: number) {}
  reset(now: number): void { this.anchor = now; }
  stalled(now: number): boolean { return now - this.anchor > 250; }
  delay(now: number): number { return Math.max(1, LIMITS.tickMs - Math.max(0, now - this.anchor)); }
  committedTick(): void { this.anchor += LIMITS.tickMs; }
  interpolate(matchTimeMs: number, now: number): number {
    return matchTimeMs + Math.min(LIMITS.tickMs, Math.max(0, now - this.anchor));
  }
}
