import { describe, expect, it } from "vitest";
import {
  authenticates,
  digestsMatch,
  hashSecret,
  isValidSessionSecret,
  sessionSecretFromBytes,
} from "../domain/session.js";

const SECRET_A = "a".repeat(64);
const SECRET_B = "b".repeat(64);

describe("match-scoped sessions", () => {
  it("issues exactly 256 bits as lowercase hexadecimal", () => {
    const secret = sessionSecretFromBytes(new Uint8Array(32).fill(171));
    expect(secret).toHaveLength(64);
    expect(secret).toMatch(/^[0-9a-f]{64}$/);
    expect(isValidSessionSecret(secret)).toBe(true);
    expect(() => sessionSecretFromBytes(new Uint8Array(31))).toThrow();
  });

  it("hashes deterministically with a stable hex digest", () => {
    expect(hashSecret(SECRET_A)).toBe(hashSecret(SECRET_A));
    expect(hashSecret(SECRET_A)).toMatch(/^[0-9a-f]{64}$/);
    expect(hashSecret("abc")).toBe(
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    );
  });

  it("authenticates only the player that owns the secret", () => {
    const hostHash = hashSecret(SECRET_A);
    const guestHash = hashSecret(SECRET_B);

    expect(authenticates(SECRET_A, hostHash)).toBe(true);
    expect(authenticates(SECRET_A, guestHash)).toBe(false);
    expect(authenticates(SECRET_B, hostHash)).toBe(false);
  });

  it("rejects empty secrets, empty digests, and length mismatches", () => {
    expect(authenticates("", hashSecret(SECRET_A))).toBe(false);
    expect(authenticates(SECRET_A, "")).toBe(false);
    expect(digestsMatch(hashSecret(SECRET_A), hashSecret(SECRET_A).slice(0, 32))).toBe(false);
    expect(digestsMatch(hashSecret(SECRET_A), hashSecret(SECRET_A))).toBe(true);
  });

  it("never exposes the secret through its digest", () => {
    expect(hashSecret(SECRET_A)).not.toContain(SECRET_A);
  });
});
