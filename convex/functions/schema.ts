import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

/**
 * Authoritative storage for the G2 slice.
 *
 * Session material lives only in `players.sessionHash` (a SHA-256 digest) and
 * is never projected into a snapshot or event. No device identifier, location,
 * or targeting evidence is stored in this slice.
 */
export default defineSchema({
  matches: defineTable({
    code: v.string(),
    phase: v.union(
      v.literal("lobby"),
      v.literal("countdown"),
      v.literal("running"),
      v.literal("finished"),
      v.literal("cancelled"),
    ),
    arenaRadiusMeters: v.number(),
    durationMs: v.number(),
    startsAt: v.optional(v.number()),
    endsAt: v.optional(v.number()),
    createdAt: v.number(),
  }).index("by_code", ["code"]),

  players: defineTable({
    matchId: v.id("matches"),
    displayName: v.string(),
    role: v.union(v.literal("host"), v.literal("guest")),
    ready: v.boolean(),
    connected: v.boolean(),
    health: v.number(),
    ammo: v.number(),
    /** SHA-256 of the server-issued session secret; never returned to a client. */
    sessionHash: v.string(),
    /** Server receipt time of the newest heartbeat; owns `connected`. */
    lastSeenAt: v.number(),
    joinedAt: v.number(),
  })
    .index("by_match", ["matchId"])
    .index("by_match_role", ["matchId", "role"]),

  shots: defineTable({
    matchId: v.id("matches"),
    shooterId: v.id("players"),
    targetId: v.id("players"),
    /** Client-supplied idempotency key, unique per press per shooter. */
    clientShotId: v.string(),
    zone: v.literal("torso"),
    damage: v.number(),
    shooterAmmo: v.number(),
    targetHealth: v.number(),
    eventId: v.optional(v.id("events")),
    createdAt: v.number(),
  })
    .index("by_shooter_client_shot", ["shooterId", "clientShotId"])
    .index("by_match", ["matchId", "createdAt"]),

  events: defineTable({
    matchId: v.id("matches"),
    type: v.union(
      v.literal("joined"),
      v.literal("ready"),
      v.literal("started"),
      v.literal("hit"),
    ),
    message: v.string(),
    actorPlayerId: v.optional(v.id("players")),
    targetPlayerId: v.optional(v.id("players")),
    zone: v.optional(v.literal("torso")),
    damage: v.optional(v.number()),
    createdAt: v.number(),
  }).index("by_match", ["matchId", "createdAt"]),
});
