import {describe, expect, it} from "vitest";
import {NativeLoadClock, type NativeClockObservation} from "../benchmarks/native-clock.js";

const sample = (sent: number, offset: number, rtt: number, processing = 0): NativeClockObservation => ({
  localSentMs: sent, serverReceivedMs: sent + offset + rtt / 2,
  serverSentMs: sent + offset + rtt / 2 + processing, localReceivedMs: sent + rtt + processing,
});
const readyClock = (): NativeLoadClock => {
  const clock = new NativeLoadClock();
  for (let i = 0; i < 3; i++) clock.observe({localSentMs: 1000, serverReceivedMs: 10, serverSentMs: 10, localReceivedMs: 1020});
  return clock;
};

describe("native benchmark clock parity", () => {
  it("replays native testClockRequiresSeveralFreshBoundedSamples and resets all readiness", () => {
    const clock = new NativeLoadClock();
    expect(clock.matchTime(1000)).toBeNull();
    expect(clock.uncertaintyMs).toBe(Infinity);
    expect(clock.isReady(1000)).toBe(false);
    for (let index = 0; index < 3; index++) {
      const sent = 1000 + index * 100;
      expect(clock.observe({localSentMs: sent, serverReceivedMs: sent - 990, serverSentMs: sent - 990, localReceivedMs: sent + 20})).toBe(true);
      expect(clock.isReady(sent + 20)).toBe(index === 2);
    }
    expect(clock.matchTime(1250)).toBe(250);
    expect(clock.uncertaintyMs).toBe(10);
    expect(clock.isReady(5000)).toBe(false);
    clock.reset();
    expect(clock.matchTime(5000)).toBeNull();
    expect(clock.uncertaintyMs).toBe(Infinity);
    expect(clock.isReady(1220)).toBe(false);
    clock.observe(sample(5000, -1000, 20));
    expect(clock.isReady(5020)).toBe(false);
  });

  it("replays native testClockRejectsImpossibleTimingAndDetectsClockDiscontinuity", () => {
    const clock = new NativeLoadClock();
    expect(clock.observe({localSentMs: 100, serverReceivedMs: 100, serverSentMs: 99, localReceivedMs: 110})).toBe(false);
    expect(clock.observe({localSentMs: 100, serverReceivedMs: 100, serverSentMs: 100, localReceivedMs: 99})).toBe(false);
    for (let i = 0; i < 3; i++) clock.observe({localSentMs: 1000, serverReceivedMs: 10, serverSentMs: 10, localReceivedMs: 1020});
    expect(clock.isReady(1020)).toBe(true);
    expect(clock.observe({localSentMs: 1100, serverReceivedMs: 500, serverSentMs: 500, localReceivedMs: 1120})).toBe(true);
    expect(clock.isReady(1120)).toBe(false);
    expect(clock.uncertaintyMs).toBe(390);
    expect(clock.matchTime(1120)).toBe(120);
  });

  it("rejects nonfinite, negative, inverted and excessive RTT timestamps without altering a good estimate", () => {
    const clock = readyClock(), valid = sample(1100, -1000, 20);
    const invalid = Object.keys(valid).flatMap(key => [NaN, Infinity, -Infinity, -1].map(value => ({...valid, [key]: value})));
    invalid.push(
      {...valid, localReceivedMs: 1099},
      {...valid, serverSentMs: valid.serverReceivedMs - 1},
      {...valid, serverSentMs: valid.serverReceivedMs + 21},
      {...valid, localReceivedMs: 6100.001},
    );
    for (const observation of invalid) {
      expect(clock.observe(observation)).toBe(false);
      expect(clock.matchTime(1120)).toBe(120);
      expect(clock.uncertaintyMs).toBe(10);
      expect(clock.isReady(1020)).toBe(true);
      expect(clock.isReady(4020.001)).toBe(false);
    }
  });

  it("subtracts server processing from RTT and includes the exact zero and 5000 ms bounds", () => {
    const clock = new NativeLoadClock();
    expect(clock.observe({localSentMs: 1000, serverReceivedMs: 10, serverSentMs: 40, localReceivedMs: 1050})).toBe(true);
    expect(clock.uncertaintyMs).toBe(10);
    expect(clock.matchTime(1100)).toBe(100);
    clock.reset();
    expect(clock.observe(sample(1000, 0, 5000))).toBe(true);
    expect(clock.uncertaintyMs).toBe(2500);
    clock.reset();
    expect(clock.observe(sample(1000, 0, 0, 30))).toBe(true);
    expect(clock.uncertaintyMs).toBe(0);
    expect(clock.matchTime(1100)).toBe(1100);
  });

  it("keeps the earliest minimum-RTT offset when a newer RTT ties", () => {
    const clock = readyClock();
    clock.observe(sample(1100, -995, 20));
    expect(clock.matchTime(1120)).toBe(120);
    expect(clock.uncertaintyMs).toBe(10);
    expect(clock.isReady(1120)).toBe(true);
  });

  it("retains the low-RTT estimate through a delayed asymmetric reply within its uncertainty", () => {
    const clock = readyClock();
    clock.observe({localSentMs: 1300, serverReceivedMs: 310, serverSentMs: 310, localReceivedMs: 1700});
    expect(clock.matchTime(1700)).toBe(700);
    expect(clock.uncertaintyMs).toBe(10);
    expect(clock.isReady(1700)).toBe(true);
  });

  it("applies the exact 25 ms uncertainty and 3000 ms freshness gates", () => {
    for (const [rtt, ready] of [[50, true], [50.002, false]] as const) {
      const clock = new NativeLoadClock();
      for (let i = 0; i < 3; i++) clock.observe(sample(1000, 0, rtt));
      expect(clock.isReady(1000 + rtt)).toBe(ready);
    }
    const clock = readyClock();
    expect(clock.isReady(1019.999)).toBe(false);
    expect(clock.isReady(4020)).toBe(true);
    expect(clock.isReady(4020.001)).toBe(false);
    for (const invalid of [NaN, Infinity, -Infinity]) expect(clock.isReady(invalid)).toBe(false);
  });

  it("expires samples only after ten seconds and requires three retained samples again", () => {
    const clock = new NativeLoadClock();
    for (let i = 0; i < 3; i++) clock.observe(sample(1000, -1000, 2));
    clock.observe(sample(10_998, -990, 4)); // Receipt is exactly 10,000 ms after the first samples.
    expect(clock.matchTime(11_010)).toBe(10_010);
    expect(clock.uncertaintyMs).toBe(9);
    expect(clock.isReady(11_002)).toBe(true);
    clock.observe(sample(10_999, -990, 4));
    expect(clock.matchTime(11_010)).toBe(10_020);
    expect(clock.uncertaintyMs).toBe(2);
    expect(clock.isReady(11_003)).toBe(false);
    clock.observe(sample(11_000, -990, 4));
    expect(clock.isReady(11_004)).toBe(true);
  });

  it("evicts the oldest sample at seventeen even if it had the best RTT", () => {
    const clock = new NativeLoadClock();
    clock.observe(sample(1000, -1000, 2));
    for (let i = 1; i <= 15; i++) clock.observe(sample(1000 + i * 100, -990, 4));
    expect(clock.matchTime(2600)).toBe(1600);
    clock.observe(sample(2600, -990, 4));
    expect(clock.matchTime(2700)).toBe(1710);
    expect(clock.uncertaintyMs).toBe(2);
  });

  it("preserves a backward offset step when a new sample has the lowest RTT", () => {
    const clock = new NativeLoadClock();
    for (let i = 0; i < 3; i++) clock.observe(sample(1000, -900, 20));
    expect(clock.matchTime(1020)).toBe(120);
    clock.observe(sample(1020, -950, 2));
    // Native CombatClock neither slews nor floors against the previous estimate.
    expect(clock.matchTime(1022)).toBe(72);
    expect(clock.uncertaintyMs).toBe(1);
    expect(clock.isReady(1022)).toBe(true);
  });

  it("retains native finite-input validation and zero-floor semantics without extra clamps", () => {
    const clock = readyClock();
    expect(clock.matchTime(-1)).toBe(0);
    expect(clock.matchTime(999)).toBe(0);
    for (const invalid of [NaN, Infinity, -Infinity]) expect(clock.matchTime(invalid)).toBeNull();
    clock.reset();
    // Native validates the four input timestamps; it does not reject offset overflow.
    expect(clock.observe({localSentMs: 0, serverReceivedMs: Number.MAX_VALUE, serverSentMs: Number.MAX_VALUE, localReceivedMs: 0})).toBe(true);
    expect(clock.uncertaintyMs).toBe(0);
    expect(clock.matchTime(1)).toBe(Infinity);
  });
});
