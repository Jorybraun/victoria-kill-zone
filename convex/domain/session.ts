import { sha256 } from "@noble/hashes/sha2.js";
import { bytesToHex, utf8ToBytes } from "@noble/hashes/utils.js";

/**
 * Match-scoped session handling (ADR 0002).
 *
 * The *server* generates a random 256-bit secret, returns it exactly once from a
 * successful create or join, and stores only its SHA-256 digest. The phone keeps
 * the secret in the Keychain and sends it with every player-controlled mutation.
 * No secret, digest, or device identifier is ever returned by a query or event.
 */

/** Deterministic, Convex-runtime-safe SHA-256 (no Node `crypto` dependency). */
export function hashSecret(secret: string): string {
  return bytesToHex(sha256(utf8ToBytes(secret)));
}

/** Length-safe, constant-time comparison of two lowercase hex digests. */
export function digestsMatch(left: string, right: string): boolean {
  if (left.length !== right.length) {
    return false;
  }

  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }

  return difference === 0;
}

/**
 * A supplied secret authenticates a player only when it hashes to that exact
 * player's stored digest, so one player's secret can never drive the opponent.
 */
export function authenticates(suppliedSecret: string, storedHash: string): boolean {
  if (suppliedSecret.length === 0 || storedHash.length === 0) {
    return false;
  }

  return digestsMatch(hashSecret(suppliedSecret), storedHash);
}
