import { StrictMode } from "react";
import { act, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";

import { App } from "./App";
import { createDemoSnapshot } from "./data/demoFixtures";
import type { SpectatorSnapshot } from "./domain/spectator";

const sockets=vi.hoisted(()=>({clients:[] as {
  closed:boolean; next:((snapshot:SpectatorSnapshot|null)=>void)|null;
  stopQuery:ReturnType<typeof vi.fn>; stopConnection:ReturnType<typeof vi.fn>;
}[]}));
vi.mock("convex/browser",()=>({ConvexClient:class {
  entry={closed:false,next:null as ((snapshot:SpectatorSnapshot|null)=>void)|null,
    stopQuery:vi.fn(),stopConnection:vi.fn()};
  constructor(){sockets.clients.push(this.entry);}
  connectionState(){return {isWebSocketConnected:!this.entry.closed};}
  subscribeToConnectionState(){return this.entry.stopConnection;}
  onUpdate(_query:unknown,_request:unknown,next:(snapshot:SpectatorSnapshot|null)=>void){
    this.entry.next=next;return this.entry.stopQuery;
  }
  close(){this.entry.closed=true;return Promise.resolve();}
}}));
afterEach(()=>{vi.unstubAllEnvs();sockets.clients=[];});

describe("App StrictMode socket ownership",()=>{
  it("survives setup-cleanup-setup with one live subscription and closes it on unmount",()=>{
    vi.stubEnv("VITE_CONVEX_URL","https://example.convex.cloud");
    window.history.replaceState({},"","/?match=ARENA4");
    const {unmount}=render(<StrictMode><App /></StrictMode>);
    const live=sockets.clients.filter(client=>!client.closed && client.next!==null);
    expect(live).toHaveLength(1);
    expect(sockets.clients.filter(client=>!client.closed)).toHaveLength(1);
    act(()=>live[0]!.next!(createDemoSnapshot("ARENA4","arena")));
    expect(screen.getByRole("heading",{name:"LIVE ARENA"})).toBeInTheDocument();
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    unmount();
    expect(sockets.clients.every(client=>client.closed)).toBe(true);
    for(const client of sockets.clients){
      expect(client.stopQuery).toHaveBeenCalledOnce();
      expect(client.stopConnection).toHaveBeenCalledOnce();
    }
  });
  it("opens no socket for an unselected StrictMode render",()=>{
    vi.stubEnv("VITE_CONVEX_URL","https://example.convex.cloud");
    const {unmount}=render(<StrictMode><App /></StrictMode>);
    expect(sockets.clients).toHaveLength(0);
    unmount();
  });
});

describe("App route and demo integration", () => {
  it("starts with no selected duel", () => {
    render(<App />);
    expect(screen.getByText("VICTORIA PEW PEW")).toBeInTheDocument();
    expect(
      screen.getByRole("heading", { name: "NO MATCH SELECTED" }),
    ).toBeInTheDocument();
  });

  it("opens the deterministic G2 active fixture from the duel route", async () => {
    window.history.replaceState({}, "", "/?match=VKZ001&demo=active");
    render(<App />);

    expect(await screen.findByTestId("match-code")).toHaveTextContent("VKZ001");
    expect(screen.getByText("DEMO FIXTURE")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "LIVE DUEL" })).toBeInTheDocument();
    expect(screen.queryByText(/radar|kills|deaths|winner/i)).not.toBeInTheDocument();
  });

  it("keeps duel selection in the shareable URL", async () => {
    const user = userEvent.setup();
    render(<App />);

    await user.type(screen.getByLabelText("6-CHARACTER MATCH CODE"), "vkz001");
    await user.click(screen.getByRole("button", { name: "WATCH MATCH" }));

    expect(await screen.findByTestId("match-code")).toHaveTextContent("VKZ001");
    expect(new URL(window.location.href).searchParams.get("match")).toBe("VKZ001");
  });

  it("maps initial feed failures to frozen safe copy", async () => {
    window.history.replaceState({}, "", "/?match=ERR001&demo=error");
    render(<App />);

    expect(await screen.findByRole("alert")).toHaveTextContent(
      "CAN’T REACH THE MATCH",
    );
    expect(screen.queryByText(/deterministic feed is unavailable/i)).not.toBeInTheDocument();
  });

  it("retains the live fixture when its feed becomes degraded", async () => {
    window.history.replaceState({}, "", "/?match=STALE1&demo=degraded");
    render(<App />);

    expect(await screen.findByText("CONNECTION INTERRUPTED")).toBeInTheDocument();
    expect(
      screen.getByRole("progressbar", { name: "VALE health, 66 of 100" }),
    ).toHaveValue(66);
  });
});
