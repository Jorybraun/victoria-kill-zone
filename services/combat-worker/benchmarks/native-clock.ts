export interface NativeClockObservation {
  localSentMs: number;
  serverReceivedMs: number;
  serverSentMs: number;
  localReceivedMs: number;
}

type Sample = {offset: number; uncertainty: number; localReceived: number};

// Swift's max(0, value) uses comparison, including when finite inputs overflow.
const nativeMaxZero = (value: number): number => value >= 0 ? value : 0;

/** Benchmark port of iOS Services/Realtime/CombatClock.swift, including offset steps. */
export class NativeLoadClock {
  private samples: Sample[] = [];
  private offsetMs: number | null = null;
  private lastSampleAtMs: number | null = null;
  private estimatedUncertaintyMs = Infinity;

  get uncertaintyMs(): number {return this.estimatedUncertaintyMs;}

  reset(): void {
    this.samples = [];
    this.offsetMs = null;
    this.lastSampleAtMs = null;
    this.estimatedUncertaintyMs = Infinity;
  }

  observe({localSentMs, serverReceivedMs, serverSentMs, localReceivedMs}: NativeClockObservation): boolean {
    if (![localSentMs, serverReceivedMs, serverSentMs, localReceivedMs].every(value => Number.isFinite(value) && value >= 0)
      || localReceivedMs < localSentMs || serverSentMs < serverReceivedMs) return false;
    const rtt = (localReceivedMs - localSentMs) - (serverSentMs - serverReceivedMs);
    if (!(rtt >= 0 && rtt <= 5000)) return false;
    const offset = ((serverReceivedMs - localSentMs) + (serverSentMs - localReceivedMs)) / 2;
    this.samples = this.samples.filter(sample => localReceivedMs - sample.localReceived <= 10_000);
    this.samples.push({offset, uncertainty: rtt / 2, localReceived: localReceivedMs});
    if (this.samples.length > 16) this.samples.splice(0, this.samples.length - 16);
    let best = this.samples[0];
    if (!best) return false;
    // Swift min(by: <) retains the first sample when RTTs tie.
    for (const sample of this.samples) if (sample.uncertainty < best.uncertainty) best = sample;
    this.estimatedUncertaintyMs = best.uncertainty + nativeMaxZero(Math.abs(offset - best.offset) - rtt / 2);
    this.offsetMs = best.offset;
    this.lastSampleAtMs = localReceivedMs;
    return true;
  }

  isReady(localMs: number): boolean {
    return this.lastSampleAtMs !== null && this.samples.length >= 3 && this.estimatedUncertaintyMs <= 25
      && localMs >= this.lastSampleAtMs && localMs - this.lastSampleAtMs <= 3000;
  }

  matchTime(localMs: number): number | null {
    if (!Number.isFinite(localMs) || this.offsetMs === null) return null;
    return nativeMaxZero(localMs + this.offsetMs);
  }
}
