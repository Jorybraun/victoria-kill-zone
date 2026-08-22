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
  | "cancelled";

export type DemoFixtureKind =
  | "loading"
  | DemoSnapshotKind
  | "degraded"
  | "recovery"
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
): () => void {
  observer.next(createDemoSnapshot(request.code, "active"));

  const interruption = window.setTimeout(
    () => observer.error(new Error("The deterministic feed was interrupted.")),
    40,
  );
  const recovery = window.setTimeout(() => {
    const recovered = createDemoSnapshot(request.code, "active");
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
        case "degraded": {
          observer.next(createDemoSnapshot(request.code, "active"));
          const timeout = window.setTimeout(
            () =>
              observer.error(new Error("The deterministic feed was interrupted.")),
            40,
          );
          return () => window.clearTimeout(timeout);
        }
        case "recovery":
          return emitRecoverySequence(request, observer);
        case "waiting":
        case "countdown":
        case "active":
        case "ended":
        case "cancelled":
          observer.next(createDemoSnapshot(request.code, fixture));
          return () => undefined;
      }
    },
    dispose() {
      // The deterministic adapter owns no long-lived client connection.
    },
  };
}
