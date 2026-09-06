import { createHash } from "node:crypto";

/** A fixed-size digest avoids retaining each full 11 KiB pose payload 512 times.
 * Canonicalization remains at the caller; this never replaces ticket authentication.
 */
export function commandFingerprint(canonicalCommand: string): string {
  return `sha256:${createHash("sha256").update(canonicalCommand).digest("hex")}`;
}

/** Older rooms retained the canonical JSON itself; exact replay still works. */
export function matchesFingerprint(stored: string, digest: string, canonicalCommand: string): boolean {
  return stored === digest || (stored.startsWith("{") && stored === canonicalCommand);
}
