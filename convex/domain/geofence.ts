import type { ArenaState } from "./types.js";

/**
 * Frozen phase0.v1 geofence contract (docs/interface-contracts.md).
 *
 * Everything in this module is pure and deterministic: it evaluates
 * server-received location samples against server-owned arena geometry and
 * derives the authoritative `ArenaState`. Convex adapters call these rules and
 * persist the returned state; nothing here reads a clock or the database.
 */
export const LOCATION_FRESHNESS_MS = 5_000;
export const MAX_TRUSTED_LOCATION_ACCURACY_METERS = 20;
export const ARENA_HYSTERESIS_METERS = 5;
export const ARENA_UNCERTAIN_GRACE_MS = 5_000;

/**
 * A sample whose client capture time differs from server receipt time by more
 * than this is untrusted. `capturedAtClient` is used only for this validation;
 * the server receipt time is the sole authoritative `locationAt`.
 */
export const MAX_CLIENT_CAPTURE_SKEW_MS = LOCATION_FRESHNESS_MS;

/** Mean Earth radius (IUGG) in metres. */
export const EARTH_RADIUS_METERS = 6_371_008.8;

/** Two trusted outside samples in a row are required before `outside`. */
export const CONSECUTIVE_OUTSIDE_SAMPLES = 2;

/** Wire shape of a phase0.v1 LocationSample. */
export interface LocationSample {
  latitude: number;
  longitude: number;
  accuracyMeters: number;
  capturedAtClient: number;
  headingDegrees?: number;
}

/** Server-owned arena geometry; `null` when the match has no captured center. */
export interface ArenaGeometry {
  latitude: number;
  longitude: number;
  radiusMeters: number;
}

/**
 * Authoritative per-player location state. `locationAt` is always the server
 * receipt time of the last trusted sample; client timestamps never enter it.
 */
export interface LocationState {
  arenaState: ArenaState;
  latitude: number | null;
  longitude: number | null;
  headingDegrees: number | null;
  accuracyMeters: number | null;
  locationAt: number | null;
  outsideStreak: number;
}

/** Players start `uncertain` with omitted location fields. */
export function initialLocationState(): LocationState {
  return {
    arenaState: "uncertain",
    latitude: null,
    longitude: null,
    headingDegrees: null,
    accuracyMeters: null,
    locationAt: null,
    outsideStreak: 0,
  };
}

/** Derive a `LocationState` from any record carrying the stored fields. */
export function locationStateFrom(player: {
  arenaState: ArenaState;
  latitude: number | null;
  longitude: number | null;
  headingDegrees: number | null;
  locationAccuracyMeters: number | null;
  locationAt: number | null;
  outsideStreak: number;
}): LocationState {
  return {
    arenaState: player.arenaState,
    latitude: player.latitude,
    longitude: player.longitude,
    headingDegrees: player.headingDegrees,
    accuracyMeters: player.locationAccuracyMeters,
    locationAt: player.locationAt,
    outsideStreak: player.outsideStreak,
  };
}

export type SampleValidity = "trusted" | "untrusted" | "malformed";

/**
 * Structural validity. A malformed sample is a protocol violation and makes
 * the mutation throw INVALID_LOCATION before any state change.
 */
export function isWellFormedLocationSample(sample: LocationSample): boolean {
  return (
    Number.isFinite(sample.latitude) &&
    sample.latitude >= -90 &&
    sample.latitude <= 90 &&
    Number.isFinite(sample.longitude) &&
    sample.longitude >= -180 &&
    sample.longitude <= 180 &&
    Number.isFinite(sample.accuracyMeters) &&
    sample.accuracyMeters >= 0 &&
    Number.isFinite(sample.capturedAtClient) &&
    (sample.headingDegrees === undefined ||
      (Number.isFinite(sample.headingDegrees) &&
        sample.headingDegrees >= 0 &&
        sample.headingDegrees <= 360))
  );
}

/**
 * Trust classification per the frozen contract: a trusted sample has valid
 * finite ranges, nonnegative accuracy at or under 20 m, and an acceptable
 * client-capture age/skew relative to server receipt time.
 */
export function classifyLocationSample(sample: LocationSample, receivedAt: number): SampleValidity {
  if (!isWellFormedLocationSample(sample)) {
    return "malformed";
  }
  if (sample.accuracyMeters > MAX_TRUSTED_LOCATION_ACCURACY_METERS) {
    return "untrusted";
  }
  if (Math.abs(receivedAt - sample.capturedAtClient) > MAX_CLIENT_CAPTURE_SKEW_MS) {
    return "untrusted";
  }
  return "trusted";
}

/**
 * Great-circle distance in metres. The haversine of the longitude delta is
 * periodic, so a crossing of the antimeridian (e.g. 179.9995° to −179.9995°)
 * resolves to the short arc, never the 360°-minus arc.
 */
export function haversineMeters(
  latitudeA: number,
  longitudeA: number,
  latitudeB: number,
  longitudeB: number,
): number {
  const phiA = toRadians(latitudeA);
  const phiB = toRadians(latitudeB);
  const deltaPhi = toRadians(latitudeB - latitudeA);
  const deltaLambda = toRadians(normalizeLongitudeDelta(longitudeB - longitudeA));
  const h =
    Math.sin(deltaPhi / 2) ** 2 +
    Math.cos(phiA) * Math.cos(phiB) * Math.sin(deltaLambda / 2) ** 2;
  return 2 * EARTH_RADIUS_METERS * Math.asin(Math.min(1, Math.sqrt(h)));
}

/**
 * Decay of stored state with no new sample:
 *
 * - No trusted sample ever recorded → `uncertain`.
 * - `inside` is authoritative only while the last trusted sample is fresh
 *   (≤ LOCATION_FRESHNESS_MS); afterwards the state is `uncertain`.
 * - `warning` holds for at most ARENA_UNCERTAIN_GRACE_MS measured from the
 *   last trusted sample, then becomes `uncertain`.
 * - `outside` is sticky: a stale outside player stays outside until a trusted
 *   sample re-enters the arena. Staleness never upgrades an outside player.
 */
export function effectiveArenaState(state: LocationState, now: number): ArenaState {
  if (state.locationAt === null) {
    return state.arenaState === "outside" ? "outside" : "uncertain";
  }
  switch (state.arenaState) {
    case "inside":
      return now - state.locationAt <= LOCATION_FRESHNESS_MS ? "inside" : "uncertain";
    case "warning":
      return now - state.locationAt <= ARENA_UNCERTAIN_GRACE_MS ? "warning" : "uncertain";
    case "outside":
      return "outside";
    case "uncertain":
      return "uncertain";
  }
}

/**
 * Apply one received location sample. Deterministic in
 * (arena, state, sample, now); the caller passes server receipt time as `now`.
 *
 * - A trusted sample updates the authoritative coordinates and `locationAt`
 *   and runs the fence transition below.
 * - An untrusted (degraded) sample never updates coordinates. It degrades a
 *   fresh `inside` to `warning`; every other state is left to decay through
 *   `effectiveArenaState`.
 * - A malformed sample is treated as untrusted here for defence in depth;
 *   adapters throw INVALID_LOCATION before reaching this point.
 *
 * Fence transition for a trusted sample at distance `d` from the center:
 * - `d ≤ radius` → `inside` (single trusted sample re-enters from any state).
 * - `radius < d ≤ radius + ARENA_HYSTERESIS_METERS` → hysteresis band: an
 *   inside/warning player stays `inside`, an outside player stays `outside`,
 *   an uncertain player stays `uncertain`. The band never counts toward the
 *   outside streak, so boundary jitter cannot flap the state.
 * - `d > radius + ARENA_HYSTERESIS_METERS` → outside candidate: the streak
 *   increments and the state flips to `outside` only at
 *   CONSECUTIVE_OUTSIDE_SAMPLES trusted candidates in a row; until then the
 *   previous effective state is kept.
 * - Without arena geometry the fence cannot be evaluated: coordinates are
 *   recorded but the state never becomes `inside` (fire stays locked).
 */
export function applyLocationSample(
  arena: ArenaGeometry | null,
  state: LocationState,
  sample: LocationSample,
  now: number,
): LocationState {
  const decayed: LocationState = { ...state, arenaState: effectiveArenaState(state, now) };

  if (classifyLocationSample(sample, now) !== "trusted") {
    if (decayed.arenaState === "inside") {
      return { ...decayed, arenaState: "warning" };
    }
    return decayed;
  }

  const measured: LocationState = {
    ...decayed,
    latitude: sample.latitude,
    longitude: sample.longitude,
    headingDegrees: sample.headingDegrees ?? null,
    accuracyMeters: sample.accuracyMeters,
    locationAt: now,
  };

  if (arena === null) {
    return {
      ...measured,
      arenaState: decayed.arenaState === "outside" ? "outside" : "uncertain",
      outsideStreak: 0,
    };
  }

  const distance = haversineMeters(
    arena.latitude,
    arena.longitude,
    sample.latitude,
    sample.longitude,
  );

  if (distance <= arena.radiusMeters) {
    return { ...measured, arenaState: "inside", outsideStreak: 0 };
  }

  if (distance <= arena.radiusMeters + ARENA_HYSTERESIS_METERS) {
    const banded: ArenaState =
      decayed.arenaState === "inside" || decayed.arenaState === "warning"
        ? "inside"
        : decayed.arenaState;
    return { ...measured, arenaState: banded, outsideStreak: 0 };
  }

  const outsideStreak = decayed.outsideStreak + 1;
  if (decayed.arenaState === "outside" || outsideStreak >= CONSECUTIVE_OUTSIDE_SAMPLES) {
    return { ...measured, arenaState: "outside", outsideStreak };
  }
  return { ...measured, outsideStreak };
}

/** Reject reasons a location gate can add to a fire attempt. */
export type FireLocationGate = "out_of_arena" | "location_stale";

/**
 * Authoritative fire lock. Fire is rejected while the shooter is outside
 * (OUT_OF_ARENA) or while the shooter's location is uncertain or stale
 * (LOCATION_STALE). A fresh `inside` or `warning` state allows fire.
 */
export function fireLocationGate(state: LocationState, now: number): FireLocationGate | null {
  const effective = effectiveArenaState(state, now);
  if (effective === "outside") {
    return "out_of_arena";
  }
  if (effective === "uncertain") {
    return "location_stale";
  }
  if (state.locationAt === null || now - state.locationAt > LOCATION_FRESHNESS_MS) {
    return "location_stale";
  }
  return null;
}

/** Sanitized public arena-relative position (SpectatorArenaPosition). */
export interface ArenaRelativePosition {
  eastMeters: number;
  northMeters: number;
  headingDegrees?: number;
}

/**
 * Local tangent-plane projection of a player position onto arena-relative
 * east/north metres. This is the only positional data the public spectator
 * projection may carry; raw coordinates never leave the backend. The
 * longitude delta is normalized so arenas beside the antimeridian project the
 * short way across it.
 */
export function arenaRelativePosition(
  center: Pick<ArenaGeometry, "latitude" | "longitude">,
  latitude: number,
  longitude: number,
  headingDegrees: number | null,
): ArenaRelativePosition {
  const metersPerDegree = (Math.PI / 180) * EARTH_RADIUS_METERS;
  const northMeters = (latitude - center.latitude) * metersPerDegree;
  const eastMeters =
    normalizeLongitudeDelta(longitude - center.longitude) *
    metersPerDegree *
    Math.cos(toRadians(center.latitude));
  return {
    eastMeters: roundToDecimeter(eastMeters),
    northMeters: roundToDecimeter(northMeters),
    ...(headingDegrees === null ? {} : { headingDegrees }),
  };
}

function toRadians(degrees: number): number {
  return (degrees * Math.PI) / 180;
}

function normalizeLongitudeDelta(deltaDegrees: number): number {
  return ((((deltaDegrees + 180) % 360) + 360) % 360) - 180;
}

function roundToDecimeter(meters: number): number {
  return Math.round(meters * 10) / 10;
}
