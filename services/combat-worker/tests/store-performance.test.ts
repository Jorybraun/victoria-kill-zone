import { env } from "cloudflare:workers";
import { abortAllDurableObjects, runInDurableObject } from "cloudflare:test";
import { afterEach, describe, expect, it } from "vitest";
import { DEFAULT_RULES, LIMITS, type CombatProjection, type ServerEvent } from "@vkz/combat-protocol";
import { CombatSimulation } from "@vkz/combat-simulation";
import { RoomStore } from "../src/store.js";
import { ProjectionStore } from "../src/projection-store.js";

afterEach(async () => { await abortAllDurableObjects(); });

/** Observe the real, synchronously consumed workerd SQL cursors. The facade
 * changes neither SQL nor results and does not substitute a database fake. */
function meter(storage: DurableObjectStorage) {
  const reads: { query: string; cursor: { readonly rowsRead: number } }[] = [];
  const sql = new Proxy(storage.sql, {
    get(target, property) {
      if (property === "exec") return (query: string, ...bindings: SqlStorageValue[]) => {
        const cursor = target.exec(query, ...bindings);
        reads.push({ query, cursor });
        return cursor;
      };
      return Reflect.get(target, property, target) as unknown;
    },
  });
  return {
    storage: new Proxy(storage, {
      get(target, property) {
        if (property === "sql") return sql;
        return Reflect.get(target, property, target) as unknown;
      },
    }),
    reads,
    reset: () => { reads.length = 0; },
    rowsRead: () => reads.reduce((total, { cursor }) => total + cursor.rowsRead, 0),
  };
}

function fillCommandHistory(storage: DurableObjectStorage): void {
  const store = new RoomStore(storage);
  store.initialize();
  storage.transactionSync(() => {
    for (const playerId of ["host", "guest"]) {
      for (let sequence = 1; sequence <= LIMITS.commandHistory; sequence += 1) {
        storage.sql.exec("INSERT INTO commands VALUES (?, ?, ?, ?, ?, ?)",
          playerId, sequence, `command-${sequence}`, `fingerprint-${playerId}-${sequence}`, sequence,
          JSON.stringify({ playerId, clientSequence: sequence }));
      }
    }
  });
}

describe("bounded SQLite room lookups", () => {
  it("keeps new commands and old replays to indexed reads at full retained history", async () => {
    const measurements = await runInDurableObject(env.COMBAT_ROOMS.getByName(crypto.randomUUID()), (_instance, state) => {
      fillCommandHistory(state.storage);
      // Retain the old query as a measured negative control, so the bound is
      // proven to detect the full-history scan on the actual workerd engine.
      const legacy = state.storage.sql.exec(
        "SELECT client_sequence, command_id, fingerprint, event_sequence, result_json FROM commands WHERE player_id = ? AND (command_id = ? OR client_sequence = ?) ORDER BY client_sequence DESC LIMIT 1",
        "host", "new-command", LIMITS.commandHistory + 1,
      );
      expect(legacy.toArray()).toEqual([]);
      expect(legacy.rowsRead).toBeGreaterThanOrEqual(LIMITS.commandHistory);
      const measured = meter(state.storage), store = new RoomStore(measured.storage);
      expect(store.findCommand("host", "new-command", LIMITS.commandHistory + 1)).toBeNull();
      const indexedMissRowsRead = measured.rowsRead();
      expect(measured.rowsRead()).toBeLessThanOrEqual(2);

      measured.reset();
      expect(store.findCommand("host", "command-1", 1)).toMatchObject({
        client_sequence: 1, command_id: "command-1", fingerprint: "fingerprint-host-1",
      });
      const indexedReplayRowsRead = measured.rowsRead();
      expect(measured.rowsRead()).toBeLessThanOrEqual(2);

      measured.reset();
      expect(store.findCommand("outsider", "command-1", 1)).toBeNull();
      expect(measured.rowsRead()).toBeLessThanOrEqual(2);
      return { measurement: "command_lookup_rows", retainedPerPlayer: LIMITS.commandHistory,
        legacyMissRowsRead: legacy.rowsRead, indexedMissRowsRead, indexedReplayRowsRead };
    });
    console.info(JSON.stringify(measurements));
  });

  it("preserves highest-sequence selection when the two unique keys conflict", async () => {
    await runInDurableObject(env.COMBAT_ROOMS.getByName(crypto.randomUUID()), (_instance, state) => {
      fillCommandHistory(state.storage);
      const measured = meter(state.storage), store = new RoomStore(measured.storage);
      // The result is deliberately the higher conflicting row, exactly as the
      // prior ORDER BY client_sequence DESC LIMIT 1 contract required.
      for (const [commandId, sequence, expected] of [
        ["command-1", LIMITS.commandHistory, LIMITS.commandHistory],
        [`command-${LIMITS.commandHistory}`, 1, LIMITS.commandHistory],
        ["command-1", LIMITS.commandHistory + 1, 1],
        ["new-command", 1, 1],
      ] as const) {
        measured.reset();
        expect(store.findCommand("host", commandId, sequence)).toMatchObject({
          client_sequence: expected, command_id: `command-${expected}`, fingerprint: `fingerprint-host-${expected}`,
        });
        expect(measured.rowsRead()).toBeLessThanOrEqual(2);
      }
    });
  });

  it("finds an open projection without scanning a sealed retry backlog", async () => {
    const measurements = await runInDurableObject(env.COMBAT_ROOMS.getByName(crypto.randomUUID()), (_instance, state) => {
      const store = new ProjectionStore(state.storage);
      store.initialize();
      store.initialize(); // Existing objects can rerun idempotent schema setup.
      const simulation = CombatSimulation.create({ matchId: "indexed-projection-fixture", authorityEpoch: 1, frameEpoch: 1,
        rules: DEFAULT_RULES, players: [{ playerId: "host", displayName: "Host", role: "host" },
          { playerId: "guest", displayName: "Guest", role: "player" }] });
      const snapshot = simulation.snapshot(), backlog = 2048;
      const projection: CombatProjection = { v: 1, matchId: snapshot.matchId, authorityEpoch: 1, frameEpoch: 1,
        fromEventSequence: 1, throughEventSequence: 1, matchTimeMs: 0, roundStartedAtMs: null,
        phase: snapshot.phase, players: snapshot.players, terminals: [] };
      state.storage.transactionSync(() => {
        for (let sequence = 1; sequence <= backlog; sequence += 1) {
          const payload = JSON.stringify({ ...projection, fromEventSequence: sequence, throughEventSequence: sequence });
          state.storage.sql.exec("INSERT INTO projection_outbox VALUES (?, ?, ?, 1)", sequence, sequence, payload);
        }
        state.storage.sql.exec("UPDATE projection_progress SET queued_sequence = ? WHERE singleton = 1", backlog);
      });
      const scan = state.storage.sql.exec("SELECT from_sequence, through_sequence, payload FROM projection_outbox NOT INDEXED WHERE sealed = 0 ORDER BY from_sequence DESC LIMIT 1");
      expect(scan.toArray()).toEqual([]);
      expect(scan.rowsRead).toBe(backlog);
      const measured = meter(state.storage), observed = new ProjectionStore(measured.storage);
      const event = (sequence: number): ServerEvent => ({ v: 1, matchId: snapshot.matchId, authorityEpoch: 1, frameEpoch: 1,
        eventSequence: sequence, tick: 0, matchTimeMs: 0, event: { kind: "phaseChanged", phase: snapshot.phase, reason: "lookup-fixture" } });
      observed.append(snapshot, [event(backlog + 1)]);
      const noOpen = measured.reads.find(({ query }) => query.includes("WHERE sealed = 0"));
      expect(noOpen).toBeDefined();
      expect(noOpen?.cursor.rowsRead).toBeLessThanOrEqual(1);
      if (noOpen === undefined) throw new Error("Open projection lookup was not measured");
      const plan = state.storage.sql.exec<{ detail: string }>(`EXPLAIN QUERY PLAN ${noOpen.query}`).toArray();
      expect(plan.some(({ detail }) => detail.includes("projection_outbox_open"))).toBe(true);

      measured.reset();
      observed.append(snapshot, [event(backlog + 2)]);
      const open = measured.reads.find(({ query }) => query.includes("WHERE sealed = 0"));
      expect(open).toBeDefined();
      expect(open?.cursor.rowsRead).toBeLessThanOrEqual(2);
      expect(state.storage.sql.exec<{ from_sequence: number; through_sequence: number }>(
        "SELECT from_sequence, through_sequence FROM projection_outbox WHERE sealed = 0").one())
        .toEqual({ from_sequence: backlog + 1, through_sequence: backlog + 2 });
      expect(state.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM projection_outbox WHERE sealed = 1").one().count).toBe(backlog);
      return { measurement: "projection_lookup_rows", sealedBacklog: backlog,
        unindexedMissRowsRead: scan.rowsRead, indexedMissRowsRead: noOpen.cursor.rowsRead, indexedOpenRowsRead: open?.cursor.rowsRead };
    });
    console.info(JSON.stringify(measurements));
  });
});
