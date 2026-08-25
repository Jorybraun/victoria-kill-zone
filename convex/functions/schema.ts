import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

const matchStatus = v.union(
  v.literal("setup"),
  v.literal("waiting"),
  v.literal("active"),
  v.literal("ended"),
);

const matchPhase = v.union(
  v.literal("lobby"),
  v.literal("countdown"),
  v.literal("running"),
  v.literal("finished"),
  v.literal("cancelled"),
);

const lifeState = v.union(
  v.literal("alive"),
  v.literal("dead"),
  v.literal("respawning"),
  v.literal("disconnected"),
);

const hitZone = v.union(v.literal("head"), v.literal("torso"), v.literal("limbs"));

const arenaState = v.union(
  v.literal("inside"),
  v.literal("warning"),
  v.literal("uncertain"),
  v.literal("outside"),
);

const shotOutcome = v.union(
  v.literal("miss"),
  v.literal("hit"),
  v.literal("kill"),
  v.literal("rejected"),
);

const nullableNumber = v.union(v.number(), v.null());

/**
 * Convex owns match phase, player sessions, health, ammunition, cooldown,
 * score, respawn timing, and the shot ledger. Stored session and device digests
 * never appear in a public query result; see `functions/queries.ts`.
 */
export default defineSchema({
  matches: defineTable({
    code: v.string(),
    status: matchStatus,
    // Optional only for a safe rollout over any pre-contract development rows.
    phase: v.optional(matchPhase),
    hostPlayerId: v.union(v.id("players"), v.null()),
    centerLatitude: v.number(),
    centerLongitude: v.number(),
    // Receipt time of a validated phase0 arenaCenter sample. Absent/null on
    // legacy centerless (G2 create shape) matches, which stay geofence-exempt.
    arenaCenterAt: v.optional(nullableNumber),
    radiusMeters: v.number(),
    maxPlayers: v.number(),
    durationMs: v.number(),
    startsAt: v.optional(nullableNumber),
    startedAt: nullableNumber,
    endsAt: nullableNumber,
    winnerPlayerId: v.union(v.id("players"), v.null()),
    endReason: v.union(
      v.literal("duration_elapsed"),
      v.literal("host_ended"),
      v.literal("abandoned"),
      v.null(),
    ),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_code", ["code"])
    .index("by_status", ["status"]),

  players: defineTable({
    matchId: v.id("matches"),
    displayName: v.string(),
    // Digests only. Raw device identifiers and session secrets are never stored.
    deviceIdHash: v.optional(v.string()),
    sessionHash: v.string(),
    role: v.union(v.literal("host"), v.literal("guest")),
    ready: v.optional(v.boolean()),
    connected: v.boolean(),
    lifeState,
    arenaState: v.optional(arenaState),
    health: v.number(),
    ammo: v.number(),
    kills: v.number(),
    deaths: v.number(),
    damageDealt: v.number(),
    shotsFired: v.number(),
    shotsHit: v.number(),
    headshots: v.number(),
    lastShotAt: nullableNumber,
    respawnAt: nullableNumber,
    lastSeenAt: v.number(),
    joinedAt: v.number(),
    // Authoritative geofence state; locationAt is server receipt time of the
    // last trusted sample. Raw client timestamps are never stored.
    latitude: v.optional(nullableNumber),
    longitude: v.optional(nullableNumber),
    headingDegrees: v.optional(nullableNumber),
    locationAccuracyMeters: v.optional(nullableNumber),
    locationAt: v.optional(nullableNumber),
    outsideStreak: v.optional(v.number()),
  })
    .index("by_match", ["matchId"])
    .index("by_match_and_device", ["matchId", "deviceIdHash"]),

  shots: defineTable({
    matchId: v.id("matches"),
    shooterId: v.id("players"),
    targetId: v.union(v.id("players"), v.null()),
    clientShotId: v.string(),
    zone: v.union(hitZone, v.null()),
    damage: v.number(),
    outcome: shotOutcome,
    rejectReason: v.union(v.string(), v.null()),
    poseConfidence: nullableNumber,
    firedAtClient: v.number(),
    mode: v.optional(v.union(v.literal("debug"), v.literal("fire"))),
    claimFingerprint: v.optional(v.string()),
    shooterAmmo: v.optional(v.number()),
    targetHealth: v.optional(nullableNumber),
    targetLifeState: v.optional(v.union(lifeState, v.null())),
    eventId: v.optional(v.union(v.id("events"), v.null())),
    createdAt: v.number(),
  })
    .index("by_match_and_created_at", ["matchId", "createdAt"])
    .index("by_shooter_and_client_shot_id", ["shooterId", "clientShotId"]),

  events: defineTable({
    matchId: v.id("matches"),
    type: v.union(
      v.literal("joined"),
      v.literal("ready"),
      v.literal("started"),
      v.literal("shot"),
      v.literal("hit"),
      v.literal("eliminated"),
      v.literal("respawned"),
      v.literal("out_of_zone"),
      v.literal("finished"),
    ),
    actorPlayerId: v.union(v.id("players"), v.null()),
    targetPlayerId: v.union(v.id("players"), v.null()),
    zone: v.union(hitZone, v.null()),
    damage: nullableNumber,
    message: v.string(),
    createdAt: v.number(),
  }).index("by_match_and_created_at", ["matchId", "createdAt"]),
});
