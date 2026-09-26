import { randomBytes, bytesToHex } from "@noble/hashes/utils.js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { validateCombatRules } from "@vkz/combat-protocol";
import { ticket } from "../functions/combat.js";
import { mutationContext, mutationHandler, storedMatch, storedPlayer, testIds } from "./mutation-context.js";
import { T0 } from "./factories.js";
import fixtureJson from "../../contracts/fixtures/combat.v1.json";

const fixture = fixtureJson as unknown as {
  protocolVersion: number;
  snapshot: {message: {snapshot: {rules: unknown}}};
};
const decode = (value: string) => Uint8Array.from(atob(value.replace(/-/g,"+").replace(/_/g,"/")), c => c.charCodeAt(0));
beforeEach(() => {
  vi.spyOn(Date,"now").mockReturnValue(T0 + 1000);
  vi.stubEnv("COMBAT_TICKET_SECRET", bytesToHex(randomBytes(32)));
  vi.stubEnv("COMBAT_WORKER_URL", "https://combat.example.test");
});
afterEach(() => {vi.restoreAllMocks(); vi.unstubAllEnvs();});

describe("combat.v1 contract fixture", () => {
  it("keeps the fixture snapshot rules valid under the admission validator", () => {
    expect(validateCombatRules(fixture.snapshot.message.snapshot.rules)).toBe(true);
  });
  it("mints tickets stamped with the fixture protocol version", async () => {
    const b = mutationContext();
    const host = storedPlayer(testIds.host,{ready:true}), guest = storedPlayer(testIds.guest,{ready:true});
    b.seed("players",host.doc); b.seed("players",guest.doc);
    b.seed("matches",storedMatch({status:"active",combatMode:"durableObject",combatPreparedAt:T0,maxPlayers:4,
      combatRulesJson:JSON.stringify(fixture.snapshot.message.snapshot.rules)}));
    const issued = await mutationHandler(ticket)(b.ctx,{matchId:testIds.match,playerId:testIds.host,sessionSecret:host.sessionSecret});
    const claims: unknown = JSON.parse(new TextDecoder().decode(decode(issued.ticket.split(".")[1] ?? "")));
    expect(claims).toMatchObject({v: fixture.protocolVersion});
  });
});
