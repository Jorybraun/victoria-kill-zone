import { render, screen, within } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { createDemoSnapshot } from "../data/demoFixtures";
import { viewKindForMatch, type SpectatorSnapshot } from "../domain/spectator";
import { SpectatorShell } from "./SpectatorShell";

function show(snapshot: SpectatorSnapshot) {
  return render(<SpectatorShell state={{kind:viewKindForMatch(snapshot.match), code:snapshot.match.code, source:"demo", snapshot}}
    onSelectMatch={vi.fn()} onRetry={vi.fn()} />);
}

describe("arena spectator", () => {
  it("shows all four supplied members and scores in server order", () => {
    const snapshot=createDemoSnapshot("ARENA4", "arena");
    show(snapshot);
    const cards=within(screen.getByLabelText("Arena players")).getAllByRole("article");
    expect(cards).toHaveLength(4);
    snapshot.players.forEach((player,index)=>{
      expect(within(cards[index]!).getByRole("heading",{name:player.displayName})).toBeInTheDocument();
      expect(within(cards[index]!).getByLabelText(`${player.displayName} combat score`)).toHaveTextContent(`KILLS${player.kills}DEATHS${player.deaths}`);
    });
    expect(screen.getByRole("heading",{name:"LIVE ARENA"})).toBeInTheDocument();
    expect(screen.queryByText("MARKERLESS 1V1 DUEL")).not.toBeInTheDocument();
    expect(screen.queryByText("READY")).not.toBeInTheDocument();
  });
  it.each([
    ["arena-calibrating", "ALIGNING ARENA", "waiting"],
    ["arena-paused", "ARENA PAUSED", "active"],
  ] as const)("shows %s without claiming live combat", (fixture,title,kind) => {
    const snapshot=createDemoSnapshot("ARENA4",fixture);
    expect(viewKindForMatch(snapshot.match)).toBe(kind);
    show(snapshot);
    expect(screen.getByRole("heading",{name:title})).toBeInTheDocument();
    expect(screen.queryByRole("heading",{name:/LIVE/})).not.toBeInTheDocument();
    expect(screen.getByLabelText("EMBER combat score")).toHaveTextContent("KILLS4");
  });
  it("uses the authoritative arena phase even if legacy expiry says finished", () => {
    const snapshot=createDemoSnapshot("ARENA4","arena-paused");
    snapshot.match.phase="finished";
    show(snapshot);
    expect(screen.getByRole("heading",{name:"ARENA PAUSED"})).toBeInTheDocument();
    expect(screen.queryByRole("button",{name:"WATCH ANOTHER MATCH"})).not.toBeInTheDocument();
  });
  it("shows configured open slots and avoids a live claim for missing arena phase", () => {
    const snapshot=createDemoSnapshot("ARENA4","arena");
    delete snapshot.match.combatPhase;
    show({...snapshot, players:snapshot.players.slice(0,2)});
    expect(screen.getByRole("heading",{name:"MATCH STATE UNAVAILABLE"})).toBeInTheDocument();
    expect(screen.getByLabelText("Player C slot, open")).toBeInTheDocument();
    expect(screen.getByLabelText("Player D slot, open")).toBeInTheDocument();
  });
  it("shows only the supplied winner, including a third roster member", () => {
    show(createDemoSnapshot("ARENA4","arena-ended"));
    expect(screen.getByLabelText("Match result")).toHaveTextContent("EMBER WINS");
    expect(screen.queryByText(/RESPAWNING IN/)).not.toBeInTheDocument();
    expect(screen.getByRole("button",{name:"WATCH ANOTHER MATCH"})).toBeInTheDocument();
  });
  it("shows a draw only for a finished arena without an authoritative winner", () => {
    const snapshot=createDemoSnapshot("ARENA4","arena-ended");
    delete snapshot.match.winnerPlayerId;
    const {unmount}=show(snapshot);
    expect(screen.getByLabelText("Match result")).toHaveTextContent("MATCH DRAW");
    unmount();
    show(createDemoSnapshot("DUEL02","ended"));
    expect(screen.queryByLabelText("Match result")).not.toBeInTheDocument();
    expect(screen.getByLabelText("Duel players")).toBeInTheDocument();
  });
  it("labels retained arena scores without LIVE during a connection outage", () => {
    const snapshot=createDemoSnapshot("ARENA4","arena");
    render(<SpectatorShell state={{kind:"degraded",code:"ARENA4",source:"convex",snapshot,lastSyncedAt:snapshot.serverNow}}
      onSelectMatch={vi.fn()} onRetry={vi.fn()} />);
    expect(screen.getByRole("heading",{name:"LAST RECEIVED STATE"})).toBeInTheDocument();
    expect(screen.getByLabelText("Arena players").querySelectorAll("article")).toHaveLength(4);
    expect(screen.getByRole("button",{name:"TRY AGAIN"})).toBeEnabled();
  });
});
