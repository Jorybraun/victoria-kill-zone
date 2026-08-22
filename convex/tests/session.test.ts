import { describe, expect, it } from "vitest";
import { authenticates, digestsMatch, hashSecret } from "../domain/session.js";

const SECRET = "d3adbeefd3adbeefd3adbeefd3adbeef";

describe("hashSecret", () => {
  it("is deterministic and never contains the plaintext secret", () => {
    const digest = hashSecret(SECRET);

    expect(digest).toBe(hashSecret(SECRET));
    expect(digest).toHaveLength(64);
    expect(digest).not.toContain(SECRET);
  });

  it("separates two secrets", () => {
    expect(hashSecret(SECRET)).not.toBe(hashSecret(`${SECRET}0`));
  });
});

describe("authenticates", () => {
  it("accepts only the owning player's secret", () => {
    const hostHash = hashSecret(SECRET);
    const guestHash = hashSecret("0123456789abcdef0123456789abcdef");

    expect(authenticates(SECRET, hostHash)).toBe(true);
    expect(authenticates(SECRET, guestHash)).toBe(false);
  });

  it("rejects empty input on either side", () => {
    expect(authenticates("", hashSecret(SECRET))).toBe(false);
    expect(authenticates(SECRET, "")).toBe(false);
  });
});

describe("digestsMatch", () => {
  it("compares equal-length digests only", () => {
    expect(digestsMatch("abc", "abc")).toBe(true);
    expect(digestsMatch("abc", "abd")).toBe(false);
    expect(digestsMatch("abc", "ab")).toBe(false);
  });
});
