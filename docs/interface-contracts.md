# G2 network interface contract

Status: **Frozen for the 2026-08-22 demo slice**
Owner: Integration
Consumers: `convex/**`, `ios/**`, `spectator/**`

This contract is the minimum shared surface for create → join → ready → start → debug fire → synchronized health. It intentionally excludes targeting, geofence enforcement, radar, K/D, respawn, reload, and permanent identity. Server functions own validation, time, damage, ammunition, phase transitions, and idempotency.

## Constants and enums

```ts
export const PLAYER_CAPACITY = 2;
export const MATCH_CODE_LENGTH = 6;
export const INITIAL_HEALTH = 100;
export const INITIAL_AMMO = 8;
export const DEBUG_TORSO_DAMAGE = 34;
export const COUNTDOWN_MS = 3_000;

export type MatchPhase =
  | "lobby"
  | "countdown"
  | "running"
  | "finished"
  | "cancelled";

export type PlayerRole = "host" | "guest";
export type EventType = "joined" | "ready" | "started" | "hit";
```

IDs are opaque strings at the client boundary. Clients never construct or parse them. Times are Unix epoch milliseconds supplied by the server.

## Public functions

| Function | Kind | Arguments | Result |
|---|---|---|---|
| `matches:create` | mutation | `CreateMatchArgs` | `PlayerSession` |
| `matches:join` | mutation | `JoinMatchArgs` | `PlayerSession` |
| `matches:setReady` | mutation | `AuthenticatedPlayerArgs & { isReady: boolean }` | `null` |
| `matches:start` | mutation | `AuthenticatedPlayerArgs` | `null` |
| `shots:debugFire` | mutation | `DebugFireArgs` | `DebugFireResult` |
| `queries:matchSnapshot` | query | `AuthenticatedPlayerArgs` | `MatchSnapshot` |
| `queries:spectatorSnapshot` | query | `{ code: string }` | `SpectatorSnapshot \| null` |

Names above are wire names. Adapters may expose platform-native method names, but must not change the wire names or field semantics.

## Requests and session envelope

```ts
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
```

The client generates one cryptographically random `clientShotId` per press and reuses it for a retry of that press. The server hashes session secrets before storage and never returns another player's secret. Secrets, deployment keys, and raw credentials never enter logs, events, spectator data, screenshots, fixtures, or PR text.

## Authoritative snapshots

```ts
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

export interface EventSnapshot {
  id: string;
  type: EventType;
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
```

`queries:matchSnapshot` validates the player session before returning data. `queries:spectatorSnapshot` is deliberately public and sanitized: it contains no session secret, device identity, precise location, raw targeting evidence, or mutation capability. Events are newest-first and stable by `id`; consumers de-duplicate by `id` during reconnect.

## Debug-fire result and idempotency

```ts
export interface DebugFireResult {
  accepted: boolean;
  outcome: "hit" | "rejected";
  clientShotId: string;
  replayed: boolean;
  damage: number;
  shooterAmmo: number;
  targetHealth: number;
  eventId?: string;
  rejectReason?: ErrorCode;
}
```

The first valid debug fire while `running` atomically changes host ammunition `8 → 7`, guest health `100 → 66`, stores one shot ledger entry, and appends one hit event. Repeating `(shooterId, clientShotId)` returns the stored outcome with `replayed: true`; it does not consume ammunition, change health, or append an event again.

## Stable error codes

```ts
export type ErrorCode =
  | "INVALID_DISPLAY_NAME"
  | "INVALID_CODE"
  | "MATCH_NOT_FOUND"
  | "MATCH_FULL"
  | "MATCH_ALREADY_STARTED"
  | "INVALID_SESSION"
  | "PLAYERS_NOT_READY"
  | "PLAYERS_NOT_CONNECTED"
  | "HOST_ONLY"
  | "MATCH_NOT_RUNNING"
  | "CONNECTION_STALE";
```

Clients map these codes to the frozen copy in `design/slices/001-g1-g2-network-vertical-slice.md`. Raw backend messages and stack traces are never user-facing.

## Client behavior

- Create/join mutations establish a `PlayerSession`; the secret remains match-scoped client state.
- Phone UI renders lobby, countdown, health, ammunition, and events only from `queries:matchSnapshot` subscription values.
- Countdown derives from `startsAt - serverNow`; clients do not run independent authoritative timers.
- Debug fire is host-only in this slice. It is disabled when the connection is stale, a request is pending, or the match is not `running`.
- Spectator has only the code-scoped query subscription and never receives a mutation client through its adapter.
- After a disconnect, all mutation input locks. A fresh snapshot atomically replaces stale state; clients do not replay animations or duplicate events.

## Compatibility gate

Before integration, each lane must prove its adapter accepts the DTOs above without field aliases or synthesized gameplay values. A backend change to a wire name, enum, constant, required field, authentication rule, or idempotency key requires an integration-owned contract revision and explicit handoff to both clients.
