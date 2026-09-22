import { abortAllDurableObjects } from "cloudflare:test";
import { afterEach, describe, expect, it } from "vitest";
import { type Member } from "@vkz/combat-protocol";
import { claims, connect, manuallyScheduledRoom, type SocketInbox } from "./helpers.js";

afterEach(async () => { await abortAllDurableObjects(); });

const trio: Member[] = [
  { playerId: "host", displayName: "Host", role: "host" },
  { playerId: "guest", displayName: "Guest", role: "player" },
  { playerId: "third", displayName: "Third", role: "player" },
];

const ni = (token: string) => JSON.stringify({ type: "niToken", token });

/** Ordered receive barrier: a pong crosses every message ordered before the ping. */
async function receivedAll(socket: SocketInbox): Promise<void> {
  const nonce = crypto.randomUUID();
  socket.socket.send(JSON.stringify({ type: "ping", nonce, clientSentAtMs: performance.now() }));
  await socket.next("pong", message => message.nonce === nonce);
}

describe("Nearby Interaction discovery-token relay", () => {
  it("delivers a published token to every other member without echoing the sender", async () => {
    const ticket = claims({ roster: trio });
    await manuallyScheduledRoom(ticket.matchId);
    const host = await connect(ticket);
    const guest = await connect({ ...ticket, playerId: "guest" });
    const third = await connect({ ...ticket, playerId: "third" });
    try {
      await Promise.all([receivedAll(host), receivedAll(guest), receivedAll(third)]);
      host.messages.length = 0;
      const token = btoa("host-discovery-token");
      host.socket.send(ni(token));
      const [toGuest, toThird] = await Promise.all([guest.next("niToken"), third.next("niToken")]);
      expect(toGuest).toEqual({ type: "niToken", playerId: "host", token });
      expect(toThird).toEqual({ type: "niToken", playerId: "host", token });
      await receivedAll(host);
      expect(host.messages.some(message => message.type === "niToken")).toBe(false);
    } finally { host.close(); guest.close(); third.close(); }
  });

  it("replays the latest stored token to a player admitted after publication", async () => {
    const ticket = claims({ roster: trio });
    await manuallyScheduledRoom(ticket.matchId);
    const host = await connect(ticket);
    const guest = await connect({ ...ticket, playerId: "guest" });
    let third: SocketInbox | undefined;
    try {
      const token = btoa("host-discovery-token");
      host.socket.send(ni(token));
      expect(await guest.next("niToken")).toEqual({ type: "niToken", playerId: "host", token });
      third = await connect({ ...ticket, playerId: "third" });
      const snapshot = await third.next("snapshot");
      expect(snapshot.type).toBe("snapshot");
      expect(await third.next("niToken")).toEqual({ type: "niToken", playerId: "host", token });
    } finally { host.close(); guest.close(); third?.close(); }
  });

  it("keeps only the newest token per player for late joiners", async () => {
    const ticket = claims({ roster: trio });
    await manuallyScheduledRoom(ticket.matchId);
    const host = await connect(ticket);
    const guest = await connect({ ...ticket, playerId: "guest" });
    let third: SocketInbox | undefined;
    try {
      const stale = btoa("stale-token");
      const fresh = btoa("fresh-token");
      host.socket.send(ni(stale));
      host.socket.send(ni(fresh));
      expect((await guest.next("niToken")).token).toBe(stale);
      expect((await guest.next("niToken")).token).toBe(fresh);
      third = await connect({ ...ticket, playerId: "third" });
      await third.next("snapshot");
      const replayed = await third.next("niToken");
      expect(replayed).toEqual({ type: "niToken", playerId: "host", token: fresh });
      await receivedAll(third);
      expect(third.messages.filter(message => message.type === "niToken")).toHaveLength(0);
    } finally { host.close(); guest.close(); third?.close(); }
  });

  it("rate-limits a sixth rapid publication and closes the socket", async () => {
    const ticket = claims();
    await manuallyScheduledRoom(ticket.matchId);
    const host = await connect(ticket);
    const guest = await connect({ ...ticket, playerId: "guest" });
    try {
      await receivedAll(host);
      for (let i = 0; i < 5; i++) host.socket.send(ni(btoa(`token-${i}`)));
      const error = await host.next("error");
      expect(error).toMatchObject({ code: "rateLimited" });
      expect(await host.closed).toBe(4008);
    } finally { host.close(); guest.close(); }
  });

  it("rejects an invalid token like any invalid message", async () => {
    const ticket = claims();
    await manuallyScheduledRoom(ticket.matchId);
    const host = await connect(ticket);
    try {
      host.socket.send(JSON.stringify({ type: "niToken", token: "a=b=" }));
      expect(await host.next("error")).toMatchObject({ code: "invalidMessage" });
      expect(await host.closed).toBe(1008);
    } finally { host.close(); }
  });
});
