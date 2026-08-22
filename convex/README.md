# @vkz/backend

Authoritative Convex backend for Victoria Kill Zone. This package owns `convex/**`
only and implements the frozen G2 contract in [`docs/interface-contracts.md`](../docs/interface-contracts.md).

## Layers

The G2 slice ships as a stack:

1. **Lobby authority** (this layer): schema, match-scoped sessions, and
   `matches:create`, `matches:join`, `matches:setReady`, `matches:start` with the
   server-timed countdown.
2. **Fire and snapshots**: `shots:debugFire`, `queries:matchSnapshot`, and
   `queries:spectatorSnapshot`.

## Authority rules

- The server owns match codes, session secrets, time, health, ammunition, phase
  transitions, and damage. Clients never send damage or timing.
- Phases are `lobby → countdown → running → finished | cancelled`. The
  countdown → running and running → finished edges resolve from server time, so
  a stale record can never gate a rule.
- Session secrets are generated server side, returned once to their owner, and
  stored only as a SHA-256 digest. No digest, secret, or device identifier is
  readable through any function result.
- Rejections cross the wire as `ConvexError({ code })` using the frozen
  `ErrorCode` union. Raw messages never reach a client.

## Structure

- `domain/` — pure, deterministic rules with no database or clock access.
- `functions/` — Convex mutations and queries that read/write documents and
  delegate every decision to `domain/`.
- `tests/` — deterministic unit tests over `domain/`.

`functions/_generated/` is produced by the Convex CLI against a deployment and is
not committed; `functions/lib/server.ts` derives the typed data model from the
committed schema instead.

## Scripts

```sh
pnpm --filter @vkz/backend lint
pnpm --filter @vkz/backend typecheck
pnpm --filter @vkz/backend test
pnpm --filter @vkz/backend build
```

`pnpm verify` at the repository root remains canonical.

## Out of scope

Targeting, geofence enforcement, radar, K/D, respawn, reload, winner
calculation, and permanent identity are later gates and are deliberately absent.
