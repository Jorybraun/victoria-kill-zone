import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";

import { createDemoSnapshot, DEMO_NOW } from "../data/demoFixtures";
import type {
  SpectatorSnapshot,
  SpectatorViewState,
} from "../domain/spectator";
import { SpectatorShell } from "./SpectatorShell";

function renderShell(state: SpectatorViewState) {
  const onSelectMatch = vi.fn();
  const onRetry = vi.fn();
  const view = render(
    <SpectatorShell
      state={state}
      onSelectMatch={onSelectMatch}
      onRetry={onRetry}
    />,
  );
  return { ...view, onSelectMatch, onRetry };
}

describe("SpectatorShell G2 contract", () => {
  it("renders the no-selection copy and keyboard-reachable code control", async () => {
    const user = userEvent.setup();
    const { onSelectMatch } = renderShell({
      kind: "no-selection",
      initialCode: "",
      isDemo: true,
    });

    expect(
      screen.getByRole("heading", { name: "NO DUEL SELECTED" }),
    ).toBeInTheDocument();
    expect(
      screen.getByText("ENTER A 6-CHARACTER CODE TO WATCH"),
    ).toBeInTheDocument();

    await user.tab();
    expect(screen.getByRole("link", { name: "SKIP TO DUEL" })).toHaveFocus();
    await user.tab();
    expect(screen.getByLabelText("6-CHARACTER DUEL CODE")).toHaveFocus();
    await user.type(screen.getByLabelText("6-CHARACTER DUEL CODE"), "ab c123");
    await user.tab();
    expect(screen.getByRole("button", { name: "WATCH DUEL" })).toHaveFocus();
    await user.keyboard("{Enter}");

    expect(onSelectMatch).toHaveBeenCalledWith("ABC123");
  });

  it("associates and focuses frozen validation copy after a failed submission", async () => {
    const user = userEvent.setup();
    const { onSelectMatch } = renderShell({
      kind: "no-selection",
      initialCode: "",
      isDemo: false,
    });

    await user.type(screen.getByLabelText("6-CHARACTER DUEL CODE"), "ABC");
    await user.click(screen.getByRole("button", { name: "WATCH DUEL" }));

    const error = screen.getByRole("alert");
    expect(error).toHaveTextContent("DUEL CODE NOT FOUND");
    expect(error).toHaveFocus();
    expect(screen.getByLabelText("6-CHARACTER DUEL CODE")).toHaveAttribute(
      "aria-describedby",
      expect.stringContaining("duel-code-error"),
    );
    expect(onSelectMatch).not.toHaveBeenCalled();
  });

  it("renders loading with the selected code retained", () => {
    renderShell({ kind: "loading", code: "LOAD01", source: "convex" });

    expect(screen.getByRole("status")).toHaveTextContent(
      "CONNECTING TO DUEL…",
    );
    expect(screen.getByRole("main")).toHaveAttribute("aria-busy", "true");
    expect(screen.getByText("LOAD01")).toBeInTheDocument();
  });

  it("renders a waiting duel with an explicit open slot and text statuses", () => {
    renderShell({
      kind: "waiting",
      code: "WAIT01",
      source: "demo",
      snapshot: createDemoSnapshot("WAIT01", "waiting"),
    });

    expect(
      screen.getByRole("heading", { name: "WAITING FOR DUEL" }),
    ).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "ROOK" })).toBeInTheDocument();
    expect(screen.getByLabelText("ROOK status")).toHaveTextContent(
      "READYCONNECTED",
    );
    expect(screen.getByLabelText("Player B slot, open")).toHaveTextContent(
      "OPEN SLOT",
    );
    expect(screen.getByLabelText("Player B slot, open")).toHaveTextContent(
      "NOT READY",
    );
    expect(screen.getByTestId("empty-events")).toHaveTextContent(
      "NO EVENTS YET",
    );
  });

  it("renders the authoritative countdown", () => {
    renderShell({
      kind: "waiting",
      code: "START1",
      source: "demo",
      snapshot: createDemoSnapshot("START1", "countdown"),
    });

    expect(
      screen.getByRole("heading", { name: "DUEL STARTS IN" }),
    ).toBeInTheDocument();
    expect(screen.getByTestId("countdown")).toHaveTextContent("3");
  });

  it("shows only the G2 active health and authoritative event surface", () => {
    renderShell({
      kind: "active",
      code: "VKZ001",
      source: "demo",
      snapshot: createDemoSnapshot("VKZ001", "active"),
    });

    expect(screen.getByTestId("match-code")).toHaveTextContent("VKZ001");
    expect(screen.getByRole("heading", { name: "LIVE DUEL" })).toBeInTheDocument();
    expect(
      screen.getByRole("progressbar", { name: "ROOK health, 100 of 100" }),
    ).toHaveValue(100);
    expect(
      screen.getByRole("progressbar", { name: "VALE health, 66 of 100" }),
    ).toHaveValue(66);
    expect(screen.getByText("ROOK HIT VALE • TORSO −34")).toBeInTheDocument();
    expect(
      screen.queryByText(/radar|position|kills|deaths|accuracy|ammo|winner|rematch/i),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: /fire|ready|start|end|reload/i }),
    ).not.toBeInTheDocument();
  });

  it("shows additive Phase 0 life state, K/D, and elimination evidence", () => {
    const g2Snapshot = createDemoSnapshot("KO0001", "active");
    const phase0Snapshot: SpectatorSnapshot = {
      ...g2Snapshot,
      players: [
        {
          ...g2Snapshot.players[0]!,
          kills: 3,
          deaths: 1,
          lifeState: "alive",
        },
        {
          ...g2Snapshot.players[1]!,
          health: 0,
          kills: 1,
          deaths: 3,
          lifeState: "dead",
        },
      ],
      events: [
        {
          id: "event-elimination",
          type: "eliminated",
          actorPlayerId: "player-rook",
          targetPlayerId: "player-vale",
          zone: "head",
          damage: 66,
          message: "ROOK ELIMINATED VALE • HEAD −66",
          createdAt: DEMO_NOW,
        },
        ...g2Snapshot.events,
      ],
    };

    renderShell({
      kind: "active",
      code: "KO0001",
      source: "convex",
      snapshot: phase0Snapshot,
    });

    expect(screen.getByLabelText("ROOK combat score")).toHaveTextContent(
      "KILLS3DEATHS1",
    );
    expect(screen.getByLabelText("VALE combat score")).toHaveTextContent(
      "KILLS1DEATHS3",
    );
    expect(screen.getByLabelText("VALE life state, dead")).toHaveTextContent(
      "ELIMINATED",
    );
    expect(screen.getByTestId("player-card-player-vale")).toHaveClass(
      "player-card--dead",
    );
    expect(
      screen.getByRole("progressbar", { name: "VALE health, 0 of 100" }),
    ).toHaveValue(0);
    expect(screen.getByText("ELIMINATION")).toBeInTheDocument();
    expect(screen.getByText("ROOK ELIMINATED VALE • HEAD −66")).toBeInTheDocument();
  });

  it("makes an authoritative respawn window visible without inventing it for G2", () => {
    const g2Snapshot = createDemoSnapshot("BACK02", "active");
    const phase0Snapshot: SpectatorSnapshot = {
      ...g2Snapshot,
      players: [
        g2Snapshot.players[0]!,
        {
          ...g2Snapshot.players[1]!,
          health: 0,
          kills: 0,
          deaths: 1,
          lifeState: "respawning",
          respawnAt: DEMO_NOW + 4_200,
        },
      ],
      events: [
        {
          id: "event-respawned",
          type: "respawned",
          actorPlayerId: "player-vale",
          message: "VALE RETURNED TO THE DUEL",
          createdAt: DEMO_NOW - 8_000,
        },
        ...g2Snapshot.events,
      ],
    };

    renderShell({
      kind: "active",
      code: "BACK02",
      source: "convex",
      snapshot: phase0Snapshot,
    });

    expect(
      screen.getByLabelText("VALE life state, respawning"),
    ).toHaveTextContent("RESPAWNING IN 5S");
    expect(screen.getByTestId("player-card-player-vale")).toHaveClass(
      "player-card--respawning",
    );
    expect(screen.getByText("RESPAWN")).toBeInTheDocument();
    expect(screen.getByText("VALE RETURNED TO THE DUEL")).toBeInTheDocument();
  });

  it("keeps server order and de-duplicates replayed event identities", () => {
    const snapshot = createDemoSnapshot("ORDER1", "active");
    const first = {
      ...snapshot.events[0]!,
      id: "server-first",
      message: "FIRST SERVER RECORD",
      createdAt: DEMO_NOW - 60_000,
    };
    const second = {
      ...snapshot.events[1]!,
      id: "server-second",
      message: "SECOND SERVER RECORD",
      createdAt: DEMO_NOW,
    };

    renderShell({
      kind: "active",
      code: "ORDER1",
      source: "convex",
      snapshot: { ...snapshot, events: [first, first, second] },
    });

    const items = screen.getAllByRole("listitem");
    expect(items).toHaveLength(2);
    expect(within(items[0]!).getByText("FIRST SERVER RECORD")).toBeInTheDocument();
    expect(within(items[1]!).getByText("SECOND SERVER RECORD")).toBeInTheDocument();
    expect(screen.getAllByText("FIRST SERVER RECORD")).toHaveLength(1);
  });

  it("retains final values without making a winner or rematch claim", async () => {
    const user = userEvent.setup();
    const { onSelectMatch } = renderShell({
      kind: "ended",
      code: "END001",
      source: "demo",
      snapshot: createDemoSnapshot("END001", "ended"),
    });

    expect(
      screen.getByRole("heading", { name: "DUEL COMPLETE" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("progressbar", { name: "VALE health, 66 of 100" }),
    ).toHaveValue(66);
    expect(screen.queryByText(/winner|wins|rematch/i)).not.toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "WATCH ANOTHER DUEL" }));
    expect(onSelectMatch).toHaveBeenCalledWith(null);
  });

  it("renders cancellation distinctly", () => {
    renderShell({
      kind: "ended",
      code: "STOP01",
      source: "demo",
      snapshot: createDemoSnapshot("STOP01", "cancelled"),
    });

    expect(
      screen.getByRole("heading", { name: "DUEL CANCELLED" }),
    ).toBeInTheDocument();
  });

  it("retains and labels the last snapshot while degraded", async () => {
    const user = userEvent.setup();
    const { onRetry } = renderShell({
      kind: "degraded",
      code: "STALE1",
      source: "convex",
      snapshot: createDemoSnapshot("STALE1", "active"),
      lastSyncedAt: DEMO_NOW,
    });

    expect(screen.getByRole("status")).toHaveTextContent(
      "LIVE FEED INTERRUPTED",
    );
    expect(screen.getByRole("status")).toHaveTextContent("LAST SYNC");
    expect(
      screen.getByRole("progressbar", { name: "VALE health, 66 of 100" }),
    ).toHaveValue(66);
    expect(screen.getByRole("main")).toHaveAccessibleName(
      "Last verified duel snapshot",
    );

    await user.click(screen.getByRole("button", { name: "TRY AGAIN" }));
    expect(onRetry).toHaveBeenCalledOnce();
  });

  it("announces recovery and does not replay a duplicate event", () => {
    const snapshot = createDemoSnapshot("BACK01", "active");
    const hit = snapshot.events[0]!;

    renderShell({
      kind: "recovery",
      currentKind: "active",
      code: "BACK01",
      source: "convex",
      snapshot: { ...snapshot, events: [hit, hit] },
    });

    expect(screen.getByRole("status")).toHaveTextContent("LIVE FEED RESTORED");
    expect(screen.getAllByText("ROOK HIT VALE • TORSO −34")).toHaveLength(1);
  });

  it("keeps a failed code editable and exposes only mapped error copy", async () => {
    const user = userEvent.setup();
    const { onRetry, onSelectMatch } = renderShell({
      kind: "error",
      code: "ERR001",
      source: "convex",
      reason: "network",
    });

    const input = screen.getByLabelText("6-CHARACTER DUEL CODE");
    const error = screen.getByRole("alert");
    expect(input).toHaveValue("ERR001");
    expect(error).toHaveTextContent("CAN’T REACH THE DUEL");
    expect(error).toHaveFocus();

    await user.click(screen.getByRole("button", { name: "TRY AGAIN" }));
    expect(onRetry).toHaveBeenCalledOnce();

    await user.clear(input);
    await user.type(input, "NEW001");
    await user.click(screen.getByRole("button", { name: "TRY AGAIN" }));
    expect(onSelectMatch).toHaveBeenCalledWith("NEW001");
  });
});
