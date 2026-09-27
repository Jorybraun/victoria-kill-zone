import { env } from "cloudflare:workers";
import { abortAllDurableObjects, runInDurableObject } from "cloudflare:test";
import { afterEach, describe, expect, it } from "vitest";
import { RoomStore } from "../src/store.js";

afterEach(async () => { await abortAllDurableObjects(); });

const tables = (storage: DurableObjectStorage): string[] =>
  storage.sql.exec<{ name: string }>("SELECT name FROM sqlite_master WHERE type = 'table'").toArray().map((row) => row.name);

const version = (storage: DurableObjectStorage): number | null =>
  storage.sql.exec<{ version: number | null }>("SELECT MAX(version) AS version FROM schema_migrations").one().version;

describe("room storage schema v2", () => {
  it("initializes fresh storage directly at version 2 without map tables", async () => {
    await runInDurableObject(env.COMBAT_ROOMS.getByName(crypto.randomUUID()), (_instance, state) => {
      new RoomStore(state.storage).initialize();
      expect(version(state.storage)).toBe(2);
      expect(tables(state.storage)).not.toContain("shared_maps");
      expect(tables(state.storage)).not.toContain("map_chunks");
    });
  });

  it("migrates version-1 storage by dropping map tables and keeping surviving rows", async () => {
    await runInDurableObject(env.COMBAT_ROOMS.getByName(crypto.randomUUID()), (_instance, state) => {
      state.storage.sql.exec(`
        DELETE FROM schema_migrations;
        INSERT INTO schema_migrations(version) VALUES (1);
        INSERT INTO events(sequence, payload) VALUES (7, '{"kept":true}');
        CREATE TABLE shared_maps (
          frame_epoch INTEGER PRIMARY KEY, frame_id TEXT NOT NULL, byte_length INTEGER NOT NULL, chunks INTEGER NOT NULL
        );
        INSERT INTO shared_maps VALUES (1, 'frame', 4, 1);
        CREATE TABLE map_chunks (
          frame_epoch INTEGER NOT NULL, chunk_index INTEGER NOT NULL, payload BLOB NOT NULL,
          PRIMARY KEY(frame_epoch, chunk_index)
        );
        INSERT INTO map_chunks VALUES (1, 0, X'0102');
      `);
      new RoomStore(state.storage).initialize();
      expect(version(state.storage)).toBe(2);
      expect(tables(state.storage)).not.toContain("shared_maps");
      expect(tables(state.storage)).not.toContain("map_chunks");
      expect(state.storage.sql.exec<{ payload: string }>("SELECT payload FROM events WHERE sequence = 7").one().payload).toBe('{"kept":true}');
    });
  });

  it("refuses storage written by an unknown newer schema version", async () => {
    await runInDurableObject(env.COMBAT_ROOMS.getByName(crypto.randomUUID()), (_instance, state) => {
      state.storage.sql.exec("DELETE FROM schema_migrations; INSERT INTO schema_migrations(version) VALUES (3)");
      expect(() => new RoomStore(state.storage).initialize()).toThrow("Unsupported room storage version");
    });
  });
});
