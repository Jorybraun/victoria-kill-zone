import { validateCombatProjection, type CombatProjection, type CombatSnapshot, type ServerEvent } from "@vkz/combat-protocol";

export type OutboxRow = { from_sequence: number; through_sequence: number; payload: string };
const TERMINALS_PER_PROJECTION = 64;

/** A sealed retry is immutable; only the last unsent row can coalesce. */
export class ProjectionStore {
  constructor(private readonly storage: DurableObjectStorage) {}

  initialize(): void {
    this.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS projection_outbox (
        from_sequence INTEGER PRIMARY KEY, through_sequence INTEGER NOT NULL, payload TEXT NOT NULL, sealed INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS projection_progress (
        singleton INTEGER PRIMARY KEY CHECK(singleton = 1), queued_sequence INTEGER NOT NULL, delivered_sequence INTEGER NOT NULL
      );
      INSERT OR IGNORE INTO projection_progress VALUES (1, 0, 0);
    `);
  }

  append(snapshot: CombatSnapshot, events: readonly ServerEvent[]): void {
    if (events.length === 0) return;
    const open = this.storage.sql.exec<OutboxRow>("SELECT from_sequence, through_sequence, payload FROM projection_outbox WHERE sealed = 0 ORDER BY from_sequence DESC LIMIT 1").toArray()[0];
    const progress = this.storage.sql.exec<{ queued_sequence: number }>("SELECT queued_sequence FROM projection_progress WHERE singleton = 1").one().queued_sequence;
    if (events[0]?.eventSequence !== progress + 1) throw new Error("Projection sequence gap");
    let from = progress + 1;
    let terminals: CombatProjection["terminals"] = [];
    if (open !== undefined) {
      const raw: unknown = JSON.parse(open.payload);
      const saved = validateCombatProjection(raw);
      if (saved === null) throw new Error("Invalid durable projection");
      if (saved.authorityEpoch === snapshot.authorityEpoch && saved.frameEpoch === snapshot.frameEpoch) {
        from = open.from_sequence;
        terminals = saved.terminals;
      } else this.put(saved, true);
    }
    let projection = this.make(snapshot, from, progress, terminals);
    for (const wrapped of events) {
      if (wrapped.event.kind === "projectileTerminal") {
        if (projection.terminals.length === TERMINALS_PER_PROJECTION) {
          this.put(projection, true);
          projection = this.make(snapshot, wrapped.eventSequence, wrapped.eventSequence - 1, []);
        }
        projection.terminals = [...projection.terminals, { eventSequence: wrapped.eventSequence, event: wrapped.event }];
      }
      projection.throughEventSequence = wrapped.eventSequence;
    }
    this.put(projection, false);
    this.storage.sql.exec("UPDATE projection_progress SET queued_sequence = ? WHERE singleton = 1", projection.throughEventSequence);
  }

  hasPending(): boolean {
    return this.storage.sql.exec<{ from_sequence: number }>("SELECT from_sequence FROM projection_outbox ORDER BY from_sequence LIMIT 1").toArray().length !== 0;
  }

  take(): OutboxRow | null {
    return this.storage.transactionSync(() => {
      const row = this.storage.sql.exec<OutboxRow>("SELECT from_sequence, through_sequence, payload FROM projection_outbox ORDER BY from_sequence LIMIT 1").toArray()[0];
      if (row === undefined) return null;
      this.storage.sql.exec("UPDATE projection_outbox SET sealed = 1 WHERE from_sequence = ?", row.from_sequence);
      return row;
    });
  }

  acknowledge(row: OutboxRow): void {
    this.storage.transactionSync(() => {
      const current = this.storage.sql.exec<OutboxRow>("SELECT from_sequence, through_sequence, payload FROM projection_outbox ORDER BY from_sequence LIMIT 1").toArray()[0];
      if (current?.from_sequence !== row.from_sequence || current.through_sequence !== row.through_sequence || current.payload !== row.payload) throw new Error("Projection acknowledgment mismatch");
      this.storage.sql.exec("DELETE FROM projection_outbox WHERE from_sequence = ?", row.from_sequence);
      this.storage.sql.exec("UPDATE projection_progress SET delivered_sequence = ? WHERE singleton = 1", row.through_sequence);
    });
  }

  private put(projection: CombatProjection, sealed: boolean): void {
    if (!validateCombatProjection(projection)) throw new Error("Invalid outgoing projection");
    this.storage.sql.exec("INSERT INTO projection_outbox(from_sequence, through_sequence, payload, sealed) VALUES (?, ?, ?, ?) ON CONFLICT(from_sequence) DO UPDATE SET through_sequence = excluded.through_sequence, payload = excluded.payload, sealed = excluded.sealed", projection.fromEventSequence, projection.throughEventSequence, JSON.stringify(projection), sealed ? 1 : 0);
  }

  private make(snapshot: CombatSnapshot, from: number, through: number, terminals: CombatProjection["terminals"]): CombatProjection {
    return { v: 1, matchId: snapshot.matchId, authorityEpoch: snapshot.authorityEpoch, frameEpoch: snapshot.frameEpoch,
      fromEventSequence: from, throughEventSequence: through, matchTimeMs: snapshot.matchTimeMs,
      roundStartedAtMs: snapshot.roundStartedAtMs, phase: snapshot.phase, players: snapshot.players, terminals };
  }
}
