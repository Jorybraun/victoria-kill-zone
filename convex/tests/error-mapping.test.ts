import { describe, expect, it } from "vitest";
import { errorCodeForRejectReason } from "../functions/lib/state.js";

describe("markerless fire reject mapping", () => {
  it("preserves non-match business reasons on the public wire", () => {
    expect(errorCodeForRejectReason("out_of_ammo")).toBe("OUT_OF_AMMO");
    expect(errorCodeForRejectReason("cooldown_active")).toBe("FIRE_COOLDOWN");
    expect(errorCodeForRejectReason("shooter_not_alive")).toBe("SHOOTER_NOT_ALIVE");
    expect(errorCodeForRejectReason("target_not_alive")).toBe("TARGET_NOT_ALIVE");
  });
});
