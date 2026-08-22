import { describe, expect, it, vi } from "vitest";

import type { SpectatorSnapshot } from "../domain/spectator";
import { createDemoSnapshot, createDemoSpectatorAdapter } from "./demoFixtures";

describe("deterministic spectator adapter", () => {
  it("preserves the requested match code and sanitized public telemetry", () => {
    const snapshot = createDemoSnapshot("VKZ001", "active");

    expect(snapshot.match.code).toBe("VKZ001");
    expect(snapshot.players).toHaveLength(2);
    expect(snapshot.events[0]?.type).toBe("hit");
    expect(JSON.stringify(snapshot)).not.toMatch(/session|device|secret/i);
  });

  it("subscribes through a query-only observer contract", () => {
    const next = vi.fn<(snapshot: SpectatorSnapshot | null) => void>();
    const error = vi.fn<(subscriptionError: Error) => void>();
    const adapter = createDemoSpectatorAdapter("waiting");

    const unsubscribe = adapter.subscribe({ code: "WAIT01" }, { next, error });
    const snapshot = next.mock.calls[0]?.[0];

    expect(snapshot?.match.code).toBe("WAIT01");
    expect(snapshot?.match.phase).toBe("lobby");
    expect(error).not.toHaveBeenCalled();
    expect(typeof unsubscribe).toBe("function");
  });

  it("reports the explicit error fixture without returning invented state", () => {
    const next = vi.fn<(snapshot: SpectatorSnapshot | null) => void>();
    const error = vi.fn<(subscriptionError: Error) => void>();

    createDemoSpectatorAdapter("error").subscribe(
      { code: "ERR001" },
      { next, error },
    );

    expect(next).not.toHaveBeenCalled();
    expect(error.mock.calls[0]?.[0]).toBeInstanceOf(Error);
  });
});
