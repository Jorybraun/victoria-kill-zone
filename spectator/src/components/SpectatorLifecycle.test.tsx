import { act, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createDemoSnapshot } from "../data/demoFixtures";
import type { SpectatorViewState } from "../domain/spectator";
import { PlayerCard } from "./PlayerCard";
import { SpectatorShell } from "./SpectatorShell";

afterEach(() => { vi.useRealTimers(); });

function shell(state: SpectatorViewState) {
  return <SpectatorShell state={state} onSelectMatch={vi.fn()} onRetry={vi.fn()} />;
}

describe("retained spectator timing", () => {
  it("does not rewind a cached countdown on interruption, recovery, or recovery completion", () => {
    vi.useFakeTimers({ toFake: ["setInterval", "clearInterval", "performance"] });
    const snapshot = createDemoSnapshot("START1", "countdown");
    const view = { code: "START1", source: "demo" as const, snapshot };
    const { rerender } = render(shell({ kind: "waiting", ...view }));
    expect(screen.getByTestId("countdown")).toHaveTextContent("3");
    act(() => { vi.advanceTimersByTime(1_000); });
    expect(screen.getByTestId("countdown")).toHaveTextContent("2");

    rerender(shell({ kind: "degraded", ...view, lastSyncedAt: snapshot.serverNow }));
    expect(screen.queryByTestId("countdown")).not.toBeInTheDocument();
    act(() => { vi.advanceTimersByTime(3_000); });
    rerender(shell({ kind: "recovery", currentKind: "waiting", ...view }));
    expect(screen.getByTestId("countdown")).toHaveTextContent("0");
    act(() => { vi.advanceTimersByTime(1_800); });
    rerender(shell({ kind: "waiting", ...view }));
    expect(screen.getByTestId("countdown")).toHaveTextContent("0");
  });

  it("starts a new timing anchor only when the authoritative snapshot timestamp changes", () => {
    vi.useFakeTimers({ toFake: ["setInterval", "clearInterval", "performance"] });
    const snapshot = createDemoSnapshot("START1", "countdown");
    const view = { kind: "waiting" as const, code: "START1", source: "demo" as const, snapshot };
    const { rerender } = render(shell(view));
    act(() => { vi.advanceTimersByTime(2_000); });
    expect(screen.getByTestId("countdown")).toHaveTextContent("1");
    rerender(shell({ ...view, snapshot: { ...snapshot, serverNow: snapshot.serverNow + 2_000 } }));
    expect(screen.getByTestId("countdown")).toHaveTextContent("1");
    act(() => { vi.advanceTimersByTime(1_000); });
    expect(screen.getByTestId("countdown")).toHaveTextContent("0");
  });
});

describe("terminal life-state accessibility", () => {
  it.each(["finished", "cancelled"] as const)("names the displayed eliminated state after %s", phase => {
    const snapshot = createDemoSnapshot("ARENA4", "arena");
    const player = snapshot.players[3]!;
    render(<PlayerCard player={player} slot="D" mode="arena" phase={phase} serverNow={snapshot.serverNow} />);
    expect(screen.getByLabelText(`${player.displayName} life state, ELIMINATED`)).toHaveTextContent("ELIMINATED");
    expect(screen.queryByLabelText(/life state, respawning/i)).not.toBeInTheDocument();
  });
});
