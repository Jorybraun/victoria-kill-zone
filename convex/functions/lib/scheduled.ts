import { makeFunctionReference } from "convex/server";
import type { Id } from "./server.js";

/**
 * References to the backend's own internal scheduled mutations.
 *
 * The Convex CLI normally emits these in `_generated/api`, which this slice
 * deliberately does not ship. Referencing them by registered name keeps
 * scheduling typed without a deployment, and avoids importing the modules they
 * belong to from the modules that schedule them.
 *
 * Every job carries the timestamp it was scheduled for, so a duplicate, early,
 * or stale run is a no-op instead of a phase or presence regression.
 */
export const scheduled = {
  activate: makeFunctionReference<
    "mutation",
    { matchId: Id<"matches">; expectedStartsAt: number },
    null
  >("matches:activate"),
  finish: makeFunctionReference<
    "mutation",
    { matchId: Id<"matches">; expectedEndsAt: number },
    null
  >("matches:finish"),
  expirePresence: makeFunctionReference<
    "mutation",
    { playerId: Id<"players">; expectedLastSeenAt: number },
    null
  >("players:expirePresence"),
};
