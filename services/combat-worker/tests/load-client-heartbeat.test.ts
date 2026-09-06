import {afterEach, beforeEach, describe, expect, it, vi} from "vitest";
import type {ClientMessage, ServerMessage} from "@vkz/combat-protocol";
import {LoadClient, type LoadSocket} from "../benchmarks/load-client.js";

type Ping = Extract<ClientMessage, {type: "ping"}>;
type Pong = Extract<ServerMessage, {type: "pong"}>;
class FakeSocket implements LoadSocket {
  readyState = 1;
  closeCalls = 0;
  failSend = false;
  readonly pings: {at: number; message: Ping}[] = [];
  private readonly messages: ((event: {data: unknown}) => void)[] = [];
  private readonly errors: (() => void)[] = [];
  private readonly closes: ((event: {code: number}) => void)[] = [];
  accept(): void { /* Already open; server replies are controlled by each test. */ }
  addEventListener(type: "message", listener: (event: {data: unknown}) => void): void;
  addEventListener(type: "error", listener: () => void): void;
  addEventListener(type: "close", listener: (event: {code: number}) => void): void;
  addEventListener(type: string, listener: unknown): void {
    if (type === "message") this.messages.push(listener as (event: {data: unknown}) => void);
    if (type === "error") this.errors.push(listener as () => void);
    if (type === "close") this.closes.push(listener as (event: {code: number}) => void);
  }
  send(data: string): void {
    if (this.failSend) throw new Error("Synthetic send failed");
    const message = JSON.parse(data) as ClientMessage;
    if (message.type === "ping") this.pings.push({at: performance.now(), message});
  }
  close(code = 1000): void {
    if (this.readyState === 3) return;
    this.readyState = 3; this.closeCalls++;
    for (const listener of this.closes) listener({code});
  }
  error(): void {for (const listener of this.errors) listener();}
  reply(index: number, override: Partial<Pong> = {}): void {
    const ping = this.pings[index]!.message;
    const message: Pong = {type: "pong", nonce: ping.nonce, clientSentAtMs: ping.clientSentAtMs,
      serverReceivedAtMs: ping.clientSentAtMs, serverSentAtMs: ping.clientSentAtMs, ...override};
    for (const listener of this.messages) listener({data: JSON.stringify(message)});
  }
}

const clients: LoadClient[] = [];
function create(mode: "native" | "receiveAnchor" = "native") {
  const socket = new FakeSocket(), client = new LoadClient(socket, `client-${clients.length}`, mode);
  clients.push(client);
  return {socket, client};
}
async function ready(onFailure = vi.fn<(error: Error) => void>()) {
  const fixture = create(), startup = fixture.client.bootstrapClock(onFailure);
  await vi.advanceTimersByTimeAsync(400);
  for (let i = 0; i < 5; i++) fixture.socket.reply(i);
  await startup;
  expect(fixture.client.clockReady).toBe(true);
  return {...fixture, onFailure};
}

beforeEach(() => {vi.useFakeTimers({toFake: ["setTimeout", "clearTimeout", "performance"]});});
afterEach(() => {
  for (const client of clients.splice(0)) client.close();
  expect(vi.getTimerCount()).toBe(0);
  vi.useRealTimers();
});

describe("native load heartbeat lifecycle", () => {
  it("sends five pings 100 ms apart without awaiting replies, then waits one second", async () => {
    const {socket, client} = create();
    const startup = client.bootstrapClock();
    expect(client.bootstrapClock()).toBe(startup);
    await vi.advanceTimersByTimeAsync(400);
    expect(socket.pings.map(ping => ping.at)).toEqual([0, 100, 200, 300, 400]);
    expect(client.clockReady).toBe(false);
    for (let i = 0; i < 5; i++) socket.reply(i);
    await startup;
    await vi.advanceTimersByTimeAsync(999);
    expect(socket.pings).toHaveLength(5);
    await vi.advanceTimersByTimeAsync(1);
    expect(socket.pings.map(ping => ping.at)).toEqual([0, 100, 200, 300, 400, 1400]);
  });

  it("keeps separately started clients independent while one client's replies are delayed", async () => {
    const first = create(), firstStartup = first.client.bootstrapClock();
    await vi.advanceTimersByTimeAsync(150);
    const second = create(), secondStartup = second.client.bootstrapClock();
    await vi.advanceTimersByTimeAsync(400);
    for (let i = 0; i < 5; i++) second.socket.reply(i);
    await secondStartup;
    expect(first.client.clockReady).toBe(false);
    expect(second.socket.pings.map(ping => ping.at)).toEqual([150, 250, 350, 450, 550]);
    await vi.advanceTimersByTimeAsync(1000);
    expect(first.socket.pings.map(ping => ping.at)).toEqual([0, 100, 200, 300, 400, 1400]);
    expect(second.socket.pings.map(ping => ping.at)).toEqual([150, 250, 350, 450, 550, 1550]);
    first.client.close();
    await expect(firstStartup).rejects.toThrow("Load client closed");
  });

  it("cancels pending bootstrap replies and the heartbeat on close, ignoring late replies", async () => {
    const {socket, client} = create(), onFailure = vi.fn<(error: Error) => void>();
    const startup = client.bootstrapClock(onFailure);
    await vi.advanceTimersByTimeAsync(400);
    expect(vi.getTimerCount()).toBe(6); // Five pending replies and the next heartbeat.
    client.close(); client.close();
    await expect(startup).rejects.toThrow("Load client closed");
    expect(vi.getTimerCount()).toBe(0);
    for (let i = 0; i < 5; i++) socket.reply(i);
    await vi.advanceTimersByTimeAsync(10_000);
    expect(socket.pings).toHaveLength(5);
    expect(socket.closeCalls).toBe(1);
    expect(client.clockReady).toBe(false);
    expect(onFailure).not.toHaveBeenCalled();
    await expect(client.bootstrapClock(onFailure)).rejects.toThrow("Load client closed");
  });

  it("closes and reports quality loss once after bootstrap, clearing every owned timer", async () => {
    const {socket, client, onFailure} = await ready();
    await vi.advanceTimersByTimeAsync(1000);
    socket.reply(5, {serverReceivedAtMs: 10_000, serverSentAtMs: 10_000});
    await vi.advanceTimersByTimeAsync(0);
    expect(client.errors).toContain("clockQualityLost");
    expect(onFailure).toHaveBeenCalledExactlyOnceWith(expect.objectContaining({message: "Clock quality lost"}));
    expect(socket.closeCalls).toBe(1);
    expect(vi.getTimerCount()).toBe(0);
    socket.reply(5);
    await vi.advanceTimersByTimeAsync(10_000);
    expect(socket.pings).toHaveLength(6);
    expect(onFailure).toHaveBeenCalledTimes(1);
  });

  it("requires a matching nonce and echoed send time before accepting a heartbeat reply", async () => {
    const {socket, client, onFailure} = await ready();
    await vi.advanceTimersByTimeAsync(1000);
    socket.reply(5, {nonce: "not-a-pending-request"});
    expect(client.clockReady).toBe(true);
    expect(onFailure).not.toHaveBeenCalled();
    socket.reply(5, {clientSentAtMs: 1399});
    await vi.advanceTimersByTimeAsync(0);
    expect(onFailure).toHaveBeenCalledExactlyOnceWith(expect.objectContaining({message: "Clock reply did not match its request"}));
    expect(socket.closeCalls).toBe(1);
    expect(vi.getTimerCount()).toBe(0);
  });

  it("continues sending while replies are missing and reports the bounded failure once", async () => {
    const {socket, onFailure} = await ready();
    await vi.advanceTimersByTimeAsync(3999);
    expect(socket.pings.map(ping => ping.at)).toEqual([0, 100, 200, 300, 400, 1400, 2400, 3400]);
    expect(onFailure).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1);
    expect(onFailure).toHaveBeenCalledExactlyOnceWith(expect.objectContaining({message: "Clock sync timed out"}));
    expect(socket.closeCalls).toBe(1);
    expect(vi.getTimerCount()).toBe(0);
  });

  it("cleans up immediately after an unexpected socket close", async () => {
    const {socket, client, onFailure} = await ready();
    await vi.advanceTimersByTimeAsync(1000);
    socket.close(1011);
    await vi.advanceTimersByTimeAsync(0);
    expect(client.errors).toContain("socketClosed:1011");
    expect(onFailure).toHaveBeenCalledExactlyOnceWith(expect.objectContaining({message: "Load socket closed: 1011"}));
    expect(vi.getTimerCount()).toBe(0);
  });

  it("rejects startup send failures without leaving a heartbeat or ping deadline", async () => {
    const {socket, client} = create(), onFailure = vi.fn<(error: Error) => void>();
    socket.failSend = true;
    await expect(client.bootstrapClock(onFailure)).rejects.toThrow("Synthetic send failed");
    expect(socket.closeCalls).toBe(1);
    expect(onFailure).not.toHaveBeenCalled();
    expect(vi.getTimerCount()).toBe(0);
  });

  it("leaves receiveAnchor synchronization explicitly driven and cancels its pending deadline on close", async () => {
    const {socket, client} = create("receiveAnchor"), onFailure = vi.fn<(error: Error) => void>();
    const startup = client.bootstrapClock(onFailure);
    socket.reply(0, {serverReceivedAtMs: 50, serverSentAtMs: 50});
    await startup;
    await vi.advanceTimersByTimeAsync(5000);
    expect(socket.pings).toHaveLength(1);
    expect(client.matchTimeMs).toBe(5050);
    expect(client.clockUncertaintyMs).toBe(1);
    expect(vi.getTimerCount()).toBe(0);
    const explicit = client.synchronizeClock();
    expect(socket.pings).toHaveLength(2);
    client.close();
    await expect(explicit).rejects.toThrow("Load client closed");
    expect(onFailure).not.toHaveBeenCalled();
  });
});
