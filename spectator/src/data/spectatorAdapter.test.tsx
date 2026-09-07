import { act, renderHook } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { createDemoSnapshot } from "./demoFixtures";
import {
  useSpectatorSnapshot,
  type SpectatorSnapshotAdapter,
  type SpectatorSnapshotObserver,
} from "./spectatorAdapter";

function createControlledAdapter(): {
  adapter: SpectatorSnapshotAdapter;
  observers: SpectatorSnapshotObserver[];
} {
  const observers: SpectatorSnapshotObserver[] = [];
  return {
    observers,
    adapter: {
      source: "convex",
      subscribe(_request, observer) {
        observers.push(observer);
        return () => undefined;
      },
      dispose() {
        // The test adapter owns no external resources.
      },
    },
  };
}

describe("useSpectatorSnapshot", () => {
  it("keeps recovery bounded while fresh updates continue, retaining the newest snapshot", () => {
    vi.useFakeTimers();
    const {adapter,observers}=createControlledAdapter();
    const snapshot=createDemoSnapshot("ARENA4","arena");
    const {result,unmount}=renderHook(()=>useSpectatorSnapshot(adapter,"ARENA4",0));
    act(()=>observers[0]!.next(snapshot));
    act(()=>observers[0]!.error(new Error("interrupted")));
    act(()=>observers[0]!.next(snapshot));
    act(()=>{vi.advanceTimersByTime(500);});
    const updated={...snapshot,serverNow:snapshot.serverNow+500};
    act(()=>observers[0]!.next(updated));
    expect(result.current).toMatchObject({kind:"recovery",snapshot:updated});
    act(()=>{vi.advanceTimersByTime(1300);});
    expect(result.current).toMatchObject({kind:"ready",snapshot:updated});
    unmount();vi.useRealTimers();
  });

  it("retains a stale snapshot, restores atomically, and de-duplicates recovery events", async () => {
    vi.useFakeTimers();
    const { adapter, observers } = createControlledAdapter();
    const initial = createDemoSnapshot("LIVE01", "active");
    const hit = initial.events[0]!;
    const { result, rerender } = renderHook(
      ({ retryToken }) =>
        useSpectatorSnapshot(adapter, "LIVE01", retryToken),
      { initialProps: { retryToken: 0 } },
    );

    expect(result.current.kind).toBe("loading");
    act(() => observers[0]!.next(initial));
    expect(result.current).toMatchObject({ kind: "ready", snapshot: initial });

    act(() => observers[0]!.error(new Error("socket closed")));
    expect(result.current).toMatchObject({
      kind: "degraded",
      snapshot: initial,
      lastSyncedAt: initial.serverNow,
    });

    rerender({ retryToken: 1 });
    expect(result.current.kind).toBe("degraded");

    const recovered = {
      ...initial,
      serverNow: initial.serverNow + 5_000,
      events: [hit, hit],
    };
    act(() => observers[1]!.next(recovered));
    expect(result.current.kind).toBe("recovery");
    if (result.current.kind === "recovery") {
      expect(result.current.snapshot.serverNow).toBe(recovered.serverNow);
      expect(result.current.snapshot.events).toHaveLength(1);
    }

    await act(() => vi.advanceTimersByTime(1_800));
    expect(result.current.kind).toBe("ready");
    vi.useRealTimers();
  });

  it("uses an error only when no safe snapshot has ever arrived, then announces recovery", () => {
    const { adapter, observers } = createControlledAdapter();
    const { result, rerender } = renderHook(
      ({ retryToken }) =>
        useSpectatorSnapshot(adapter, "FAIL01", retryToken),
      { initialProps: { retryToken: 0 } },
    );

    act(() => observers[0]!.error(new Error("internal transport detail")));
    expect(result.current.kind).toBe("error");

    rerender({ retryToken: 1 });
    expect(result.current.kind).toBe("loading");
    act(() =>
      observers[1]!.next(createDemoSnapshot("FAIL01", "waiting")),
    );
    expect(result.current.kind).toBe("recovery");
  });
});
