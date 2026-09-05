import { LIMITS, type AuthenticatedCommand, type CombatSnapshot, type ServerEvent } from "@vkz/combat-protocol";
import { BulletLedger } from "./bullet-ledger.js";
import { ProjectionStore } from "./projection-store.js";

type RoomRow = {
  match_id: string;
  authority_epoch: number;
  frame_epoch: number;
  bootstrap: string;
  checkpoint: string;
  event_sequence: number;
  last_activity_ms: number;
};

export type StoredCommand = {
  client_sequence: number;
  command_id: string;
  fingerprint: string;
  event_sequence: number;
  result_json: string;
};

export interface ProcessedCommand {
  command: AuthenticatedCommand;
  fingerprint: string;
  result: ServerEvent;
}

/** All dynamic SQL values are bound, and every history read/write is bounded. */
export class RoomStore {
  private readonly ledger: BulletLedger;
  readonly projections: ProjectionStore;
  constructor(private readonly storage: DurableObjectStorage) {
    this.ledger = new BulletLedger(storage.sql);
    this.projections = new ProjectionStore(storage);
  }

  initialize(): void {
    this.storage.transactionSync(() => {
      this.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY);
        INSERT OR IGNORE INTO schema_migrations(version) VALUES (1);
        CREATE TABLE IF NOT EXISTS room (
          singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
          match_id TEXT NOT NULL, authority_epoch INTEGER NOT NULL, frame_epoch INTEGER NOT NULL,
          bootstrap TEXT NOT NULL, checkpoint TEXT NOT NULL,
          event_sequence INTEGER NOT NULL, last_activity_ms INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS members (
          player_id TEXT PRIMARY KEY, client_sequence INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS commands (
          player_id TEXT NOT NULL, client_sequence INTEGER NOT NULL, command_id TEXT NOT NULL,
          fingerprint TEXT NOT NULL, event_sequence INTEGER NOT NULL, result_json TEXT NOT NULL,
          PRIMARY KEY(player_id, client_sequence), UNIQUE(player_id, command_id)
        );
        CREATE TABLE IF NOT EXISTS events (sequence INTEGER PRIMARY KEY, payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS shared_maps (
          frame_epoch INTEGER PRIMARY KEY, frame_id TEXT NOT NULL, byte_length INTEGER NOT NULL, chunks INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS map_chunks (
          frame_epoch INTEGER NOT NULL, chunk_index INTEGER NOT NULL, payload BLOB NOT NULL,
          PRIMARY KEY(frame_epoch, chunk_index)
        );
      `);
      const version = this.storage.sql.exec<{ version: number }>("SELECT MAX(version) AS version FROM schema_migrations").one();
      if (version.version !== 1) throw new Error("Unsupported room storage version");
      this.ledger.initialize();
      this.projections.initialize();
    });
  }

  load(): RoomRow | null {
    return this.storage.sql.exec<RoomRow>("SELECT * FROM room WHERE singleton = 1").toArray()[0] ?? null;
  }

  create(snapshot: CombatSnapshot, checkpoint: unknown, bootstrap: string, now: number): void {
    this.storage.transactionSync(() => {
      this.storage.sql.exec(
        "INSERT INTO room VALUES (1, ?, ?, ?, ?, ?, 0, ?)",
        snapshot.matchId, snapshot.authorityEpoch, snapshot.frameEpoch, bootstrap, JSON.stringify(checkpoint), now,
      );
      for (const player of snapshot.players) this.storage.sql.exec("INSERT INTO members(player_id) VALUES (?)", player.playerId);
    });
  }

  sequence(playerId: string): number {
    return this.storage.sql.exec<{ client_sequence: number }>(
      "SELECT client_sequence FROM members WHERE player_id = ?", playerId,
    ).toArray()[0]?.client_sequence ?? 0;
  }

  findCommand(playerId: string, commandId: string, sequence: number): StoredCommand | null {
    // Separate unique-key probes avoid scanning all retained commands for every
    // new pose. Preserve the prior highest-sequence result when the keys collide.
    const byId = this.storage.sql.exec<StoredCommand>(
      "SELECT client_sequence, command_id, fingerprint, event_sequence, result_json FROM commands WHERE player_id = ? AND command_id = ?",
      playerId, commandId,
    ).toArray()[0];
    const bySequence = this.storage.sql.exec<StoredCommand>(
      "SELECT client_sequence, command_id, fingerprint, event_sequence, result_json FROM commands WHERE player_id = ? AND client_sequence = ?",
      playerId, sequence,
    ).toArray()[0];
    if (byId === undefined) return bySequence ?? null;
    if (bySequence === undefined) return byId;
    return byId.client_sequence > bySequence.client_sequence ? byId : bySequence;
  }

  /** The output gate plus storage.sync at the caller precedes every broadcast. */
  commit(snapshot: CombatSnapshot, checkpoint: unknown, events: readonly ServerEvent[], commands: readonly ProcessedCommand[], eventSequence: number, now: number): void {
    this.storage.transactionSync(() => {
      this.storage.sql.exec(
        "UPDATE room SET authority_epoch = ?, frame_epoch = ?, checkpoint = ?, event_sequence = ?, last_activity_ms = ? WHERE singleton = 1",
        snapshot.authorityEpoch, snapshot.frameEpoch, JSON.stringify(checkpoint), eventSequence, now,
      );
      for (const event of events) {
        this.ledger.append(snapshot, event);
        this.storage.sql.exec("INSERT INTO events(sequence, payload) VALUES (?, ?)", event.eventSequence, JSON.stringify(event));
      }
      this.projections.append(snapshot, events);
      for (const item of commands) {
        const command = item.command;
        this.storage.sql.exec(
          "INSERT INTO commands VALUES (?, ?, ?, ?, ?, ?)",
          command.playerId, command.clientSequence, command.commandId, item.fingerprint, eventSequence, JSON.stringify(item.result),
        );
        this.storage.sql.exec("UPDATE members SET client_sequence = MAX(client_sequence, ?) WHERE player_id = ?", command.clientSequence, command.playerId);
        this.storage.sql.exec("DELETE FROM commands WHERE player_id = ? AND client_sequence <= ?", command.playerId, command.clientSequence - LIMITS.commandHistory);
      }
      this.storage.sql.exec("DELETE FROM events WHERE sequence <= ?", eventSequence - LIMITS.eventHistory);
    });
  }

  /** Already serialized trusted server events: never reinterpreted as commands. */
  eventPage(after: number, through: number, limit: number): { sequence: number; payload: string }[] {
    return this.storage.sql.exec<{ sequence: number; payload: string }>(
      "SELECT sequence, payload FROM events WHERE sequence > ? AND sequence <= ? ORDER BY sequence ASC LIMIT ?", after, through, limit,
    ).toArray();
  }

  earliestEvent(): number | null {
    return this.storage.sql.exec<{ sequence: number | null }>("SELECT MIN(sequence) AS sequence FROM events").one().sequence;
  }
}
