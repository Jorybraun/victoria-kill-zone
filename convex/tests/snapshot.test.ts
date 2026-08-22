import { describe, expect, it } from "vitest";
import { GAMEPLAY } from "../domain/config.js";
import { buildSpectatorSnapshot, type SnapshotMatch } from "../domain/snapshot.js";
import { hashSecret } from "../domain/session.js";
import { match, player, T0 } from "./factories.js";

const SESSION_SECRET = "c".repeat(64);

function snapshotMatch(overrides: Partial<SnapshotMatch> = {}): SnapshotMatch {
  return {
    ...match(),
    id: "match-1",
    code: "AB12CD",
    centerLatitude: 48.4284,
    centerLongitude: -123.3656,
    ...overrides,
  };
}

const events = [
  {
    id: "event-1",
    type: "hit",
    actorPlayerId: "host",
    targetPlayerId: "guest",
    zone: "torso" as const,
    damage: 34,
    message: "Host hit Challenger (torso) for 34",
    createdAt: T0 + 500,
  },
];

describe("spectatorSnapshot", () => {
  it("reports the arena, timer, and per-player authority state", () => {
    const now = T0 + 30_000;
    const snapshot = buildSpectatorSnapshot(
      snapshotMatch(),
      [player("host", { kills: 1, damageDealt: 100 }), player("guest", { health: 66 })],
      events,
      now,
    );

    expect(snapshot).toMatchObject({
      matchId: "match-1",
      code: "AB12CD",
      status: "active",
      phase: "running",
      arena: { radiusMeters: GAMEPLAY.defaultArenaRadiusMeters },
      remainingMs: GAMEPLAY.matchDurationMs - 30_000,
      generatedAt: now,
    });
    expect(snapshot.players.map((entry) => entry.health)).toEqual([100, 66]);
    expect(snapshot.events[0]).toMatchObject({
      actorDisplayName: "Host",
      targetDisplayName: "Challenger",
      message: "Host hit Challenger (torso) for 34",
    });
  });

  it("reports an active duel past endsAt as ended", () => {
    const snapshot = buildSpectatorSnapshot(
      snapshotMatch(),
      [player("host"), player("guest")],
      [],
      T0 + GAMEPLAY.matchDurationMs + 1,
    );

    expect(snapshot.status).toBe("ended");
    expect(snapshot.phase).toBe("finished");
    expect(snapshot.remainingMs).toBe(0);
  });

  it("surfaces the remaining respawn delay instead of raw timestamps", () => {
    const now = T0 + 1_000;
    const snapshot = buildSpectatorSnapshot(
      snapshotMatch(),
      [player("host"), player("guest", { lifeState: "dead", health: 0, respawnAt: now + 4_000 })],
      [],
      now,
    );

    expect(snapshot.players[1]).toMatchObject({ lifeState: "dead", respawnInMs: 4_000 });
    expect(JSON.stringify(snapshot)).not.toContain("respawnAt");
  });

  it("never exposes session digests, session secrets, or device identifiers", () => {
    const contaminated = [
      { ...player("host"), sessionHash: hashSecret(SESSION_SECRET), deviceIdHash: hashSecret("device-a") },
      { ...player("guest"), sessionHash: hashSecret("guest-secret"), deviceIdHash: hashSecret("device-b") },
    ];

    const serialized = JSON.stringify(
      buildSpectatorSnapshot(snapshotMatch(), contaminated, events, T0 + 1_000),
    );

    expect(serialized).not.toContain(hashSecret(SESSION_SECRET));
    expect(serialized).not.toContain(hashSecret("guest-secret"));
    expect(serialized).not.toContain(hashSecret("device-a"));
    expect(serialized).not.toContain(hashSecret("device-b"));
    expect(serialized).not.toContain(SESSION_SECRET);
    expect(serialized).not.toMatch(/sessionHash|deviceIdHash|sessionSecret/);
  });
});
