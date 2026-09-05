import { env } from "cloudflare:workers";
import { abortAllDurableObjects, runInDurableObject } from "cloudflare:test";
import { afterEach, describe, expect, it } from "vitest";
import { DEFAULT_RULES, validateCombatProjection, type CombatEvent, type CombatSnapshot, type ServerEvent } from "@vkz/combat-protocol";
import { CombatSimulation } from "@vkz/combat-simulation";
import { ProjectionStore } from "../src/projection-store.js";
import { ProjectionDelivery, projectionConfigured } from "../src/projection-delivery.js";
import { SerialQueue } from "../src/serial-queue.js";

afterEach(async () => { await abortAllDurableObjects(); });

function snapshot(epoch = 1): CombatSnapshot {
  const simulation = CombatSimulation.create({ matchId: "projection-fixture", authorityEpoch: epoch, frameEpoch: 1, rules: DEFAULT_RULES,
    players: [{ playerId: "host", displayName: "Host", role: "host" }, { playerId: "guest", displayName: "Guest", role: "player" }] });
  simulation.advance([]);
  return simulation.snapshot();
}

function wrapped(state: CombatSnapshot, sequence: number, event: CombatEvent = { kind: "phaseChanged", phase: state.phase, reason: "fixture" }): ServerEvent {
  return { v: 1, matchId: state.matchId, authorityEpoch: state.authorityEpoch, frameEpoch: state.frameEpoch, eventSequence: sequence,
    tick: state.tick, matchTimeMs: state.matchTimeMs, event };
}

function terminal(state: CombatSnapshot, sequence: number): ServerEvent {
  return wrapped(state, sequence, { kind: "projectileTerminal", projectileId: `p:${state.authorityEpoch}:${sequence}`, shotId: `s:${sequence}`, shooterId: "host",
    reason: "missExpired", atMs: state.matchTimeMs, position: [0, 0, -1], targetPlayerId: null, zone: null, damage: 0 });
}

function decode(payload: string) {
  const raw: unknown = JSON.parse(payload);
  const value = validateCombatProjection(raw);
  if (value === null) throw new Error("Invalid projection fixture");
  return value;
}

function signingKey(): string { return [...crypto.getRandomValues(new Uint8Array(32))].map((byte) => byte.toString(16).padStart(2, "0")).join(""); }
const storageFailure = (): never => { throw new Error("Unexpected test storage failure"); };

describe("durable ordered spectator projection", () => {
  it("coalesces unsent state while retaining every terminal and seals on authority changes", async () => {
    await runInDurableObject(env.COMBAT_ROOMS.getByName(crypto.randomUUID()), (_instance, state) => {
      const store = new ProjectionStore(state.storage); store.initialize();
      const first = snapshot();
      store.append(first, [terminal(first, 1)]);
      store.append(first, [wrapped(first, 2)]);
      const recovered = snapshot(2);
      store.append(recovered, [terminal(recovered, 3)]);
      const old = store.take();
      expect(old).not.toBeNull();
      if (old === null) throw new Error("Missing first projection");
      expect(decode(old.payload)).toMatchObject({ authorityEpoch: 1, fromEventSequence: 1, throughEventSequence: 2 });
      expect(decode(old.payload).terminals.map((item) => item.eventSequence)).toEqual([1]);
      store.acknowledge(old);
      const current = store.take();
      if (current === null) throw new Error("Missing recovered projection");
      expect(decode(current.payload)).toMatchObject({ authorityEpoch: 2, fromEventSequence: 3, throughEventSequence: 3 });
      expect(decode(current.payload).terminals.map((item) => item.eventSequence)).toEqual([3]);
    });
  });

  it("splits cancellation bursts at64 terminals without gaps or loss", async () => {
    await runInDurableObject(env.COMBAT_ROOMS.getByName(crypto.randomUUID()), (_instance, state) => {
      const store = new ProjectionStore(state.storage); store.initialize();
      const current = snapshot();
      store.append(current, Array.from({ length: 129 }, (_, index) => terminal(current, index + 1)));
      const counts = [], ranges = [];
      for (;;) {
        const row = store.take();
        if (row === null) break;
        const projection = decode(row.payload);
        counts.push(projection.terminals.length); ranges.push([projection.fromEventSequence, projection.throughEventSequence]);
        store.acknowledge(row);
      }
      expect(counts).toEqual([64, 64, 1]);
      expect(ranges).toEqual([[1, 64], [65, 128], [129, 129]]);
      expect(store.hasPending()).toBe(false);
    });
  });

  it("holds durable data when projection configuration is absent or insecure", async () => {
    await runInDurableObject(env.COMBAT_ROOMS.getByName(crypto.randomUUID()), async (_instance, state) => {
      const store = new ProjectionStore(state.storage); store.initialize(); const current = snapshot(); store.append(current, [terminal(current, 1)]);
      const config = { ...env, COMBAT_PROJECTION_SECRET: signingKey(), CONVEX_URL: "http://projection.test" };
      expect(projectionConfigured(config)).toBe(false);
      let requests = 0;
      const delivery = new ProjectionDelivery(config, state.storage, new SerialQueue(), store, storageFailure, () => { requests += 1; return Promise.resolve(new Response()); });
      await delivery.flush(Date.now());
      expect(requests).toBe(0); expect(store.hasPending()).toBe(true);
    });
  });

  it("signs exact immutable FIFO retries and deletes only a matching Convex receipt", async () => {
    await runInDurableObject(env.COMBAT_ROOMS.getByName(crypto.randomUUID()), async (_instance, state) => {
      const store = new ProjectionStore(state.storage); store.initialize(); const current = snapshot(); store.append(current, [terminal(current, 1)]);
      const config = { ...env, COMBAT_PROJECTION_SECRET: signingKey(), CONVEX_URL: "https://projection.test" };
      const sent: string[] = [];
      let refuse = true;
      const delivery = new ProjectionDelivery(config, state.storage, new SerialQueue(), store, storageFailure, async (request) => {
        expect(request.url).toBe("https://projection.test/api/mutation"); expect(request.method).toBe("POST");
        const raw: unknown = await request.json();
        if (raw === null || typeof raw !== "object" || !("args" in raw) || raw.args === null || typeof raw.args !== "object" || !("payload" in raw.args) || typeof raw.args.payload !== "string" || !("signature" in raw.args) || typeof raw.args.signature !== "string") throw new Error("Malformed projection request");
        expect(raw).toHaveProperty("path", "combat:publishProjection"); expect(raw).toHaveProperty("format", "json");
        sent.push(raw.args.payload);
        const signature = Uint8Array.from(raw.args.signature.match(/../g) ?? [], (byte) => Number.parseInt(byte, 16));
        const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(config.COMBAT_PROJECTION_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
        expect(await crypto.subtle.verify("HMAC", key, signature, new TextEncoder().encode(`vkz-projection-v1.${raw.args.payload}`))).toBe(true);
        return Response.json({ status: "success", value: { eventSequence: refuse ? 999 : decode(raw.args.payload).throughEventSequence, replayed: false } });
      });
      await delivery.flush(Date.now());
      expect(store.hasPending()).toBe(true);
      store.append(current, [wrapped(current, 2)]);
      refuse = false;
      await delivery.flush(Date.now() + 60_000);
      expect(sent).toHaveLength(3);
      expect(sent[0]).toBe(sent[1]);
      expect(decode(sent[2] ?? "")).toMatchObject({ fromEventSequence: 2, throughEventSequence: 2 });
      expect(store.hasPending()).toBe(false);
      expect(state.storage.sql.exec<{ delivered_sequence: number }>("SELECT delivered_sequence FROM projection_progress").one().delivered_sequence).toBe(2);
    });
  });
});
