export const MATCH_CODE_LENGTH = 6;
export const PLAYER_CAPACITY = 2;
export const MAX_HEALTH = 100;

export type MatchPhase =
  | "lobby"
  | "countdown"
  | "running"
  | "finished"
  | "cancelled";

export type HitZone = "head" | "torso" | "limbs";

export type PlayerLifeState =
  | "alive"
  | "dead"
  | "respawning"
  | "disconnected";

export type SpectatorEventType =
  | "joined"
  | "ready"
  | "started"
  | "shot"
  | "hit"
  | "eliminated"
  | "respawned"
  | "out_of_zone"
  | "finished";

/**
 * G2-safe match data returned by `queries:spectatorSnapshot({ code })`.
 * Additive combat telemetry lives on players and events, leaving this base intact.
 */
export interface SpectatorMatchSnapshot {
  id: string;
  code: string;
  phase: MatchPhase;
  startsAt?: number;
  combatMode?: "durableObject";
  combatPhase?: "calibrating" | "running" | "paused" | "finished";
  maxPlayers?: number;
  durationMs?: number;
  endsAt?: number;
  winnerPlayerId?: string;
}

export interface SpectatorPlayerSnapshot {
  id: string;
  displayName: string;
  role: "host" | "guest";
  ready: boolean;
  connected: boolean;
  health: number;
  /** Additive phase0.v1 combat fields. Omitted by a G2 snapshot. */
  kills?: number;
  deaths?: number;
  lifeState?: PlayerLifeState;
  respawnAt?: number;
}

export interface SpectatorEventSnapshot {
  id: string;
  type: SpectatorEventType;
  message: string;
  createdAt: number;
  actorPlayerId?: string;
  targetPlayerId?: string;
  zone?: HitZone;
  damage?: number;
}

/** Sanitized return value of the public `queries:spectatorSnapshot` query. */
export interface SpectatorSnapshot {
  serverNow: number;
  match: SpectatorMatchSnapshot;
  players: readonly SpectatorPlayerSnapshot[];
  /** Server-ordered, newest-first authoritative events. */
  events: readonly SpectatorEventSnapshot[];
}

export type SpectatorDataSource = "demo" | "convex";
export type SnapshotViewKind = "waiting" | "active" | "ended";
export type SpectatorErrorReason = "not-found" | "network" | "unknown";

interface SnapshotViewState {
  code: string;
  source: SpectatorDataSource;
  snapshot: SpectatorSnapshot;
}

export type SpectatorViewState =
  | { kind: "no-selection"; initialCode: string; isDemo: boolean }
  | { kind: "loading"; code: string; source: SpectatorDataSource }
  | ({ kind: "waiting" } & SnapshotViewState)
  | ({ kind: "active" } & SnapshotViewState)
  | ({ kind: "ended" } & SnapshotViewState)
  | ({
      kind: "degraded";
      lastSyncedAt: number;
    } & SnapshotViewState)
  | ({
      kind: "recovery";
      currentKind: SnapshotViewKind;
    } & SnapshotViewState)
  | {
      kind: "error";
      code: string;
      source: SpectatorDataSource;
      reason: SpectatorErrorReason;
    };

export function normalizeMatchCode(value: string): string {
  return value
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, "")
    .slice(0, MATCH_CODE_LENGTH);
}

export function isValidMatchCode(value: string): boolean {
  return new RegExp(`^[A-Z0-9]{${MATCH_CODE_LENGTH}}$`).test(value);
}

export function viewKindForPhase(phase: MatchPhase): SnapshotViewKind {
  switch (phase) {
    case "lobby":
    case "countdown":
      return "waiting";
    case "running":
      return "active";
    case "finished":
    case "cancelled":
      return "ended";
  }
}

/** Preserve the backend's order while removing replayed records by identity. */
export function dedupeEventsInServerOrder(
  events: readonly SpectatorEventSnapshot[],
): readonly SpectatorEventSnapshot[] {
  const seen = new Set<string>();
  return events.filter((event) => {
    if (seen.has(event.id)) {
      return false;
    }
    seen.add(event.id);
    return true;
  });
}

export function snapshotWithDedupedEvents(
  snapshot: SpectatorSnapshot,
): SpectatorSnapshot {
  const events = dedupeEventsInServerOrder(snapshot.events);
  return events.length === snapshot.events.length
    ? snapshot
    : { ...snapshot, events };
}

/** The arena authority owns combat phase; legacy wall-time phase cannot finish it. */
export function displayPhase(match: SpectatorMatchSnapshot): MatchPhase | "calibrating" | "paused" | "unavailable" {
  if (match.combatMode !== "durableObject") return match.phase;
  if (match.combatPhase !== undefined) return match.combatPhase;
  return match.phase === "lobby" || match.phase === "cancelled" ? match.phase : "unavailable";
}

export function viewKindForMatch(match: SpectatorMatchSnapshot): SnapshotViewKind {
  const phase = displayPhase(match);
  if (phase === "finished" || phase === "cancelled") return "ended";
  return phase === "running" || phase === "paused" ? "active" : "waiting";
}

export const PLAYER_SLOTS = ["A", "B", "C", "D"] as const;
export type PlayerSlot = typeof PLAYER_SLOTS[number];

/** Preserve the server order instead of selecting a single opponent. */
export function playerSlots(snapshot: SpectatorSnapshot): readonly (SpectatorPlayerSnapshot | undefined)[] {
  const configured = snapshot.match.combatMode === "durableObject" ? snapshot.match.maxPlayers : PLAYER_CAPACITY;
  const capacity = Number.isInteger(configured) ? configured ?? PLAYER_CAPACITY : PLAYER_CAPACITY;
  const count = Math.min(PLAYER_SLOTS.length, Math.max(PLAYER_CAPACITY, capacity, snapshot.players.length));
  return Array.from({length: count}, (_, index) => snapshot.players[index]);
}

export function resultLabel(snapshot: SpectatorSnapshot): string | null {
  if (displayPhase(snapshot.match) !== "finished") return null;
  if (snapshot.match.winnerPlayerId !== undefined) {
    const winner = snapshot.players.find(player => player.id === snapshot.match.winnerPlayerId);
    return winner === undefined ? "RESULT UNAVAILABLE" : `${winner.displayName} WINS`;
  }
  return snapshot.match.combatMode === "durableObject" && snapshot.match.combatPhase === "finished" ? "MATCH DRAW" : null;
}
