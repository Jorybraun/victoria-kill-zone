import {createHash} from "node:crypto";
import {describe, expect, it} from "vitest";
import {DEFAULT_RULES, PROTOCOL_VERSION, REFUSAL_REASONS, parseClientMessage, rulesSchemaKeyPaths, validateCombatRules} from "../src/index.js";
import fixtureJson from "../../../contracts/fixtures/combat.v1.json";
import manifest from "../../../release-manifest.json";

const fixture = fixtureJson as unknown as {
  contract: string; protocolVersion: number;
  envelopes: {id: string; message: unknown}[];
  rejected: {id: string; message: unknown}[];
  refusalReasons: string[];
  snapshot: {id: string; message: {type: string; eventSequence: number; clientSequence: number; snapshot: {rules: unknown}}};
};

describe("combat.v1 contract fixture", () => {
  it("round-trips every command envelope through parseClientMessage", () => {
    for (const entry of fixture.envelopes) {
      expect(parseClientMessage(JSON.stringify(entry.message)), entry.id).toEqual(entry.message);
    }
  });
  it("rejects every tampered message", () => {
    for (const entry of fixture.rejected) {
      expect(parseClientMessage(JSON.stringify(entry.message)), entry.id).toBeFalsy();
    }
  });
  it("freezes the refusal reason catalog", () => {
    expect([...fixture.refusalReasons].sort()).toEqual([...REFUSAL_REASONS].sort());
  });
  it("pins the protocol version in the fixture and release manifest", () => {
    expect(fixture.protocolVersion).toBe(PROTOCOL_VERSION);
    expect(manifest.protocolVersion).toBe(PROTOCOL_VERSION);
  });
  it("keeps the snapshot rules valid", () => {
    expect(validateCombatRules(fixture.snapshot.message.snapshot.rules)).toBe(true);
  });
  it("matches the manifest rules schema hash", () => {
    const hash = createHash("sha256").update(JSON.stringify(rulesSchemaKeyPaths(DEFAULT_RULES))).digest("hex");
    expect(hash).toBe(manifest.rulesSchemaHash);
  });
});
