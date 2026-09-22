import { abortAllDurableObjects } from "cloudflare:test";
import { afterEach, describe, expect, it } from "vitest";
import { LIMITS, type Member } from "@vkz/combat-protocol";
import { claims, connect, manuallyScheduledRoom, type SocketInbox } from "./helpers.js";

afterEach(async () => { await abortAllDurableObjects(); });

const trio: Member[] = [
  { playerId: "host", displayName: "Host", role: "host" },
  { playerId: "guest", displayName: "Guest", role: "player" },
  { playerId: "third", displayName: "Third", role: "player" },
];

const collab = (data: string) => JSON.stringify({ type: "collab", data });

/** Ordered receive barrier: a pong crosses every collab relayed before the ping. */
async function receivedAll(socket: SocketInbox): Promise<void> {
  const nonce = crypto.randomUUID();
  socket.socket.send(JSON.stringify({ type: "ping", nonce, clientSentAtMs: performance.now() }));
  await socket.next("pong", message => message.nonce === nonce);
}

describe("opaque collaboration relay", () => {
  it("relays archives verbatim to every other member without echoing the sender", async () => {
    const ticket = claims({ roster: trio });
    await manuallyScheduledRoom(ticket.matchId);
    const host = await connect(ticket);
    const guest = await connect({ ...ticket, playerId: "guest" });
    const third = await connect({ ...ticket, playerId: "third" });
    try {
      await Promise.all([receivedAll(host), receivedAll(guest), receivedAll(third)]);
      host.messages.length = 0;
      const data = btoa("arkit-collaboration-archive");
      host.socket.send(collab(data));
      const [toGuest, toThird] = await Promise.all([guest.next("collab"), third.next("collab")]);
      expect(toGuest).toEqual({ type: "collab", playerId: "host", data });
      expect(toThird).toEqual({ type: "collab", playerId: "host", data });
      await receivedAll(host);
      expect(host.messages.some(message => message.type === "collab")).toBe(false);
    } finally { host.close(); guest.close(); third.close(); }
  });

  it("relays while the match is still calibrating", async () => {
    const ticket = claims();
    await manuallyScheduledRoom(ticket.matchId);
    const host = await connect(ticket);
    const guest = await connect({ ...ticket, playerId: "guest" });
    try {
      const baseline = await host.next("snapshot");
      expect(baseline.snapshot.phase).toBe("calibrating");
      const data = btoa("pre-start-archive");
      guest.socket.send(collab(data));
      expect(await host.next("collab")).toEqual({ type: "collab", playerId: "guest", data });
    } finally { host.close(); guest.close(); }
  });

  it.each([
    ["non-base64", { type: "collab", data: "a=b=" }],
    ["over collabBytes", { type: "collab", data: "A".repeat(LIMITS.collabBytes + 4) }],
    ["extra keys", { type: "collab", data: "AAAA", extra: true }],
  ])("rejects %s collab like any invalid message", async (_label, message) => {
    const ticket = claims();
    await manuallyScheduledRoom(ticket.matchId);
    const host = await connect(ticket);
    try {
      host.socket.send(JSON.stringify(message));
      expect(await host.next("error")).toMatchObject({ code: "invalidMessage" });
      expect(await host.closed).toBe(1008);
    } finally { host.close(); }
  });

  it("still applies the 16 KiB bound to non-collab messages under the raised ceiling", async () => {
    const ticket = claims();
    await manuallyScheduledRoom(ticket.matchId);
    const host = await connect(ticket);
    try {
      host.socket.send(JSON.stringify({ type: "ping", nonce: "n", clientSentAtMs: 0, pad: "x".repeat(LIMITS.messageBytes) }));
      expect(await host.next("error")).toMatchObject({ code: "invalidMessage" });
      expect(await host.closed).toBe(1008);
    } finally { host.close(); }
  });

  it("silently drops collab for a receiver whose relay budget is exhausted", async () => {
    const ticket = claims({ roster: trio });
    await manuallyScheduledRoom(ticket.matchId);
    const host = await connect(ticket);
    const guest = await connect({ ...ticket, playerId: "guest" });
    let third: SocketInbox | undefined;
    try {
      await Promise.all([receivedAll(host), receivedAll(guest)]);
      guest.messages.length = 0;
      // ~384 KiB encoded leaves a fresh 512 KiB budget unable to admit a repeat.
      const bulk = "A".repeat(LIMITS.collabBytes);
      host.socket.send(collab(bulk));
      expect(await guest.next("collab")).toMatchObject({ playerId: "host" });
      third = await connect({ ...ticket, playerId: "third" });
      await receivedAll(third);
      third.messages.length = 0;
      third.socket.send(collab(bulk));
      expect(await host.next("collab")).toMatchObject({ playerId: "third", data: bulk });
      await receivedAll(guest);
      expect(guest.messages.some(message => message.type === "collab")).toBe(false);
    } finally { host.close(); guest.close(); third?.close(); }
  });

  it("silently drops collab from a sender whose ingest budget is exhausted", async () => {
    const ticket = claims({ roster: trio });
    await manuallyScheduledRoom(ticket.matchId);
    const host = await connect(ticket);
    const guest = await connect({ ...ticket, playerId: "guest" });
    let third: SocketInbox | undefined;
    try {
      await Promise.all([receivedAll(host), receivedAll(guest)]);
      guest.messages.length = 0;
      const bulk = "A".repeat(LIMITS.collabBytes);
      host.socket.send(collab(bulk));
      host.socket.send(collab(bulk));
      host.socket.send(collab(bulk));
      await receivedAll(guest);
      expect(guest.messages.filter(message => message.type === "collab")).toHaveLength(1);

      third = await connect({ ...ticket, playerId: "third" });
      await receivedAll(third);
      third.messages.length = 0;
      host.socket.send(collab(bulk));
      await receivedAll(third);
      expect(third.messages.some(message => message.type === "collab")).toBe(false);
      await receivedAll(host);
      expect(host.socket.readyState).toBe(WebSocket.OPEN);
    } finally { host.close(); guest.close(); third?.close(); }
  });
});
