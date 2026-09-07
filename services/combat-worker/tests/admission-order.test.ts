import { env } from "cloudflare:workers";
import { abortAllDurableObjects, runInDurableObject } from "cloudflare:test";
import { afterEach, describe, expect, it } from "vitest";
import type { CombatSimulation } from "@vkz/combat-simulation";
import type { SerialQueue } from "../src/serial-queue.js";
import { claims, connect, manuallyScheduledRoom, type SocketInbox } from "./helpers.js";

afterEach(async () => { await abortAllDurableObjects(); });

// A pong is an ordered receive barrier. Unlike next("snapshot"), this preserves
// every snapshot/event in its original wire order, as the native replica sees it.
async function receivedAll(socket: SocketInbox): Promise<void> {
  const nonce = crypto.randomUUID();
  socket.socket.send(JSON.stringify({ type: "ping", nonce, clientSentAtMs: performance.now() }));
  await socket.next("pong", message => message.nonce === nonce);
}

function expectBaselineFirst(socket: SocketInbox, playerId: string): void {
  const first = socket.messages[0];
  expect(first?.type).toBe("snapshot");
  if (first?.type !== "snapshot") throw new Error("Missing initial snapshot");
  expect(first.snapshot.players.find(player => player.playerId === playerId)?.connected).toBe(true);
  const admission = socket.messages.flatMap(message => message.type === "events" ? message.events : []);
  expect(admission.length).toBeGreaterThan(0);
  expect(admission.every(event => event.authorityEpoch === first.snapshot.authorityEpoch && event.eventSequence <= first.eventSequence)).toBe(true);
}

describe("native replica baseline ordering", () => {
  it("sends the first member a snapshot before admission events", async () => {
    const ticket = claims();
    await manuallyScheduledRoom(ticket.matchId);
    const host = await connect(ticket);
    try {
      await receivedAll(host);
      expectBaselineFirst(host, "host");
    } finally { host.close(); }
  });

  it("sends a joining member a snapshot and still publishes the join to existing peers", async () => {
    const ticket = claims();
    await manuallyScheduledRoom(ticket.matchId);
    const host = await connect(ticket);
    const guest = await connect({ ...ticket, playerId: "guest" });
    try {
      await Promise.all([receivedAll(host), receivedAll(guest)]);
      expectBaselineFirst(guest, "guest");
      const changes = host.messages.flatMap(message => message.type === "events" ? message.events : []);
      expect(changes.some(event => event.event.kind === "playerChanged" && event.event.player.playerId === "guest" && event.event.player.connected)).toBe(true);
    } finally { host.close(); guest.close(); }
  });

  it("sends a replacement socket a snapshot while peers receive both replacement transitions", async () => {
    const ticket = claims();
    await manuallyScheduledRoom(ticket.matchId);
    const original = await connect(ticket);
    const guest = await connect({ ...ticket, playerId: "guest" });
    await receivedAll(guest);
    guest.messages.length = 0;
    const replacement = await connect(ticket);
    try {
      expect(await original.closed).toBe(4001);
      await Promise.all([receivedAll(replacement), receivedAll(guest)]);
      expectBaselineFirst(replacement, "host");
      const changes = guest.messages.flatMap(message => message.type === "events" ? message.events : [])
        .flatMap(event => event.event.kind === "playerChanged" && event.event.player.playerId === "host" ? [event.event.player.connected] : []);
      expect(changes).toEqual([false, true]);
    } finally { original.close(); replacement.close(); guest.close(); }
  });

  it("sends every connected member the recovery snapshot before new-epoch events", async () => {
    const ticket = claims();
    await manuallyScheduledRoom(ticket.matchId);
    const sockets = [await connect(ticket), await connect({ ...ticket, playerId: "guest" })];
    try {
      await Promise.all(sockets.map(receivedAll));
      for (const socket of sockets) socket.messages.length = 0;
      const recovered = await runInDurableObject(env.COMBAT_ROOMS.getByName(ticket.matchId), async instance => {
        const room = instance as unknown as {
          queue: Pick<SerialQueue, "run">;
          cadence: { reset(now: number): void };
          simulation: Pick<CombatSimulation, "snapshot">;
          tick(): Promise<void>;
        };
        return room.queue.run(async () => {
          room.cadence.reset(performance.now() - 251);
          await room.tick();
          return room.simulation.snapshot();
        });
      });
      expect(recovered.authorityEpoch).toBe(2);
      await Promise.all(sockets.map(receivedAll));
      for (const socket of sockets) {
        expect(socket.messages[0]?.type).toBe("snapshot");
        expect(socket.messages.some(message => message.type === "error" && message.code === "epochMismatch")).toBe(true);
        const stateMessages = socket.messages.filter(message => message.type === "snapshot" || message.type === "events");
        expect(stateMessages[0]?.type).toBe("snapshot");
        const baseline = stateMessages[0];
        if (baseline?.type !== "snapshot") throw new Error("Missing recovery snapshot");
        expect(baseline.snapshot).toEqual(recovered);
        const events = stateMessages.flatMap(message => message.type === "events" ? message.events : []);
        expect(events.length).toBeGreaterThan(0);
        expect(events.every(event => event.authorityEpoch === recovered.authorityEpoch && event.eventSequence <= baseline.eventSequence)).toBe(true);
        // Cumulative receipts for the baseline and its covered events remain valid.
        expect(socket.socket.readyState).toBe(WebSocket.OPEN);
      }
    } finally { for (const socket of sockets) socket.close(); }
  });
});
