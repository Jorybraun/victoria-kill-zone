import { LIMITS, type CombatSnapshot, type ServerEvent } from "@vkz/combat-protocol";

type BulletRow = { projectile_id: string; terminal_sequence: number | null; segments: number };

/** Full-match evidence, independent from the short reconnect event ring. */
export class BulletLedger {
  constructor(private readonly sql: SqlStorage) {}

  initialize(): void {
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS bullet_totals (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), shots INTEGER NOT NULL);
      INSERT OR IGNORE INTO bullet_totals VALUES (1, 0);
      CREATE TABLE IF NOT EXISTS bullets (
        projectile_id TEXT PRIMARY KEY, shooter_id TEXT NOT NULL, shot_id TEXT NOT NULL,
        spawn_sequence INTEGER, terminal_sequence INTEGER, segments INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS bullet_events (
        sequence INTEGER PRIMARY KEY, projectile_id TEXT NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS bullet_events_by_projectile ON bullet_events(projectile_id, sequence);
    `);
  }

  /** Called only inside the caller's checkpoint/command-result transaction. */
  append(snapshot: CombatSnapshot, wrapped: ServerEvent): void {
    const event = wrapped.event;
    if (event.kind !== "projectileSpawn" && event.kind !== "projectileSegment" && event.kind !== "projectileTerminal") return;
    const projectileId = event.kind === "projectileSpawn" ? event.projectile.projectileId : event.projectileId;
    const row = this.sql.exec<BulletRow>("SELECT projectile_id, terminal_sequence, segments FROM bullets WHERE projectile_id = ?", projectileId).toArray()[0];
    if (row?.terminal_sequence !== undefined && row.terminal_sequence !== null) throw new Error("Bullet emitted after terminal result");
    if (event.kind === "projectileSpawn") {
      if (row !== undefined) throw new Error("Duplicate projectile spawn");
      this.create(snapshot, projectileId, event.projectile.shooterId, event.projectile.shotId, wrapped.eventSequence);
    } else if (event.kind === "projectileTerminal") {
      if (row === undefined) {
        if (snapshot.rules.weapon.kind !== "hitscan") throw new Error("Projectile terminal has no durable spawn");
        this.create(snapshot, projectileId, event.shooterId, event.shotId, null);
      }
      this.sql.exec("UPDATE bullets SET terminal_sequence = ? WHERE projectile_id = ?", wrapped.eventSequence, projectileId);
    } else {
      if (row === undefined) throw new Error("Projectile segment has no durable spawn");
      // A straight projectile crosses each of at most four fixed fields twice;
      // field expiration adds one transition each. Allow an extra transition at
      // either tick boundary, over the entire bounded projectile lifetime.
      const segmentLimit = (Math.ceil(snapshot.rules.weapon.lifetimeMs / LIMITS.tickMs) + 1) * (3 * snapshot.players.length + 2);
      if (row.segments >= segmentLimit) throw new Error("Bullet segment bound exceeded");
      this.sql.exec("UPDATE bullets SET segments = segments + 1 WHERE projectile_id = ?", projectileId);
    }
    this.sql.exec("INSERT INTO bullet_events(sequence, projectile_id, kind, payload) VALUES (?, ?, ?, ?)", wrapped.eventSequence, projectileId, event.kind, JSON.stringify(wrapped));
  }

  private create(snapshot: CombatSnapshot, projectileId: string, shooterId: string, shotId: string, spawnSequence: number | null): void {
    // Respawn resets weapon cooldown, so a configured fast respawn can admit
    // another shot sooner than the ordinary per-life fire interval.
    const interval = Math.max(LIMITS.tickMs, Math.min(snapshot.rules.weapon.cooldownMs, snapshot.rules.respawnMs));
    const maxShots = snapshot.players.length * (Math.ceil(snapshot.rules.durationMs / interval) + 1);
    const shots = this.sql.exec<{ shots: number }>("SELECT shots FROM bullet_totals WHERE singleton = 1").one().shots;
    if (shots >= maxShots) throw new Error("Match bullet bound exceeded");
    this.sql.exec("INSERT INTO bullets(projectile_id, shooter_id, shot_id, spawn_sequence) VALUES (?, ?, ?, ?)", projectileId, shooterId, shotId, spawnSequence);
    this.sql.exec("UPDATE bullet_totals SET shots = shots + 1 WHERE singleton = 1");
  }
}
