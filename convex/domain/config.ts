import type { HitZone } from "./types.js";

/**
 * Gameplay configuration is server-owned. Clients never submit damage, health,
 * ammunition, cooldown, or duration values; they are resolved from here.
 */
export const GAMEPLAY = {
  maxPlayers: 2,
  startingHealth: 100,
  magazineSize: 8,
  countdownMs: 3_000,
  fireCooldownMs: 150,
  presenceTimeoutMs: 15_000,
  reloadDurationMs: 1250,
  respawnDelayMs: 5000,
  matchDurationMs: 180_000,
  defaultArenaRadiusMeters: 30,
  minArenaRadiusMeters: 20,
  maxArenaRadiusMeters: 60,
  matchCodeLength: 6,
  maxDisplayNameLength: 20,
} as const;

export const ZONE_DAMAGE: Readonly<Record<HitZone, number>> = {
  head: 75,
  torso: 34,
  limbs: 20,
};

/** Server-owned damage for a claimed zone; client-supplied damage is ignored. */
export function damageForZone(zone: HitZone): number {
  return ZONE_DAMAGE[zone];
}

/** Clamp a host-selected arena radius into the supported range. */
export function normalizeArenaRadius(radiusMeters: number | undefined): number {
  if (radiusMeters === undefined || !Number.isFinite(radiusMeters)) {
    return GAMEPLAY.defaultArenaRadiusMeters;
  }

  return Math.min(
    GAMEPLAY.maxArenaRadiusMeters,
    Math.max(GAMEPLAY.minArenaRadiusMeters, Math.round(radiusMeters)),
  );
}

/** Trim a display name to a safe length, falling back to a neutral label. */
export function normalizeDisplayName(displayName: string, fallback: string): string {
  const trimmed = displayName.trim();
  return isValidDisplayName(trimmed) ? trimmed : fallback;
}

/** G2 display names are 1-20 Unicode scalar values after trimming. */
export function isValidDisplayName(displayName: string): boolean {
  const trimmed = displayName.trim();
  const scalarCount = Array.from(trimmed).length;
  return scalarCount >= 1 && scalarCount <= GAMEPLAY.maxDisplayNameLength;
}

/** Normalize typed/pasted G2 match codes while rejecting malformed input. */
export function normalizeMatchCode(code: string): string | null {
  const normalized = code.replace(/[-\t\n\r ]/g, "").toUpperCase();
  return /^[A-Z0-9]{6}$/.test(normalized) ? normalized : null;
}
