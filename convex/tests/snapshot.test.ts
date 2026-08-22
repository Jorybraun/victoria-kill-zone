import { describe, expect, it } from "vitest";
import { GAMEPLAY } from "../domain/config.js";
import {
  buildMatchSnapshot,
  buildSpectatorSnapshot,
  type SnapshotMatch,
} from "../domain/snapshot.js";
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
    message: "Host hit Challenger",
    createdAt: T0 + 500,
  },
];

describe("contract snapshots", () => {
  it("projects the authenticated phone shape with synchronized authority state", () => {
    const now = T0 + 30_000;
    const snapshot = buildMatchSnapshot(
      snapshotMatch(),
      "host",
      [player("guest", { health: 66 }), player("host", { kills: 1, damageDealt: 100 })],
      events,
      now,
    );

    expect(snapshot).toMatchObject({
      serverNow: now,
      match: {
        id: "match-1",
        code: "AB12CD",
        phase: "running",
        durationMs: GAMEPLAY.matchDurationMs,
      },
      arena: { latitude: 48.4284, longitude: -123.3656, radiusMeters: 30 },
      localPlayerId: "host",
    });
    expect(snapshot.players.map((entry) => entry.id)).toEqual(["host", "guest"]);
    expect(snapshot.players.map((entry) => entry.health)).toEqual([100, 66]);
    expect(snapshot.events[0]).toMatchObject({ actorPlayerId: "host", targetPlayerId: "guest" });
  });

  it("derives finished once the authoritative running window expires", () => {
    const snapshot = buildSpectatorSnapshot(
      snapshotMatch(),
      [player("host"), player("guest")],
      [],
      T0 + GAMEPLAY.matchDurationMs,
    );

    expect(snapshot.match.phase).toBe("finished");
    expect(snapshot.match.endsAt).toBe(T0 + GAMEPLAY.matchDurationMs);
  });

  it("projects respawn state and server-owned timestamp on both player views", () => {
    const respawnAt = T0 + 5_000;
    const snapshot = buildSpectatorSnapshot(
      snapshotMatch(),
      [player("host"), player("guest", { lifeState: "respawning", health: 0, respawnAt })],
      [],
      T0 + 1_000,
    );

    expect(snapshot.players[1]).toMatchObject({
      lifeState: "respawning",
      health: 0,
      respawnAt,
    });
  });

  it("sanitizes phone and spectator projections field by field", () => {
    const contaminated = [
      {
        ...player("host"),
        sessionHash: hashSecret(SESSION_SECRET),
        deviceIdHash: hashSecret("device-a"),
      },
      {
        ...player("guest"),
        sessionHash: hashSecret("guest-secret"),
        deviceIdHash: hashSecret("device-b"),
      },
    ];

    const phone = JSON.stringify(
      buildMatchSnapshot(snapshotMatch(), "host", contaminated, events, T0 + 1_000),
    );
    const spectator = JSON.stringify(
      buildSpectatorSnapshot(snapshotMatch(), contaminated, events, T0 + 1_000),
    );

    for (const serialized of [phone, spectator]) {
      expect(serialized).not.toContain(SESSION_SECRET);
      expect(serialized).not.toMatch(/sessionHash|deviceIdHash|sessionSecret/);
    }
    expect(spectator).not.toMatch(/centerLatitude|centerLongitude|latitude|longitude|lastSeenAt/);
    expect(phone).toContain("lastSeenAt");
  });
});
