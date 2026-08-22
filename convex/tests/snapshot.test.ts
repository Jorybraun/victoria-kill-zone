import { describe, expect, it } from "vitest";
import { COUNTDOWN_MS } from "../domain/contract.js";
import {
  buildMatchSnapshot,
  buildSpectatorSnapshot,
  type StoredEvent,
  type StoredMatch,
  type StoredPlayer,
} from "../domain/snapshot.js";

const T0 = 1_760_000_000_000;

const match: StoredMatch = {
  id: "match-1",
  code: "ABC123",
  phase: "countdown",
  durationMs: 300_000,
  startsAt: T0 + COUNTDOWN_MS,
  endsAt: T0 + COUNTDOWN_MS + 300_000,
};

const players: StoredPlayer[] = [
  {
    id: "guest",
    displayName: "JORY",
    role: "guest",
    ready: true,
    connected: true,
    health: 66,
    ammo: 8,
  },
  { id: "host", displayName: "VIC", role: "host", ready: true, connected: true, health: 100, ammo: 7 },
];

const events: StoredEvent[] = [
  { id: "event-1", type: "joined", message: "VIC JOINED", createdAt: T0 - 20 },
  {
    id: "event-2",
    type: "hit",
    message: "VIC HIT JORY • TORSO \u221234",
    createdAt: T0,
    actorPlayerId: "host",
    targetPlayerId: "guest",
    zone: "torso",
    damage: 34,
  },
];

describe("buildMatchSnapshot", () => {
  it("returns server time, host-first players, and newest-first events", () => {
    const snapshot = buildMatchSnapshot({ match, localPlayerId: "guest", players, events, now: T0 });

    expect(snapshot.serverNow).toBe(T0);
    expect(snapshot.localPlayerId).toBe("guest");
    expect(snapshot.match).toEqual({
      id: "match-1",
      code: "ABC123",
      phase: "countdown",
      durationMs: 300_000,
      startsAt: T0 + COUNTDOWN_MS,
      endsAt: T0 + COUNTDOWN_MS + 300_000,
    });
    expect(snapshot.players.map((player) => player.role)).toEqual(["host", "guest"]);
    expect(snapshot.events.map((event) => event.id)).toEqual(["event-2", "event-1"]);
  });

  it("retires a match whose end time has passed but never promotes a countdown", () => {
    // A read may retire a duel whose `endsAt` has passed — treating it as
    // playable would be worse than showing it early — but only the scheduled
    // activation issues `running`, so a read that outran the job still waits.
    const pastStart = buildMatchSnapshot({
      match,
      localPlayerId: "host",
      players,
      events,
      now: T0 + COUNTDOWN_MS + 1,
    });
    const finished = buildMatchSnapshot({
      match,
      localPlayerId: "host",
      players,
      events,
      now: (match.endsAt ?? 0) + 1,
    });

    expect(pastStart.match.phase).toBe("countdown");
    expect(finished.match.phase).toBe("finished");
  });

  it("breaks equal event timestamps by ascending id", () => {
    const tied: StoredEvent[] = [
      { id: "event-b", type: "ready", message: "JORY READY", createdAt: T0 },
      { id: "event-a", type: "ready", message: "VIC READY", createdAt: T0 },
      { id: "event-c", type: "joined", message: "VIC JOINED", createdAt: T0 - 1 },
    ];

    const feed = (
      snapshot: { events: readonly { id: string }[] },
    ): string[] => snapshot.events.map((event) => event.id);

    expect(
      feed(buildMatchSnapshot({ match, localPlayerId: "host", players, events: tied, now: T0 })),
    ).toEqual(["event-a", "event-b", "event-c"]);
    expect(feed(buildSpectatorSnapshot({ match, players, events: tied, now: T0 }))).toEqual([
      "event-a",
      "event-b",
      "event-c",
    ]);
  });

  it("omits absent countdown timings instead of emitting nulls", () => {
    const snapshot = buildMatchSnapshot({
      match: { id: "match-2", code: "ZZZ999", phase: "lobby", durationMs: 300_000 },
      localPlayerId: "host",
      players,
      events: [],
      now: T0,
    });

    expect("startsAt" in snapshot.match).toBe(false);
    expect("endsAt" in snapshot.match).toBe(false);
  });
});

describe("buildSpectatorSnapshot", () => {
  it("projects an allow-list with no local player and no arena geometry", () => {
    const snapshot = buildSpectatorSnapshot({ match, players, events, now: T0 });

    expect(Object.keys(snapshot).sort()).toEqual(["events", "match", "players", "serverNow"]);
    expect("localPlayerId" in snapshot).toBe(false);
    expect(Object.keys(snapshot.match).sort()).toEqual([
      "code",
      "durationMs",
      "endsAt",
      "id",
      "phase",
      "startsAt",
    ]);
    for (const player of snapshot.players) {
      expect(Object.keys(player).sort()).toEqual([
        "ammo",
        "connected",
        "displayName",
        "health",
        "id",
        "ready",
        "role",
      ]);
    }
  });

  it("cannot surface a stored field outside the allow-list", () => {
    const contaminated = [
      { ...players[1]!, sessionHash: "deadbeef", deviceId: "iphone-15" },
    ] as unknown as StoredPlayer[];

    const snapshot = buildSpectatorSnapshot({
      match: { ...match, arenaRadiusMeters: 30 } as unknown as StoredMatch,
      players: contaminated,
      events,
      now: T0,
    });

    expect(JSON.stringify(snapshot)).not.toContain("deadbeef");
    expect(JSON.stringify(snapshot)).not.toContain("iphone-15");
    expect(JSON.stringify(snapshot)).not.toContain("arenaRadiusMeters");
  });
});
