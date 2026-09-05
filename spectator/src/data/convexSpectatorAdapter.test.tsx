import { act, renderHook } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { SpectatorSnapshot } from "../domain/spectator";
import { createDemoSnapshot } from "./demoFixtures";
import { useSpectatorSnapshot } from "./spectatorAdapter";

const transport=vi.hoisted(()=>({
  connected:true,
  connection: (state:{isWebSocketConnected:boolean})=>{void state;},
  next: (snapshot:SpectatorSnapshot|null)=>{void snapshot;},
  error: (): void=>undefined,
  stopConnection:vi.fn(),stopQuery:vi.fn(),close:vi.fn(),
}));
vi.mock("convex/browser",()=>({ConvexClient:class {
  connectionState(){return {isWebSocketConnected:transport.connected};}
  subscribeToConnectionState(callback:typeof transport.connection){transport.connection=callback;return transport.stopConnection;}
  onUpdate(_query:unknown,_request:unknown,next:typeof transport.next,error:()=>void){transport.next=next;transport.error=error;return transport.stopQuery;}
  close(){transport.close();return Promise.resolve();}
}}));
import { createConvexSpectatorAdapter } from "./convexSpectatorAdapter";

afterEach(()=>{vi.clearAllMocks();transport.connected=true;vi.useRealTimers();});
describe("Convex socket lifecycle",()=>{
  it("retains four-player data on socket loss and restores unchanged data without a fresh timestamp",()=>{
    vi.useFakeTimers();
    const adapter=createConvexSpectatorAdapter("https://example.convex.cloud");
    const snapshot=createDemoSnapshot("ARENA4","arena");
    const {result,unmount}=renderHook(()=>useSpectatorSnapshot(adapter,"ARENA4",0));
    act(()=>transport.next(snapshot));
    act(()=>transport.connection({isWebSocketConnected:false}));
    expect(result.current).toMatchObject({kind:"degraded",snapshot,lastSyncedAt:snapshot.serverNow});
    act(()=>transport.connection({isWebSocketConnected:true}));
    expect(result.current).toMatchObject({kind:"recovery",snapshot});
    act(()=>{vi.advanceTimersByTime(1800);});
    expect(result.current).toMatchObject({kind:"ready",snapshot});
    unmount();adapter.dispose();
    expect(transport.stopConnection).toHaveBeenCalledOnce();
    expect(transport.stopQuery).toHaveBeenCalledOnce();
  });
  it("does not treat a cached query while offline as restored",()=>{
    transport.connected=false;
    const adapter=createConvexSpectatorAdapter("https://example.convex.cloud");
    const snapshot=createDemoSnapshot("ARENA4","arena-paused");
    const {result,unmount}=renderHook(()=>useSpectatorSnapshot(adapter,"ARENA4",0));
    act(()=>transport.next(snapshot));
    expect(result.current).toMatchObject({kind:"degraded",snapshot});
    unmount();adapter.dispose();
  });
  it("keeps a query failure degraded across socket recovery until a query succeeds",()=>{
    const adapter=createConvexSpectatorAdapter("https://example.convex.cloud");
    const snapshot=createDemoSnapshot("ARENA4","arena");
    const {result,unmount}=renderHook(()=>useSpectatorSnapshot(adapter,"ARENA4",0));
    act(()=>transport.next(snapshot));act(()=>transport.error());
    act(()=>transport.connection({isWebSocketConnected:false}));
    act(()=>transport.connection({isWebSocketConnected:true}));
    expect(result.current.kind).toBe("degraded");
    act(()=>transport.next(snapshot));
    expect(result.current.kind).toBe("recovery");
    unmount();adapter.dispose();
  });
  it("stops every listener on disposal and ignores delayed callbacks",()=>{
    const adapter=createConvexSpectatorAdapter("https://example.convex.cloud");
    const observer={next:vi.fn(),error:vi.fn()};
    adapter.subscribe({code:"ARENA4"},observer);
    adapter.dispose();adapter.dispose();
    transport.next(createDemoSnapshot("ARENA4","arena"));
    transport.connection({isWebSocketConnected:false});transport.error();
    expect(observer.next).not.toHaveBeenCalled();expect(observer.error).not.toHaveBeenCalled();
    expect(transport.stopConnection).toHaveBeenCalledOnce();expect(transport.stopQuery).toHaveBeenCalledOnce();
    expect(transport.close).toHaveBeenCalledOnce();
  });
});
