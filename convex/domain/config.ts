import type { HitZone } from "./types.js";

/**
 * Gameplay configuration is server-owned. Clients never submit damage, health,
 * ammunition, cooldown, or duration values; they are resolved from here.
 */
export const GAMEPLAY = {
  maxPlayers: 2,
  startingHealth: 100,
  magazineSize: 8,
  fireCooldownMs: 350,
  reloadDurationMs: 1250,
  respawnDelayMs: 5000,
  matchDurationMs: 180_000,
  defaultArenaRadiusMeters: 30,
  minArenaRadiusMeters: 20,
  maxArenaRadiusMeters: 60,
  matchCodeLength: 6,
  maxDisplayNameLength: 24,
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
  const trimmed = displayName.trim().slice(0, GAMEPLAY.maxDisplayNameLength);
  return trimmed.length > 0 ? trimmed : fallback;
}
