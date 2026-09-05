import type {
  SpectatorEventSnapshot,
  SpectatorMatchSnapshot,
  SpectatorPlayerSnapshot,
  SpectatorSnapshot,
} from "../domain/spectator";
import type {
  SpectatorSnapshotAdapter,
  SpectatorSnapshotObserver,
  SpectatorSnapshotRequest,
} from "./spectatorAdapter";

export const DEMO_NOW = Date.UTC(2026, 7, 22, 19, 30, 0);

export type DemoSnapshotKind =
  | "waiting"
  | "countdown"
  | "active"
  | "ended"
  | "cancelled"
  | "arena"
  | "arena-calibrating"
  | "arena-paused"
  | "arena-ended";

export type DemoFixtureKind =
  | "loading"
  | DemoSnapshotKind
  | "degraded"
  | "recovery"
  | "arena-degraded"
  | "arena-recovery"
  | "error";

const host: SpectatorPlayerSnapshot = {
  id: "player-rook",
  displayName: "ROOK",
  role: "host",
  ready: true,
  connected: true,
  health: 100,
};

const guest: SpectatorPlayerSnapshot = {
  id: "player-vale",
  displayName: "VALE",
  role: "guest",
  ready: true,
  connected: true,
  health: 66,
};

const hitEvent: SpectatorEventSnapshot = {
  id: "event-debug-hit",
  type: "hit",
  actorPlayerId: host.id,
  targetPlayerId: guest.id,
  zone: "torso",
  damage: 34,
  message: "ROOK HIT VALE • TORSO −34",
  createdAt: DEMO_NOW - 2_000,
};

const activeEvents: readonly SpectatorEventSnapshot[] = [
  hitEvent,
  {
    id: "event-started",
    type: "started",
    message: "DUEL STARTED",
    createdAt: DEMO_NOW - 12_000,
  },
];

function match(
  code: string,
  values: Pick<SpectatorMatchSnapshot, "phase"> &
    Partial<Pick<SpectatorMatchSnapshot, "startsAt">>,
): SpectatorMatchSnapshot {
  return {
    id: `demo-${code}`,
    code,
    ...values,
  };
}

export function createDemoSnapshot(
  code: string,
  kind: DemoSnapshotKind,
): SpectatorSnapshot {
  switch (kind) {
    case "arena":
    case "arena-calibrating":
    case "arena-paused":
    case "arena-ended": {
      const combatPhase = kind === "arena-calibrating" ? "calibrating" : kind === "arena-paused" ? "paused" : kind === "arena-ended" ? "finished" : "running";
      return {
        serverNow: DEMO_NOW,
        match: {...match(code, {phase: combatPhase === "finished" ? "finished" : "running"}),
          combatMode: "durableObject", maxPlayers: 4, combatPhase,
          ...(combatPhase === "finished" ? {winnerPlayerId: "player-ember"} : {})},
        players: [
          {...host, kills: 2, deaths: 1, lifeState: "alive"},
          {...guest, kills: 1, deaths: 2, lifeState: "alive"},
          {...guest, id: "player-ember", displayName: "EMBER", health: 100, kills: 4, deaths: 0, lifeState: "alive"},
          {...guest, id: "player-north", displayName: "NORTH STAR OF THE MOUNTAIN", health: 0, kills: 0, deaths: 4, lifeState: "respawning", respawnAt: DEMO_NOW + 4200},
        ],
        events: [{...hitEvent, actorPlayerId: "player-ember", targetPlayerId: "player-north", message: "EMBER HIT NORTH STAR OF THE MOUNTAIN", damage: 34}],
      };
    }
    case "waiting":
      return {
        serverNow: DEMO_NOW,
        match: match(code, { phase: "lobby" }),
        players: [host],
        events: [],
      };
    case "countdown":
      return {
        serverNow: DEMO_NOW,
        match: match(code, {
          phase: "countdown",
          startsAt: DEMO_NOW + 3_000,
        }),
        players: [host, { ...guest, health: 100 }],
        events: [],
      };
    case "active":
      return {
        serverNow: DEMO_NOW,
        match: match(code, {
          phase: "running",
          startsAt: DEMO_NOW - 12_000,
        }),
        players: [host, guest],
        events: activeEvents,
      };
    case "ended":
      return {
        serverNow: DEMO_NOW,
        match: match(code, {
          phase: "finished",
          startsAt: DEMO_NOW - 60_000,
        }),
        players: [host, guest],
        events: [
          {
            id: "event-finished",
            type: "finished",
            message: "DUEL COMPLETE",
            createdAt: DEMO_NOW,
          },
          ...activeEvents,
        ],
      };
    case "cancelled":
      return {
        serverNow: DEMO_NOW,
        match: match(code, { phase: "cancelled" }),
        players: [host, { ...guest, connected: false }],
        events: activeEvents,
      };
  }
}

function emitRecoverySequence(
  request: SpectatorSnapshotRequest,
  observer: SpectatorSnapshotObserver,
  kind: "active" | "arena" = "active",
): () => void {
  observer.next(createDemoSnapshot(request.code, kind));

  const interruption = window.setTimeout(
    () => observer.error(new Error("The deterministic feed was interrupted.")),
    40,
  );
  const recovery = window.setTimeout(() => {
    const recovered = createDemoSnapshot(request.code, kind);
    observer.next({
      ...recovered,
      serverNow: recovered.serverNow + 2_000,
      // Simulate a replayed record so the display path proves identity de-duping.
      events: [recovered.events[0]!, recovered.events[0]!, ...recovered.events.slice(1)],
    });
  }, 100);

  return () => {
    window.clearTimeout(interruption);
    window.clearTimeout(recovery);
  };
}

export function createDemoSpectatorAdapter(
  fixture: DemoFixtureKind,
): SpectatorSnapshotAdapter {
  return {
    source: "demo",
    subscribe(
      request: SpectatorSnapshotRequest,
      observer: SpectatorSnapshotObserver,
    ) {
      switch (fixture) {
        case "loading":
          return () => undefined;
        case "error":
          observer.error(new Error("The deterministic feed is unavailable."));
          return () => undefined;
        case "degraded":
        case "arena-degraded": {
          observer.next(createDemoSnapshot(request.code, fixture === "arena-degraded" ? "arena" : "active"));
          const timeout = window.setTimeout(
            () =>
              observer.error(new Error("The deterministic feed was interrupted.")),
            40,
          );
          return () => window.clearTimeout(timeout);
        }
        case "recovery":
        case "arena-recovery":
          return emitRecoverySequence(request, observer, fixture === "arena-recovery" ? "arena" : "active");
        case "waiting":
        case "countdown":
        case "active":
        case "ended":
        case "cancelled":
        case "arena":
        case "arena-calibrating":
        case "arena-paused":
        case "arena-ended":
          observer.next(createDemoSnapshot(request.code, fixture));
          return () => undefined;
      }
    },
    dispose() {
      // The deterministic adapter owns no long-lived client connection.
    },
  };
}
