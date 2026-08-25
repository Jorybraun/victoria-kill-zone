import { describe, expect, it } from "vitest";
import { arenaGeometryOf, errorCodeForRejectReason } from "../functions/lib/state.js";
import type { Doc } from "../functions/lib/server.js";

describe("markerless fire reject mapping", () => {
  it("preserves non-match business reasons on the public wire", () => {
    expect(errorCodeForRejectReason("out_of_ammo")).toBe("OUT_OF_AMMO");
    expect(errorCodeForRejectReason("cooldown_active")).toBe("FIRE_COOLDOWN");
    expect(errorCodeForRejectReason("shooter_not_alive")).toBe("SHOOTER_NOT_ALIVE");
    expect(errorCodeForRejectReason("target_not_alive")).toBe("TARGET_NOT_ALIVE");
  });

  it("maps the geofence gates to the frozen wire reject codes", () => {
    expect(errorCodeForRejectReason("out_of_arena")).toBe("OUT_OF_ARENA");
    expect(errorCodeForRejectReason("location_stale")).toBe("LOCATION_STALE");
  });
});

describe("arena geometry resolution", () => {
  function matchDoc(arenaCenterAt: number | null | undefined): Doc<"matches"> {
    return {
      centerLatitude: 48.4284,
      centerLongitude: -123.3656,
      radiusMeters: 30,
      ...(arenaCenterAt === undefined ? {} : { arenaCenterAt }),
    } as unknown as Doc<"matches">;
  }

  it("resolves geometry only for a match with a recorded arenaCenter", () => {
    expect(arenaGeometryOf(matchDoc(1_700_000_000_000))).toEqual({
      latitude: 48.4284,
      longitude: -123.3656,
      radiusMeters: 30,
    });
    // Legacy centerless matches (pre-geofence rows and the G2 create shape)
    // have no enforceable fence and stay exempt.
    expect(arenaGeometryOf(matchDoc(null))).toBeNull();
    expect(arenaGeometryOf(matchDoc(undefined))).toBeNull();
  });
});
