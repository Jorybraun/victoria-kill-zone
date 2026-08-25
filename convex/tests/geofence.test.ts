import { describe, expect, it } from "vitest";
import geofenceFixture from "../../contracts/fixtures/geofence.v1.json";
import {
  ARENA_HYSTERESIS_METERS,
  ARENA_UNCERTAIN_GRACE_MS,
  CONSECUTIVE_OUTSIDE_SAMPLES,
  LOCATION_FRESHNESS_MS,
  MAX_TRUSTED_LOCATION_ACCURACY_METERS,
  applyLocationSample,
  arenaRelativePosition,
  classifyLocationSample,
  effectiveArenaState,
  fireLocationGate,
  haversineMeters,
  initialLocationState,
  isWellFormedLocationSample,
  type ArenaGeometry,
  type FireLocationGate,
  type LocationSample,
  type LocationState,
} from "../domain/geofence.js";
import type { ArenaState } from "../domain/types.js";

/**
 * Frozen authority for expected states: contracts/fixtures/geofence.v1.json
 * (KIL-25). Every vector below must pass unchanged; a failing vector means the
 * evaluator is wrong, never the fixture.
 */
interface GeofenceFixture {
  contractVersion: string;
  constants: {
    locationFreshnessMs: number;
    maxTrustedLocationAccuracyMeters: number;
    arenaHysteresisMeters: number;
    arenaUncertainGraceMs: number;
    consecutiveOutsideSamplesToExit: number;
  };
  arena: ArenaGeometry;
  geofenceVectors: GeofenceVector[];
}

interface GeofenceVector {
  id: string;
  description: string;
  arenaOverride?: ArenaGeometry;
  steps: GeofenceStep[];
}

interface GeofenceStep {
  atMs: number;
  sample?: LocationSample;
  expectedError?: "INVALID_LOCATION";
  expectedArenaState: ArenaState;
  expectedFire: { allowed?: boolean; rejectReason?: "OUT_OF_ARENA" | "LOCATION_STALE" };
}

const fixture = geofenceFixture as unknown as GeofenceFixture;

const GATE_BY_REJECT: Record<"OUT_OF_ARENA" | "LOCATION_STALE", FireLocationGate> = {
  OUT_OF_ARENA: "out_of_arena",
  LOCATION_STALE: "location_stale",
};

/** A trusted sample `meters` east of the fixture arena center. */
function sampleEastOf(meters: number, atMs: number, accuracyMeters = 5): LocationSample {
  // 1 degree of longitude at the equator ~ 111195.08 m with the module radius.
  return {
    latitude: 0,
    longitude: meters / 111_195.08,
    accuracyMeters,
    capturedAtClient: atMs,
  };
}

describe("geofence.v1 frozen constants", () => {
  it("matches the fixture exactly", () => {
    expect(fixture.contractVersion).toBe("geofence.v1");
    expect(LOCATION_FRESHNESS_MS).toBe(fixture.constants.locationFreshnessMs);
    expect(MAX_TRUSTED_LOCATION_ACCURACY_METERS).toBe(
      fixture.constants.maxTrustedLocationAccuracyMeters,
    );
    expect(ARENA_HYSTERESIS_METERS).toBe(fixture.constants.arenaHysteresisMeters);
    expect(ARENA_UNCERTAIN_GRACE_MS).toBe(fixture.constants.arenaUncertainGraceMs);
    expect(CONSECUTIVE_OUTSIDE_SAMPLES).toBe(fixture.constants.consecutiveOutsideSamplesToExit);
  });
});

describe("geofence.v1 fixture vectors", () => {
  it.each(fixture.geofenceVectors.map((vector) => [vector.id, vector] as const))(
    "%s",
    (_id, vector) => {
      const arena = vector.arenaOverride ?? fixture.arena;
      let state = initialLocationState();

      for (const step of vector.steps) {
        if (step.sample !== undefined) {
          if (step.expectedError === "INVALID_LOCATION") {
            // The Convex adapter throws INVALID_LOCATION for a malformed
            // sample before any write; the stored state never changes.
            expect(isWellFormedLocationSample(step.sample)).toBe(false);
            expect(classifyLocationSample(step.sample, step.atMs)).toBe("malformed");
          } else {
            state = applyLocationSample(arena, state, step.sample, step.atMs);
          }
        }

        expect(effectiveArenaState(state, step.atMs)).toBe(step.expectedArenaState);

        const gate = fireLocationGate(state, step.atMs);
        if (step.expectedFire.allowed === true) {
          expect(gate).toBeNull();
        } else {
          expect(step.expectedFire.rejectReason).toBeDefined();
          expect(gate).toBe(GATE_BY_REJECT[step.expectedFire.rejectReason ?? "LOCATION_STALE"]);
        }
      }
    },
  );

  it("covers every frozen vector id", () => {
    expect(fixture.geofenceVectors.map((vector) => vector.id).sort()).toEqual(
      [
        "geofence.antimeridian-inside",
        "geofence.boundary-jitter-stays-inside",
        "geofence.initial-state-uncertain",
        "geofence.invalid-sample-rejected",
        "geofence.re-entry-restores-fire",
        "geofence.stale-after-freshness-window",
        "geofence.trusted-inside-unlocks-fire",
        "geofence.two-consecutive-outside-locks-fire",
        "geofence.untrusted-accuracy-rejected-sample",
      ].sort(),
    );
  });
});

describe("haversine distance", () => {
  it("measures the short arc across the antimeridian in both directions", () => {
    const east = haversineMeters(0, 179.9999, 0, -179.999955);
    const west = haversineMeters(0, -179.999955, 0, 179.9999);
    expect(east).toBeCloseTo(16.1, 0);
    expect(west).toBeCloseTo(east, 6);
    // A naive longitude subtraction would measure nearly the full circumference.
    expect(east).toBeLessThan(30);
  });

  it("is zero for identical points and symmetric elsewhere", () => {
    expect(haversineMeters(48.4284, -123.3656, 48.4284, -123.3656)).toBe(0);
    const forward = haversineMeters(48.4284, -123.3656, 48.4287, -123.366);
    const backward = haversineMeters(48.4287, -123.366, 48.4284, -123.3656);
    expect(forward).toBeCloseTo(backward, 9);
    expect(forward).toBeGreaterThan(30);
    expect(forward).toBeLessThan(60);
  });
});

describe("sample trust classification", () => {
  const at = 10_000;

  it("rejects non-finite and out-of-range values as malformed", () => {
    const good = sampleEastOf(10, at);
    expect(isWellFormedLocationSample(good)).toBe(true);
    for (const bad of [
      { ...good, latitude: Number.NaN },
      { ...good, latitude: Number.POSITIVE_INFINITY },
      { ...good, latitude: 90.0001 },
      { ...good, latitude: -90.0001 },
      { ...good, longitude: Number.NaN },
      { ...good, longitude: 180.0001 },
      { ...good, longitude: -180.0001 },
      { ...good, accuracyMeters: Number.NaN },
      { ...good, accuracyMeters: -1 },
      { ...good, capturedAtClient: Number.NaN },
      { ...good, headingDegrees: Number.NaN },
      { ...good, headingDegrees: -1 },
      { ...good, headingDegrees: 360.5 },
    ]) {
      expect(isWellFormedLocationSample(bad)).toBe(false);
      expect(classifyLocationSample(bad, at)).toBe("malformed");
    }
  });

  it("distrusts accuracy above 20 m and excessive client clock skew", () => {
    expect(classifyLocationSample(sampleEastOf(10, at, 20), at)).toBe("trusted");
    expect(classifyLocationSample(sampleEastOf(10, at, 20.01), at)).toBe("untrusted");
    const skewed = { ...sampleEastOf(10, at), capturedAtClient: at - LOCATION_FRESHNESS_MS - 1 };
    expect(classifyLocationSample(skewed, at)).toBe("untrusted");
    const future = { ...sampleEastOf(10, at), capturedAtClient: at + LOCATION_FRESHNESS_MS + 1 };
    expect(classifyLocationSample(future, at)).toBe("untrusted");
  });

  it("never lets a malformed sample update stored state", () => {
    const inside = applyLocationSample(fixture.arena, initialLocationState(), sampleEastOf(10, 1_000), 1_000);
    const afterMalformed = applyLocationSample(
      fixture.arena,
      inside,
      { ...sampleEastOf(10, 2_000), latitude: Number.NaN },
      2_000,
    );
    // Defence in depth: coordinates and locationAt are untouched; only the
    // recently-inside degradation to warning may apply.
    expect(afterMalformed.latitude).toBe(inside.latitude);
    expect(afterMalformed.longitude).toBe(inside.longitude);
    expect(afterMalformed.locationAt).toBe(1_000);
    expect(afterMalformed.arenaState).toBe("warning");
  });
});

describe("fence transitions beyond the fixture vectors", () => {
  function insideAt(atMs: number): LocationState {
    return applyLocationSample(fixture.arena, initialLocationState(), sampleEastOf(10, atMs), atMs);
  }

  it("starts uncertain with omitted location fields", () => {
    expect(initialLocationState()).toEqual({
      arenaState: "uncertain",
      latitude: null,
      longitude: null,
      headingDegrees: null,
      accuracyMeters: null,
      locationAt: null,
      outsideStreak: 0,
    });
  });

  it("never counts boundary jitter inside radius + 5 m as an outside sample", () => {
    let state = insideAt(1_000);
    for (let step = 1; step <= 10; step += 1) {
      const atMs = 1_000 + step * 1_000;
      // 34.9 m from a 30 m arena: beyond the radius, inside the exit band.
      state = applyLocationSample(fixture.arena, state, sampleEastOf(34.9, atMs), atMs);
      expect(state.arenaState).toBe("inside");
      expect(state.outsideStreak).toBe(0);
    }
  });

  it("resets the outside streak when a band sample interrupts it", () => {
    let state = insideAt(1_000);
    state = applyLocationSample(fixture.arena, state, sampleEastOf(40, 2_000), 2_000);
    expect(state.outsideStreak).toBe(1);
    expect(state.arenaState).toBe("inside");
    state = applyLocationSample(fixture.arena, state, sampleEastOf(33, 3_000), 3_000);
    expect(state.outsideStreak).toBe(0);
    expect(state.arenaState).toBe("inside");
    state = applyLocationSample(fixture.arena, state, sampleEastOf(40, 4_000), 4_000);
    expect(state.arenaState).toBe("inside");
    state = applyLocationSample(fixture.arena, state, sampleEastOf(40, 5_000), 5_000);
    expect(state.arenaState).toBe("outside");
  });

  it("holds warning for exactly the 5000 ms grace, then uncertain", () => {
    const inside = insideAt(1_000);
    const degraded = applyLocationSample(fixture.arena, inside, sampleEastOf(10, 3_000, 45), 3_000);
    expect(degraded.arenaState).toBe("warning");
    // Untrusted samples never update the authoritative coordinates or clock.
    expect(degraded.locationAt).toBe(1_000);
    expect(degraded.accuracyMeters).toBe(5);
    expect(effectiveArenaState(degraded, 1_000 + ARENA_UNCERTAIN_GRACE_MS)).toBe("warning");
    expect(effectiveArenaState(degraded, 1_000 + ARENA_UNCERTAIN_GRACE_MS + 1)).toBe("uncertain");
    expect(fireLocationGate(degraded, 1_000 + ARENA_UNCERTAIN_GRACE_MS)).toBeNull();
    expect(fireLocationGate(degraded, 1_000 + ARENA_UNCERTAIN_GRACE_MS + 1)).toBe("location_stale");
  });

  it("expires a fresh inside state exactly at the freshness window", () => {
    const inside = insideAt(1_000);
    expect(effectiveArenaState(inside, 1_000 + LOCATION_FRESHNESS_MS)).toBe("inside");
    expect(fireLocationGate(inside, 1_000 + LOCATION_FRESHNESS_MS)).toBeNull();
    expect(effectiveArenaState(inside, 1_000 + LOCATION_FRESHNESS_MS + 1)).toBe("uncertain");
    expect(fireLocationGate(inside, 1_000 + LOCATION_FRESHNESS_MS + 1)).toBe("location_stale");
  });

  it("keeps outside sticky through staleness until a trusted re-entry", () => {
    let state = initialLocationState();
    state = applyLocationSample(fixture.arena, state, sampleEastOf(40, 1_000), 1_000);
    state = applyLocationSample(fixture.arena, state, sampleEastOf(40, 2_000), 2_000);
    expect(state.arenaState).toBe("outside");
    // Staleness never upgrades an outside player back to firing eligibility.
    expect(effectiveArenaState(state, 60_000)).toBe("outside");
    expect(fireLocationGate(state, 60_000)).toBe("out_of_arena");
    const reentered = applyLocationSample(fixture.arena, state, sampleEastOf(20, 61_000), 61_000);
    expect(reentered.arenaState).toBe("inside");
    expect(reentered.outsideStreak).toBe(0);
    expect(fireLocationGate(reentered, 61_000)).toBeNull();
  });

  it("never derives inside without arena geometry (centerless match keeps fire locked)", () => {
    const state = applyLocationSample(null, initialLocationState(), sampleEastOf(10, 1_000), 1_000);
    expect(state.arenaState).toBe("uncertain");
    expect(state.latitude).toBe(0);
    expect(state.locationAt).toBe(1_000);
    expect(fireLocationGate(state, 1_000)).toBe("location_stale");
  });
});

describe("public arena-relative projection", () => {
  it("projects east/north metres rounded to a decimetre", () => {
    const position = arenaRelativePosition({ latitude: 0, longitude: 0 }, 0.000089932, 0.000179864, 45);
    expect(position).toEqual({ eastMeters: 20, northMeters: 10, headingDegrees: 45 });
  });

  it("omits heading when unknown and projects the short way across the antimeridian", () => {
    const position = arenaRelativePosition({ latitude: 0, longitude: 179.9999 }, 0, -179.999955, null);
    expect(position.eastMeters).toBeCloseTo(16.1, 1);
    expect(position.northMeters).toBe(0);
    expect(position).not.toHaveProperty("headingDegrees");
  });
});
