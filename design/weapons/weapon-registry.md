# WeaponDefinition registry — weapons v1 design (KIL-39)

| Field | Value |
|---|---|
| Status | Proposed for KIL-39 review |
| Layer | L5 — Content systems ([docs/roadmap.md](../../docs/roadmap.md) §3) |
| Design owner | `design/**` |
| Scope | Registry schema, launch weapons, reload behavior, ammo economy, projectile relationship to L1, phasing |
| Authority inputs | [victoria-kill-zone-technical-spec.md](../../victoria-kill-zone-technical-spec.md) §5.2–5.4, [docs/interface-contracts.md](../../docs/interface-contracts.md) (shared constants, match.v2), ADR 0003, roadmap Phase 2 |
| Non-goals | Time semantics (ADR 0005), spatial vocabulary (spatial-hit.v1), any code or contract edit |

## Outcome

One registry drives every gun: server-owned numbers decide combat outcomes, client-owned keys decide presentation. The current build's implicit weapon becomes registry entry #1 unchanged, so shipping this design retroactively conforms the existing game without a behavior change. Reload is specified completely here, once.

## 1. Registry schema

Extends the technical spec's `WeaponDefinition` sketch (spec §5.4). One deliberate deviation: `roundsPerMinute: Double` becomes `fireCooldownMs: Int`, because the wire rules require exact-integer durations and the live constant is already `FIRE_COOLDOWN_MS = 350`.

| Field | Type | Rules |
|---|---|---|
| `id` | string | Stable lowercase-kebab key; opaque to clients; never reused after retirement |
| `bulletType` | `"hitscan" \| "projectile" \| "special"` | `special` is reserved (see §6); backend never emits it before ADR 0005 |
| `damageByZone` | `{ head, torso, limbs }` ints | Applied damage capped by remaining health, per phase0.v1 invariants |
| `fireCooldownMs` | int | Minimum ms between accepted shots; enforced against `lastShotAt` |
| `magazineSize` | int | Rounds per magazine; reload always refills to this value |
| `reloadDurationMs` | int | Per-weapon; replaces the single global `RELOAD_DURATION_MS` for v2 surfaces |
| `projectileSpeedMetersPerSecond` | number | Present iff `bulletType === "projectile"`; omitted otherwise (never null) |
| `projectileLifetimeMs` | int | Present iff projectile; worldline terminal bound when nothing is hit |
| `presentationKey` | string | Opaque key into the client presentation table below |

### Ownership split

| Server-owned (authoritative numbers) | Client-owned (presentation) |
|---|---|
| `id`, `bulletType`, `damageByZone`, `fireCooldownMs`, `magazineSize`, `reloadDurationMs`, `projectileSpeedMetersPerSecond`, `projectileLifetimeMs` | `displayName`, tracer/muzzle/impact effects, audio keys, haptic pattern, HUD icon — all resolved from `presentationKey` |

- Clients never send damage, cooldown, or speed values; the authority looks them up by `id`. A client with a stale registry renders wrong cosmetics at worst — never wrong outcomes.
- Changing a presentation asset never requires a backend change or contract revision.
- `displayName` is copy, not wire data; server events reference weapons by `id` only.

## 2. Launch weapons and pacing math

All pacing is against `INITIAL_HEALTH = 100`.

| # | id | displayName | bulletType | head / torso / limbs | fireCooldownMs | magazineSize | reloadDurationMs | projectile speed |
|---|---|---|---|---|---|---|---|---|
| 1 | `sidearm-mk1` | Standard Sidearm | hitscan | 75 / 34 / 20 | 350 | 8 | 1250 | — |
| 2 | `bolt-caster` | Bolt Caster | projectile | 100 / 60 / 40 | 900 | 3 | 2000 | 12 m/s, lifetime 2000 ms |
| 3 | `repeater` | Repeater | hitscan | 30 / 18 / 12 | 150 | 24 | 2000 | — |

`sidearm-mk1` is exactly the current implicit weapon: `HEAD_DAMAGE = 75`, `TORSO_DAMAGE = 34`, `LIMB_DAMAGE = 20`, `MAGAZINE_SIZE = 8`, `FIRE_COOLDOWN_MS = 350`, `RELOAD_DURATION_MS = 1250`. The current build is registry-conformant on the day this lands.

### Shots to kill (STK = ⌈100 / damage⌉)

| Weapon | Head | Torso | Limbs | Limb kill fits one magazine? |
|---|---|---|---|---|
| Standard Sidearm | 2 | 3 | 5 | Yes (5 ≤ 8) |
| Bolt Caster | 1 | 2 | 3 | Exactly (3 = 3) |
| Repeater | 4 | 6 | 9 | Yes (9 ≤ 24) |

### Time to kill (first shot at t = 0; TTK = (STK − 1) × fireCooldownMs; all shots land, same zone; projectile travel excluded and listed separately)

| Weapon | Head | Torso | Limbs |
|---|---|---|---|
| Standard Sidearm | 350 ms | 700 ms | 1400 ms |
| Bolt Caster | 0 ms + travel | 900 ms + travel | 1800 ms + travel |
| Repeater | 450 ms | 750 ms | 1200 ms |

Bolt Caster travel time over the 3–15 m play lane (slice 002) at 12 m/s: 250–1250 ms per bolt — comparable to human reaction time at range, which is what makes it dodgeable (§5).

### Sustained effective DPS (convention: full-magazine cycle = magazineSize × fireCooldownMs + reloadDurationMs; every round lands in the stated zone)

| Weapon | Cycle | Head DPS | Torso DPS | Limbs DPS |
|---|---|---|---|---|
| Standard Sidearm | 8×350 + 1250 = 4050 ms | 148.1 | 67.2 | 39.5 |
| Bolt Caster | 3×900 + 2000 = 4700 ms | 63.8 | 38.3 | 25.5 |
| Repeater | 24×150 + 2000 = 5600 ms | 128.6 | 77.1 | 51.4 |

### Design intent

| Weapon | Role | Trade |
|---|---|---|
| Standard Sidearm | Baseline; the current game | Best burst TTK on precision; a miss forfeits 34–75 potential damage |
| Bolt Caster | The fantasy weapon: visible, dodgeable, one-tap headshot | Worst sustain; 3-round magazine punishes misses hardest; target can dodge |
| Repeater | Forgiving spray | Worst per-zone burst TTK except limbs; best torso/limb sustain; a miss costs only 12–18 potential; 3.6 s uptime before reload |

If Phase 2 scope tightens, cut Repeater first: the gate (§6) needs one hitscan and one projectile, not three guns.

## 3. Reload — complete behavior (designed once, here)

The current scaffold is contract-only (`playersV2:startReload`, `reloadEndsAt`, `RELOADING`, `MAGAZINE_FULL`, `ALREADY_RELOADING`). This section is the full behavioral spec; no other document re-designs reload.

| Rule | Decision |
|---|---|
| Trigger | Player-initiated via `startReload`. No server-side auto-reload. |
| Client dry-fire policy | On a trigger press with 0 ammo, the client MAY auto-invoke `startReload` and MUST show a reload prompt. Client policy only; server behavior identical either way. |
| Validity | Alive, presence-fresh, in-arena, match running, `ammo < weapon.magazineSize`, no active reload. Violations: `MAGAZINE_FULL`, `ALREADY_RELOADING`, or the existing phase/life/arena errors. |
| Duration | `reloadEndsAt = serverNow + weapon.reloadDurationMs` (per-weapon, not the global constant). |
| Refill | Always to full `magazineSize`. No partial reloads, no per-round insertion. |
| While reloading | `shots:fire`/`shotsV2:fire` rejected with `RELOADING`. Movement, being targeted, and taking damage are unaffected. |
| Cancellation | Not cancellable by the player in weapons v1. |
| Death during reload | Elimination clears the reload; respawn restores full magazine and removes `reloadEndsAt` (existing respawn rule, unchanged). |
| Disconnect during reload | Reload completes on schedule via the guarded `internal.players:completeReload`; server time, not presence, owns completion. |
| Reload speed modifiers | None in weapons v1. |
| Weapon switching | No mid-match switching in weapons v1 (§4 loadout rule), so reload/switch interaction is out of scope by construction. |
| Presentation | Client shows a progress affordance derived from `reloadEndsAt − serverNow`; interpolation only, never authoritative (matches the match-clock rule). |

## 4. Ammo economy

**Decision: infinite reserve magazines with reloads for Phase 1/2. Ammo pickups are open-world (Phase 3) scope.**

| Consideration | Why infinite-with-reload wins for co-located 2–4 player park sessions |
|---|---|
| Match shape | 180 s matches; scarcity mechanics need longer arcs to matter |
| Pacing lever | Reload downtime (1.25–2 s, per-weapon) already creates vulnerability windows and rhythm; scarcity would add downtime without adding decisions |
| Infrastructure | Pickups require placing items in shared space — that is L3 spatial persistence plus safety design, neither of which exists yet (roadmap F6, Phase 3) |
| Social reality | Running dry permanently in a park game with friends is a bad time, not a strategy |
| Fairness | Everyone always has ammo; the only economies are aim, position, and reload timing |
| Loadout rule | Each player selects one weapon `id` in the lobby; the loadout is fixed for the match. Switching, drops, and pickups are all deferred together. |

Reserve-ammo fields, pickup entities, and drop mechanics are deliberately absent from the v1 schema; they are additive later.

## 5. Projectiles and the simulation core

Projectile weapons are content on top of the L1 worldline machinery (roadmap L1, ADR 0003, research H5). The registry adds numbers; it adds no simulation semantics.

- **Spawn parameters, never position streams.** A fire input yields `{ projectileId, weaponId, shooterId, origin, direction (unit), speedMetersPerSecond, spawnedAt (match clock) }`. Speed and lifetime come from the registry by `weaponId`.
- **Position is a pure function of time:** `position(t) = origin + direction × speed × (t − spawnedAt)`, valid until impact or `spawnedAt + projectileLifetimeMs`. Every device and the spectator reconstruct the same worldline locally from the spawn record.
- **Dodgeable by construction.** Travel across the 3–15 m lane at 12 m/s takes 250–1250 ms; a target who moves after the spawn record arrives can leave the worldline. This is the product thesis ("they travel, they can be dodged") made concrete.
- **Verdicts belong to the authority, never the shooter's client.** The `AuthorityHost` performs the swept collision test between the worldline and each targetable player's proxy pose history and emits the terminal verdict (hit + zone, miss, expired). The shooter's client renders a prediction only, following slice 002 conventions (amber predicted state, no health/score change before the authoritative result).
- **Bullet accounting:** every projectile's spawn state and terminal verdict are written to the L2 ledger — identity, worldline, outcome — consistent with the roadmap's "Call of Duty accounting" and future killcams/replays.
- **Hitscan is the degenerate case:** no `projectileSpeed` means evaluate at fire time under the existing bounded-rewind rule (250 ms cap, spatial-hit.v1). One fire path, two evaluation modes, keyed entirely by the registry.

## 6. Phasing

| Item | Phase | Gate / owner |
|---|---|---|
| Registry schema + `sidearm-mk1` retroactive conformance | Phase 2 weapons v1 | This doc + contracts proposal (§7) co-sign |
| `bolt-caster` (projectile) | Phase 2 weapons v1 | Requires L1 projectile worldlines passing on devices (roadmap Phase 2 item 1) |
| `repeater` (hitscan variant) | Phase 2 weapons v1, first cut if scope tightens | Same gate as registry |
| Per-weapon reload (§3) | Phase 2 weapons v1 | Ships with registry; supersedes the global-constant scaffold |
| Lobby loadout selection | Phase 2 weapons v1 | Contracts proposal (§7) |
| **Bullet-time rounds** (`bulletType: "special"`) | **Phase 2, gated on projectiles passing on devices** | **ADR 0005 owns time semantics and activation economy — referenced, not designed here.** The registry only reserves the `special` value and one future id. |
| Ammo pickups, drops, weapon switching | Phase 3 (open world) | Needs L3 spatial persistence + safety design; explicit ADR per roadmap |
| Fire modes (burst/auto), attachments, progression loadouts | Phase 3+ | Needs L0 identity; out of scope entirely |

Phase 2 gate restated (roadmap): 4-player projectile match with one bullet-time activation, all devices consistent, on video. Weapons v1 supplies the guns for that gate; ADR 0005 supplies the time.

## 7. Contracts proposal (requires Integration co-sign)

Design does not edit `contracts/**` or `docs/interface-contracts.md`. The following is a proposal for an Integration-owned `weapons.v1` revision to the match.v2 surface; nothing here is frozen until Integration lands it with fixtures.

1. **Shared catalog additions:**

   ~~~ts
   export type BulletType = "hitscan" | "projectile" | "special";

   export interface WeaponDefinition {
     id: string;
     bulletType: BulletType;
     damageByZone: { head: number; torso: number; limbs: number };
     fireCooldownMs: number;
     magazineSize: number;
     reloadDurationMs: number;
     projectileSpeedMetersPerSecond?: number; // present iff projectile
     projectileLifetimeMs?: number;           // present iff projectile
     presentationKey: string;
   }

   export const DEFAULT_WEAPON_ID = "sidearm-mk1";
   ~~~

   The registry ships as an immutable fixture (`contracts/fixtures/weapons.v1.json`) validated by all three consumers, per the existing fixture discipline.
2. **Loadout:** add optional `weaponId` to `matchesV2:create` / `matchesV2:join` args (omitted = `DEFAULT_WEAPON_ID`; unknown id throws a new `INVALID_WEAPON`). Fixed for the match.
3. **Snapshots:** `PlayerV2Snapshot` adds `weaponId: string`. `ammo` semantics generalize from the constant 8 to that weapon's `magazineSize`; respawn restores `weapon.magazineSize`, not `MAGAZINE_SIZE`.
4. **Validation:** cooldown, magazine, reload duration, and damage lookups switch from global constants to the shooter's registry entry. v1 surfaces (g2.v1, phase0.v1) are untouched; `sidearm-mk1` equals the current constants, so v2 behavior is unchanged until a second weapon is selectable.
5. **Projectile events (with L1/ADR 0004):** a projectile fire emits one spawn record and, later, one terminal-verdict record to the ledger and event stream; enum additions follow the standard decoders-merge-before-emit rule.
6. **`special` stays un-emittable** until ADR 0005 is accepted and its decoders are merged.

## Open questions (product owner)

1. Bolt Caster one-shot headshot (100): keep, or cap at 90 so no weapon one-taps? Affects the dodge-vs-precision fantasy directly.
2. Is the Repeater in or out of the Phase 2 gate build? (Cut-first candidate; §2.)
3. May players in one match choose different weapons at launch, or does weapons v1 ship with a single host-selected match-wide weapon first?
4. Repeater at 150 ms cooldown likely exceeds the voice-trigger cadence — is trigger-button-only acceptable for it, or must every weapon be voice-fireable?
5. Should the eventual bullet-time round consume magazine ammo or be entitlement-only? (Feeds ADR 0005; no registry impact until then.)
