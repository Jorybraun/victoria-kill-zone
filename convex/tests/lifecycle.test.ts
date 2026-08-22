import { describe, expect, it } from "vitest";
import { canTransition, hasExpired, isJoinable, phaseForStatus, resolveWinner } from "../domain/lifecycle.js";
import { match, player, T0 } from "./factories.js";

describe("duel state machine", () => {
  it("allows only the documented transitions", () => {
    expect(canTransition("setup", "waiting")).toBe(true);
    expect(canTransition("waiting", "active")).toBe(true);
    expect(canTransition("active", "ended")).toBe(true);
    expect(canTransition("setup", "active")).toBe(false);
    expect(canTransition("ended", "active")).toBe(false);
    expect(canTransition("active", "waiting")).toBe(false);
  });

  it("projects each status onto the frozen phase vocabulary", () => {
    expect(phaseForStatus({ status: "setup", endReason: null })).toBe("lobby");
    expect(phaseForStatus({ status: "waiting", endReason: null })).toBe("lobby");
    expect(phaseForStatus({ status: "active", endReason: null })).toBe("running");
    expect(phaseForStatus({ status: "ended", endReason: "duration_elapsed" })).toBe("finished");
    expect(phaseForStatus({ status: "ended", endReason: "abandoned" })).toBe("cancelled");
  });

  it("only treats a duel in setup below the player limit as joinable", () => {
    expect(isJoinable({ status: "setup" }, 1, 2)).toBe(true);
    expect(isJoinable({ status: "setup" }, 2, 2)).toBe(false);
    expect(isJoinable({ status: "waiting" }, 1, 2)).toBe(false);
    expect(isJoinable({ status: "active" }, 1, 2)).toBe(false);
  });

  it("reports an active duel past endsAt as expired", () => {
    const active = match();
    expect(hasExpired(active, T0)).toBe(false);
    expect(hasExpired(active, T0 + active.durationMs - 1)).toBe(false);
    expect(hasExpired(active, T0 + active.durationMs)).toBe(true);
    expect(hasExpired(match({ status: "waiting", endsAt: null }), T0)).toBe(false);
  });
});

describe("winner resolution", () => {
  it("ranks by kills, then fewest deaths, then damage dealt", () => {
    expect(resolveWinner([player("a", { kills: 3 }), player("b", { kills: 2 })])).toBe("a");
    expect(
      resolveWinner([player("a", { kills: 2, deaths: 3 }), player("b", { kills: 2, deaths: 1 })]),
    ).toBe("b");
    expect(
      resolveWinner([
        player("a", { kills: 1, deaths: 1, damageDealt: 120 }),
        player("b", { kills: 1, deaths: 1, damageDealt: 300 }),
      ]),
    ).toBe("b");
  });

  it("returns null for a fully tied duel or an incomplete duel", () => {
    expect(resolveWinner([player("a"), player("b")])).toBeNull();
    expect(resolveWinner([player("a", { kills: 5 })])).toBeNull();
  });
});
