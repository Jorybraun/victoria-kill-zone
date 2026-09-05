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
    // Legacy centerless (G2 create shape) by default; geofenced tests override.
    arenaCenterAt: null,
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

  it.each([-1, 0, 1])("preserves legacy expiry at deadline offset %i on both views", (offset) => {
    const match = snapshotMatch();
    const players = [player("host"), player("guest")];
    const now = T0 + GAMEPLAY.matchDurationMs + offset;
    const phone = buildMatchSnapshot(match, "host", players, [], now);
    const spectator = buildSpectatorSnapshot(match, players, [], now);

    for (const snapshot of [phone, spectator]) {
      expect(snapshot.match.phase).toBe(offset < 0 ? "running" : "finished");
      expect(snapshot.match.endsAt).toBe(T0 + GAMEPLAY.matchDurationMs);
      expect(snapshot.match).not.toHaveProperty("combatMode");
    }
  });

  it.each(["running", "paused", "finished"] as const)(
    "keeps the stored realtime %s projection authoritative across its old wall deadline",
    (combatPhase) => {
      const phase = combatPhase === "finished" ? "finished" : "running";
      const match = snapshotMatch({
        combatMode: "durableObject", combatPhase, maxPlayers: 4,
        status: combatPhase === "finished" ? "ended" : "active", phase,
      });
      const players = [player("host"), player("guest")];
      // A delayed projection can retain an elapsed estimated wall deadline.
      // Conversely, an authoritative finish must apply even before that estimate.
      for (const offset of [-1, 0, GAMEPLAY.matchDurationMs]) {
        const now = T0 + GAMEPLAY.matchDurationMs + offset;
        const phone = buildMatchSnapshot(match, "host", players, [], now);
        const spectator = buildSpectatorSnapshot(match, players, [], now);
        for (const snapshot of [phone, spectator]) {
          expect(snapshot.serverNow).toBe(now);
          expect(snapshot.match).toMatchObject({
            combatMode: "durableObject", combatPhase, phase, maxPlayers: 4,
            endsAt: T0 + GAMEPLAY.matchDurationMs,
          });
        }
      }
    },
  );

  it("does not finish a realtime lobby or calibration with no round deadline", () => {
    const players = [player("host"), player("guest")];
    for (const phase of ["lobby", "running"] as const) {
      const match = snapshotMatch({ combatMode: "durableObject", combatPhase: "calibrating",
        phase, status: phase === "lobby" ? "setup" : "active", startsAt: null, endsAt: null });
      const now = T0 + GAMEPLAY.matchDurationMs * 2;
      const phone = buildMatchSnapshot(match, "host", players, [], now);
      const spectator = buildSpectatorSnapshot(match, players, [], now);
      for (const snapshot of [phone, spectator]) {
        expect(snapshot.match).toMatchObject({ combatMode: "durableObject", combatPhase: "calibrating", phase });
        expect(snapshot.match).not.toHaveProperty("endsAt");
      }
    }
  });

  it("keeps realtime respawn and reload state until a new authority projection arrives", () => {
    const match = snapshotMatch({ combatMode: "durableObject", combatPhase: "paused" });
    const reloadEndsAt = T0 + 1_000, respawnAt = T0 + 5_000;
    const players = [player("host", { ammo: 3, reloadEndsAt }),
      player("guest", { health: 0, lifeState: "respawning", respawnAt })];
    const now = T0 + 10_000;
    const phone = buildMatchSnapshot(match, "host", players, [], now);
    const spectator = buildSpectatorSnapshot(match, players, [], now);
    for (const snapshot of [phone, spectator]) {
      expect(snapshot.players[0]).toMatchObject({ ammo: 3, reloadEndsAt });
      expect(snapshot.players[1]).toMatchObject({ health: 0, lifeState: "respawning", respawnAt });
    }
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

  it("projects an active reload deadline on both views and omits it after completion", () => {
    const reloadEndsAt = T0 + GAMEPLAY.reloadDurationMs;
    const players = [player("host", { ammo: 3, reloadEndsAt }), player("guest")];
    const phone = buildMatchSnapshot(snapshotMatch(), "host", players, [], T0);
    const spectator = buildSpectatorSnapshot(snapshotMatch(), players, [], T0);
    for (const snapshot of [phone, spectator]) {
      expect(snapshot.players[0]).toMatchObject({ ammo: 3, reloadEndsAt });
      expect(snapshot.players[1]).not.toHaveProperty("reloadEndsAt");
    }
  });

  it("projects verdict target confirmation and omits absent or null values", () => {
    const confirmed = buildSpectatorSnapshot(
      snapshotMatch(),
      [player("host"), player("guest")],
      events.map((event) => ({ ...event, targetConfirmed: true })),
      T0 + 1_000,
    );
    expect(confirmed.events[0]).toHaveProperty("targetConfirmed", true);

    const absent = buildSpectatorSnapshot(
      snapshotMatch(),
      [player("host"), player("guest")],
      events.map((event) => ({ ...event, targetConfirmed: null })),
      T0 + 1_000,
    );
    expect(absent.events[0]).not.toHaveProperty("targetConfirmed");
  });

  it("preserves shot identity while leaving legacy event rows compatible", () => {
    const withIdentity = events.map((event) => ({ ...event, clientShotId: "shot-confirmed" }));
    const players = [player("host"), player("guest")];
    const phone = buildMatchSnapshot(snapshotMatch(), "host", players, withIdentity, T0 + 1_000);
    const spectator = buildSpectatorSnapshot(snapshotMatch(), players, withIdentity, T0 + 1_000);
    for (const snapshot of [phone, spectator]) {
      expect(snapshot.events[0]).toHaveProperty("clientShotId", "shot-confirmed");
    }
    const legacy = buildMatchSnapshot(snapshotMatch(), "host", players, events, T0 + 1_000);
    expect(legacy.events[0]).not.toHaveProperty("clientShotId");
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

  describe("geofenced location projection", () => {
    // Arena centred at the equator/prime meridian: 0.000089932° of longitude
    // is ~10 m east; matches the frozen geofence.v1 fixture geometry.
    const geofenced = () => snapshotMatch({ centerLatitude: 0, centerLongitude: 0, arenaCenterAt: T0 });
    const now = T0 + 1_000;
    const located = () =>
      player("host", {
        arenaState: "inside",
        latitude: 0,
        longitude: 0.000089932,
        headingDegrees: 90,
        locationAccuracyMeters: 5,
        locationAt: now - 500,
      });

    it("projects raw location only on the authenticated phone shape", () => {
      const snapshot = buildMatchSnapshot(geofenced(), "host", [located(), player("guest")], [], now);

      expect(snapshot.players[0]).toMatchObject({
        arenaState: "inside",
        latitude: 0,
        longitude: 0.000089932,
        headingDegrees: 90,
        locationAccuracyMeters: 5,
        locationAt: now - 500,
      });
      // Players with no trusted sample omit every location field.
      expect(snapshot.players[1]).not.toHaveProperty("latitude");
      expect(snapshot.players[1]).not.toHaveProperty("locationAt");
    });

    it("exposes only sanitized arena-relative metres on the public spectator projection", () => {
      const snapshot = buildSpectatorSnapshot(geofenced(), [located(), player("guest")], [], now);

      expect(snapshot.players[0]?.arenaPosition).toEqual({
        eastMeters: 10,
        northMeters: 0,
        headingDegrees: 90,
      });
      expect(snapshot.players[1]?.arenaPosition).toBeUndefined();

      const serialized = JSON.stringify(snapshot);
      // Never raw coordinates, accuracy, location timestamps, history, or
      // session/device/capability data — only arena-relative east/north metres.
      expect(serialized).not.toMatch(
        /"latitude"|"longitude"|"locationAccuracyMeters"|"accuracyMeters"|"locationAt"|"capturedAtClient"|"lastSeenAt"|centerLatitude|centerLongitude|sessionHash|deviceIdHash|sessionSecret|capabilit/,
      );
    });

    it("projects authoritative staleness decay for a geofenced match on both views", () => {
      const stale = player("host", {
        arenaState: "inside",
        latitude: 0,
        longitude: 0.000089932,
        locationAccuracyMeters: 5,
        locationAt: T0,
      });
      const later = T0 + 6_000;

      const phone = buildMatchSnapshot(geofenced(), "host", [stale, player("guest")], [], later);
      const spectator = buildSpectatorSnapshot(geofenced(), [stale, player("guest")], [], later);
      expect(phone.players[0]?.arenaState).toBe("uncertain");
      expect(spectator.players[0]?.arenaState).toBe("uncertain");

      // Compatibility: a legacy centerless match (existing iOS clients create
      // matches without arenaCenter) keeps its stored pre-geofence state.
      const legacy = buildSpectatorSnapshot(
        snapshotMatch({ arenaCenterAt: null }),
        [stale, player("guest")],
        [],
        later,
      );
      expect(legacy.players[0]?.arenaState).toBe("inside");
    });
  });
});
