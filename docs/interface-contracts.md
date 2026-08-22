# iOS, Convex, and spectator interface contract

- **Owner:** Integration
- **Current compatibility contract:** g2.v1
- **Next complete gameplay contract:** phase0.v1
- **Consumers:** convex/**, ios/**, spectator/**

This document is the canonical shared wire contract. The technical specification remains product authority. ADR 0002 contains the only accepted G2 exception: Convex issues the match capability and iOS persists it in Keychain.

## Version and rollout rules

| Version | Purpose | Delivery state |
|---|---|---|
| g2.v1 | Create → join → ready → countdown → debug torso hit → synchronized health | Backward-compatible baseline; presence and reconnect amendments below are required before merge |
| phase0.v1 | Markerless fire, arena telemetry, cooldown, reload, elimination, K/D, respawn, finish, and spectator results | Frozen implementation target; not yet implemented |

phase0.v1 extends g2.v1. It does not rename or remove a G2 field or wire name. Optional JSON properties are omitted, never encoded as null. Unknown additive object properties must be ignored by consumers. An enum case is not additive: iOS and spectator decoders for a new case must merge before the backend may emit it.

Contract versions live in the fixture manifest, not as a required runtime field. The immutable fixtures in contracts/fixtures are the cross-language compatibility authority.

## Common wire rules

- IDs are opaque strings. Clients never construct, parse, or sort by internal ID structure.
- Times are server-authoritative Unix epoch milliseconds represented as finite JSON numbers under JavaScript's safe-integer limit.
- Counts, health, ammunition, damage, and durations are exact integers.
- Arrays have deterministic order: players are host-first; events are createdAt descending, then id ascending.
- Events have stable unique IDs. Consumers de-duplicate by ID after reconnect.
- Raw backend exceptions, argument dumps, stack traces, secrets, hashes, private URLs, device identifiers, and exact public spectator coordinates are forbidden.
- Convex owns phase, time, arena state, membership, presence, health, ammunition, cooldown, reload, score, respawn, shot idempotency, winner, and spectator projections.
- iOS owns camera frames, pose detection, the aim ray, immediate local effects, and whether to submit a miss or a markerless hit claim.

## Shared constants and enums

~~~ts
export const PLAYER_CAPACITY = 2;
export const MATCH_CODE_LENGTH = 6;
export const MATCH_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
export const MATCH_CODE_INPUT_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
export const DISPLAY_NAME_MAX_SCALARS = 20;
export const INITIAL_HEALTH = 100;
export const MAGAZINE_SIZE = 8;
export const INITIAL_AMMO = MAGAZINE_SIZE;
export const ARENA_RADIUS_MIN_METERS = 20;
export const ARENA_RADIUS_MAX_METERS = 60;
export const ARENA_RADIUS_DEFAULT_METERS = 30;
export const COUNTDOWN_MS = 3_000;
export const MATCH_DURATION_MS = 180_000;
export const FIRE_COOLDOWN_MS = 350;
export const RELOAD_DURATION_MS = 1_250;
export const RESPAWN_DELAY_MS = 5_000;
export const HEARTBEAT_INTERVAL_MS = 5_000;
export const PRESENCE_TIMEOUT_MS = 15_000;
export const LOCATION_FRESHNESS_MS = 5_000;
export const ARENA_HYSTERESIS_METERS = 5;
export const MAX_TRUSTED_LOCATION_ACCURACY_METERS = 20;
export const ARENA_UNCERTAIN_GRACE_MS = 5_000;
export const HEAD_DAMAGE = 75;
export const TORSO_DAMAGE = 34;
export const LIMB_DAMAGE = 20;
export const DEBUG_TORSO_DAMAGE = TORSO_DAMAGE;

export type MatchPhase =
  | "lobby"
  | "countdown"
  | "running"
  | "finished"
  | "cancelled";

export type PlayerRole = "host" | "guest";
export type PlayerLifeState = "alive" | "dead" | "respawning" | "disconnected";
export type HitZone = "head" | "torso" | "limbs";
export type ShotOutcome = "miss" | "hit" | "kill" | "rejected";
export type ArenaState = "inside" | "warning" | "uncertain" | "outside";
~~~

# g2.v1

## Public functions

| Function | Kind | Arguments | Result |
|---|---|---|---|
| matches:create | mutation | CreateMatchArgs | PlayerSession |
| matches:join | mutation | JoinMatchArgs | PlayerSession |
| matches:setReady | mutation | AuthenticatedPlayerArgs plus isReady | null |
| matches:start | mutation | AuthenticatedPlayerArgs | null |
| players:heartbeat | mutation | AuthenticatedPlayerArgs | null |
| shots:debugFire | mutation | DebugFireArgs | DebugFireResult |
| queries:matchSnapshot | query | AuthenticatedPlayerArgs | MatchSnapshot |
| queries:spectatorSnapshot | query | code | SpectatorSnapshot or null |

These are exact wire names. Platform adapters may use native method names but may not add aliases.

G2 also requires these guarded internal mutations:

| Function | Arguments | Result |
|---|---|---|
| internal.matches:activate | matchId and expectedStartsAt | null |
| internal.matches:finish | matchId and expectedEndsAt | null |
| internal.players:expirePresence | playerId and expectedLastSeenAt | null |

## Requests and match capability

~~~ts
export interface CreateMatchArgs {
  displayName: string;
  arenaRadiusMeters: number;
}

export interface JoinMatchArgs {
  displayName: string;
  code: string;
}

export interface PlayerSession {
  matchId: string;
  code: string;
  playerId: string;
  sessionSecret: string;
}

export interface AuthenticatedPlayerArgs {
  matchId: string;
  playerId: string;
  sessionSecret: string;
}

export interface DebugFireArgs extends AuthenticatedPlayerArgs {
  clientShotId: string;
}
~~~

Per ADR 0002, Convex generates sessionSecret from 32 cryptographically random bytes and returns exactly 64 lowercase hexadecimal characters. It stores only SHA-256(sessionSecret). The capability binds one player to one match, is returned only by that player's successful create/join mutation, and is never retrievable later.

iOS validates and saves the full PlayerSession to a device-only Keychain item before subscribing or enabling input. A restored session remains locked until a fresh matching snapshot arrives. Explicit leave, corrupt data, INVALID_SESSION, and MATCH_NOT_FOUND clear it; a transport failure does not.

The client generates one cryptographically random clientShotId per trigger press and reuses it only for a retry of that same logical press.

## G2 input normalization

- A display name is trimmed of leading/trailing Unicode whitespace. Internal characters are preserved. The result must contain 1–20 Unicode scalar values; otherwise create/join throws INVALID_DISPLAY_NAME. The backend does not silently truncate it.
- A generated duel code is exactly six characters from ABCDEFGHJKLMNPQRSTUVWXYZ23456789, excluding ambiguous 0, 1, I, and O.
- A typed or pasted code is uppercased and may remove ASCII whitespace or hyphen separators. The normalized input must be exactly six ASCII A–Z/0–9 characters; any other character or length throws INVALID_CODE. An unknown valid code throws MATCH_NOT_FOUND.
- arenaRadiusMeters must be finite. A non-finite value makes matches:create throw the sanitized ConvexError({ code: "INVALID_ARENA_RADIUS" }) before writing a match, player, or event. A finite value is rounded to the nearest whole metre and clamped to 20–60; clients default to 30.

## G2 snapshots

~~~ts
export interface MatchSummary {
  id: string;
  code: string;
  phase: MatchPhase;
  durationMs: number;
  startsAt?: number;
  endsAt?: number;
}

export interface PlayerSnapshot {
  id: string;
  displayName: string;
  role: PlayerRole;
  ready: boolean;
  connected: boolean;
  health: number;
  ammo: number;
}

export type G2EventType = "joined" | "ready" | "started" | "hit";

export interface EventSnapshot {
  id: string;
  type: G2EventType;
  message: string;
  createdAt: number;
  actorPlayerId?: string;
  targetPlayerId?: string;
  zone?: "torso";
  damage?: number;
}

export interface MatchSnapshot {
  serverNow: number;
  match: MatchSummary;
  localPlayerId: string;
  players: PlayerSnapshot[];
  events: EventSnapshot[];
}

export interface SpectatorSnapshot {
  serverNow: number;
  match: MatchSummary;
  players: PlayerSnapshot[];
  events: EventSnapshot[];
}
~~~

queries:matchSnapshot authenticates before projecting. queries:spectatorSnapshot is public, read-only, and allow-list projected. A malformed or unknown code returns null. Neither projection contains capability material, device identity, raw targeting evidence, or precise location.

## G2 debug fire

~~~ts
export interface DebugFireResult {
  accepted: boolean;
  outcome: "hit" | "rejected";
  clientShotId: string;
  replayed: boolean;
  damage: number;
  shooterAmmo: number;
  targetHealth: number;
  eventId?: string;
  rejectReason?: G2ErrorCode;
}
~~~

The first valid debug fire during running atomically changes host ammunition 8 → 7, guest health 100 → 66, inserts one shot ledger entry, and appends one torso-hit event. Repeating the same authenticated playerId and clientShotId returns the stored result with replayed true and creates no second state change or event. Keep this path until markerless targeting passes physical-device evidence.

## G2 stable errors

~~~ts
export type G2ErrorCode =
  | "INVALID_DISPLAY_NAME"
  | "INVALID_CODE"
  | "INVALID_ARENA_RADIUS"
  | "MATCH_NOT_FOUND"
  | "MATCH_FULL"
  | "MATCH_ALREADY_STARTED"
  | "INVALID_SESSION"
  | "PLAYERS_NOT_READY"
  | "PLAYERS_NOT_CONNECTED"
  | "HOST_ONLY"
  | "MATCH_NOT_RUNNING"
  | "CONNECTION_STALE";
~~~

Create, join, ready, start, heartbeat, query authentication, and invalid debug-fire authentication throw ConvexError({ code }). For a non-finite matches:create arenaRadiusMeters, the exact public error data is { code: "INVALID_ARENA_RADIUS" }; the rejected numeric value and internal validation text are never returned. A validly authenticated debug-fire business rejection returns accepted false rather than throwing. Clients show frozen product copy, never raw error text.

## Presence, match clock, and reconnect amendment

Presence is server-owned and must not be a permanent true flag.

1. Create/join initialize lastSeenAt with server time, set connected true, and schedule a guarded expiry.
2. While a session is active in the foreground, iOS calls players:heartbeat at least every 5 seconds.
3. Heartbeat authenticates, sets lastSeenAt to server time, sets connected true, and schedules expiry for 15 seconds later with expectedLastSeenAt.
4. An expiry job changes connected to false only if lastSeenAt still equals its expected value. Older jobs are no-ops.
5. Start and fire defensively check both connected and lastSeenAt freshness.
6. A socket reconnect alone never unlocks input. Only a fresh matching snapshot does.

matches:start sets phase countdown and startsAt = serverNow + 3,000. During countdown, endsAt is omitted. The guarded activation mutation sets phase running, sets endsAt = activation server time + durationMs, and schedules finish. A guarded finish mutation calculates the result and sets phase finished. Public gameplay mutations also reject when serverNow is at or after endsAt.

Clients derive the visible countdown from startsAt - serverNow and the match clock from endsAt - serverNow. A local timer only interpolates between snapshots; it never changes authoritative phase.

# phase0.v1

phase0.v1 retains every G2 field and adds the complete native gameplay surface. Existing G2 clients may continue to call shots:debugFire during migration. The backend must not emit Phase 0 event enum values until the iOS and spectator decoders that accept them are merged.

## Phase 0 public and internal functions

| Function | Kind | Arguments | Result |
|---|---|---|---|
| matches:create | mutation | Phase0CreateMatchArgs | PlayerSession |
| matches:join | mutation | JoinMatchArgs | PlayerSession |
| matches:setReady | mutation | AuthenticatedPlayerArgs plus isReady | null |
| matches:start | mutation | AuthenticatedPlayerArgs | null |
| matches:end | mutation | AuthenticatedPlayerArgs | null |
| players:heartbeat | mutation | HeartbeatArgs | null |
| players:startReload | mutation | AuthenticatedPlayerArgs | ReloadStartResult |
| shots:fire | mutation | FireShotArgs | FireShotResult |
| shots:debugFire | mutation | DebugFireArgs | DebugFireResult |
| queries:matchSnapshot | query | AuthenticatedPlayerArgs | Phase0MatchSnapshot |
| queries:spectatorSnapshot | query | code | Phase0SpectatorSnapshot or null |
| internal.matches:activate | internal mutation | matchId and expectedStartsAt | null |
| internal.matches:finish | internal mutation | matchId and expectedEndsAt | null |
| internal.players:expirePresence | internal mutation | playerId and expectedLastSeenAt | null |
| internal.players:completeReload | internal mutation | playerId and expectedReloadEndsAt | null |
| internal.players:respawn | internal mutation | playerId and expectedRespawnAt | null |

Every scheduled mutation rereads current state and exits harmlessly when its expected timestamp or phase no longer matches. It also exits when serverNow is earlier than expectedAt, so an accidentally early job cannot advance state.

## Phase 0 requests

~~~ts
export interface LocationSample {
  latitude: number;
  longitude: number;
  accuracyMeters: number;
  capturedAtClient: number;
  headingDegrees?: number;
}

export interface Phase0CreateMatchArgs extends CreateMatchArgs {
  arenaCenter: LocationSample;
}

export interface HeartbeatArgs extends AuthenticatedPlayerArgs {
  location?: LocationSample;
}

export interface FireShotArgs {
  matchId: string;
  shooterId: string;
  sessionSecret: string;
  clientShotId: string;
  targetId?: string;
  zone?: HitZone;
  poseConfidence?: number;
  origin?: [number, number, number];
  direction?: [number, number, number];
  firedAtClient: number;
}

export interface ReloadStartResult {
  ammo: number;
  reloadEndsAt: number;
}

export type FireRejectReason =
  | "MATCH_NOT_RUNNING"
  | "CONNECTION_STALE"
  | "SHOOTER_NOT_ALIVE"
  | "RELOADING"
  | "OUT_OF_ARENA"
  | "LOCATION_STALE"
  | "OUT_OF_AMMO"
  | "FIRE_COOLDOWN"
  | "IDEMPOTENCY_CONFLICT"
  | "INVALID_TARGET"
  | "TARGET_NOT_ALIVE";

export interface FireShotResult {
  accepted: boolean;
  outcome: ShotOutcome;
  clientShotId: string;
  replayed: boolean;
  damage: number;
  shooterAmmo: number;
  targetHealth?: number;
  targetLifeState?: PlayerLifeState;
  eventId?: string;
  rejectReason?: FireRejectReason;
}
~~~

Phase 0 iOS always sends arenaCenter on create. During the migration window the backend may continue accepting the smaller G2 create shape, but a match without a valid center cannot use shots:fire.

For shots:fire only, shooterId is the technical-spec wire name for PlayerSession.playerId. It must name the player bound to the supplied sessionSecret; it is not a second identity.

Location ranges, accuracy, and finite numbers are validated. Convex records receipt time as locationAt and uses capturedAtClient only for age validation; client time never becomes authoritative. Location is sent through players:heartbeat when meaningfully changed at approximately 2–5 Hz, with a presence-only heartbeat at least every 5 seconds.

A player with no trusted location sample starts with arenaState uncertain and omitted location fields. shots:fire returns LOCATION_STALE until a trusted fresh sample establishes an authoritative arena state.

For a claimed hit, targetId, zone, and poseConfidence are all required. Head confidence must be at least 0.60; torso and limbs confidence must be at least 0.45. A miss omits those three fields. Damage is never accepted from the client. origin and direction are optional reduced evidence for the active match only and never enter public snapshots.

## Phase 0 snapshots

~~~ts
export interface ArenaSnapshot {
  latitude: number;
  longitude: number;
  radiusMeters: number;
}

export interface Phase0MatchSummary extends MatchSummary {
  winnerPlayerId?: string;
}

export interface Phase0PlayerSnapshot extends PlayerSnapshot {
  kills: number;
  deaths: number;
  damageDealt: number;
  shotsFired: number;
  shotsHit: number;
  headshots: number;
  lifeState: PlayerLifeState;
  arenaState: ArenaState;
  lastSeenAt: number;
  lastShotAt?: number;
  reloadEndsAt?: number;
  respawnAt?: number;
  latitude?: number;
  longitude?: number;
  headingDegrees?: number;
  locationAccuracyMeters?: number;
  locationAt?: number;
}

export type Phase0EventType =
  | G2EventType
  | "shot"
  | "eliminated"
  | "respawned"
  | "out_of_zone"
  | "finished";

export interface Phase0EventSnapshot {
  id: string;
  type: Phase0EventType;
  message: string;
  createdAt: number;
  actorPlayerId?: string;
  targetPlayerId?: string;
  zone?: HitZone;
  damage?: number;
}

export interface Phase0MatchSnapshot {
  serverNow: number;
  match: Phase0MatchSummary;
  arena: ArenaSnapshot;
  localPlayerId: string;
  players: Phase0PlayerSnapshot[];
  events: Phase0EventSnapshot[];
}

export interface SpectatorArenaPosition {
  eastMeters: number;
  northMeters: number;
  headingDegrees?: number;
}

export interface Phase0SpectatorPlayerSnapshot
  extends Omit<
    Phase0PlayerSnapshot,
    | "latitude"
    | "longitude"
    | "headingDegrees"
    | "locationAccuracyMeters"
    | "locationAt"
    | "lastSeenAt"
  > {
  arenaPosition?: SpectatorArenaPosition;
}

export interface Phase0SpectatorSnapshot {
  serverNow: number;
  match: Phase0MatchSummary;
  arena: { radiusMeters: number };
  players: Phase0SpectatorPlayerSnapshot[];
  events: Phase0EventSnapshot[];
}
~~~

The public spectator projection exposes only arena-relative current position, never latitude, longitude, accuracy, location history, session data, device data, or raw targeting evidence.

## Phase 0 gameplay invariants

- shots:fire authenticates, checks idempotency, validates match time, shooter presence/life/arena/ammo/cooldown, validates the only opponent for a hit, clamps damage to server constants, applies state and statistics atomically, writes one ledger row and event, and schedules respawn on a kill.
- accepted is true for miss, hit, and kill. A validly authenticated business rejection returns accepted false, outcome rejected, damage 0, and no state or event change.
- Replaying shooterId plus clientShotId returns the original result with replayed true. Reusing that key with different claim data returns a rejected idempotency conflict and changes no state.
- A miss consumes one round, increments shotsFired, applies zero damage, and does not change target state.
- A hit consumes one round and increments shotsFired, shotsHit, damageDealt, and headshots when applicable.
- One accepted shot appends one gameplay event: shot for a miss, hit for a nonlethal hit, or eliminated for a kill. Event and result damage is actual applied damage capped by remaining health; clients never calculate it.
- A kill performs the hit changes, sets target health to 0, increments kills and deaths, sets the target to respawning, records respawnAt, and schedules restoration after 5 seconds.
- Respawn restores health to 100, ammo to 8, lifeState to alive, and removes reloadEndsAt and respawnAt.
- startReload is valid only for a fresh, alive, in-arena player during running with ammo below 8 and no active reload. It records reloadEndsAt and scheduled completion; firing while reloading is rejected.
- Match finish cancels effective gameplay, calculates the winner, and appends one finished event. Winner order is most kills, then fewest deaths, then most applied damageDealt. An exact tie omits winnerPlayerId.
- matches:end is host-only and valid only during countdown or running. It atomically sets phase finished, sets endsAt to serverNow, calculates the same winner, and appends exactly one finished event. Lobby calls return MATCH_NOT_RUNNING; finished/cancelled calls return MATCH_ALREADY_FINISHED. Repeated calls and previously scheduled activate/finish jobs cannot append another event or change the winner.
- Arena state and geofence enforcement are server-owned. Accuracy above 20 metres is untrusted. A recently trusted inside sample becomes warning for at most 5 seconds when accuracy degrades, then uncertain. The 5-metre boundary hysteresis and two consecutive trusted outside samples prevent flapping. The iOS client may predict a warning but locks fire whenever the authoritative state is outside, uncertain, or stale.
- Presence expiry sets connected false. It may project lifeState disconnected only for an otherwise-alive player; respawning remains respawning. A fresh heartbeat restores an alive disconnected player to alive without changing health or score.

## Phase 0 thrown errors

The G2 error union remains stable. Phase 0 adds these thrown validation or non-shot mutation errors:

~~~ts
export type Phase0ErrorCode =
  | G2ErrorCode
  | "INVALID_ARENA"
  | "INVALID_LOCATION"
  | "MATCH_ALREADY_FINISHED"
  | "PLAYER_NOT_ALIVE"
  | "MAGAZINE_FULL"
  | "ALREADY_RELOADING";
~~~

FireRejectReason values are returned in FireShotResult rather than thrown after authentication. Shape validation and INVALID_SESSION still throw.

## Compatibility and release gates

1. Integration commits g2.v1 and phase0.v1 fixtures without credentials or real coordinates.
2. Backend and both clients validate the immutable fixtures through production DTO/decoder seams.
3. iOS and spectator merge support for every Phase 0 enum before the backend emits it.
4. Backend preserves shots:debugFire until markerless physical-device evidence passes.
5. Presence, Keychain restore, and fresh-snapshot locking pass before G2 merge.
6. shots:fire, reload, elimination, respawn, finish, and public sanitization pass function-level tests before Phase 0 promotion.
7. pnpm verify passes on each exact PR head and on the final integrated SHA.
8. Simulator evidence is not physical evidence. The final gate names both phones and records observed camera, network, haptic, geofence, signing, reconnect, and spectator results without identifiers or secrets.

A backend change to a wire name, enum, constant, required field, authentication rule, ordering rule, or idempotency key requires an Integration-owned revision and explicit handoff to iOS and spectator.
