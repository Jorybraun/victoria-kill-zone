import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

const matchStatus = v.union(
  v.literal("setup"),
  v.literal("waiting"),
  v.literal("active"),
  v.literal("ended"),
);

const lifeState = v.union(
  v.literal("alive"),
  v.literal("dead"),
  v.literal("respawning"),
  v.literal("disconnected"),
);

const hitZone = v.union(v.literal("head"), v.literal("torso"), v.literal("limbs"));

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
    hostPlayerId: v.union(v.id("players"), v.null()),
    centerLatitude: v.number(),
    centerLongitude: v.number(),
    radiusMeters: v.number(),
    maxPlayers: v.number(),
    durationMs: v.number(),
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
    deviceIdHash: v.string(),
    sessionHash: v.string(),
    role: v.union(v.literal("host"), v.literal("guest")),
    connected: v.boolean(),
    lifeState,
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
    createdAt: v.number(),
  })
    .index("by_match_and_created_at", ["matchId", "createdAt"])
    .index("by_shooter_and_client_shot_id", ["shooterId", "clientShotId"]),

  events: defineTable({
    matchId: v.id("matches"),
    type: v.union(
      v.literal("joined"),
      v.literal("started"),
      v.literal("shot"),
      v.literal("hit"),
      v.literal("eliminated"),
      v.literal("respawned"),
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
