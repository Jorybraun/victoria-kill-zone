# @vkz/backend

Authoritative Convex backend for Victoria Kill Zone. This package owns `convex/**` only.

## Layout

```text
convex/
  convex.json        Convex CLI configuration (functions live in functions/)
  domain/            Pure, dependency-free game rules and deterministic tests target
  functions/         Convex schema, mutations, and queries (thin adapters over domain/)
  tests/             Deterministic unit tests for the domain rules
```

`domain/**` imports nothing but `@noble/hashes`, so every rule is unit-testable without a
deployment, network access, or the Convex runtime. `functions/**` loads documents, calls a
domain planner, and applies the returned patches.

## Slice scope

This first vertical slice implements the authoritative create → join → start → debug fire →
sanitized spectator path:

| Function | Type | Purpose |
|---|---|---|
| `matches:createMatch` | mutation | Create the duel and host player atomically |
| `matches:joinMatch` | mutation | Join by code as the guest, enforcing the two-player limit |
| `matches:startMatch` | mutation | Host-only start; stamps the server-owned duel window |
| `shots:debugFire` | mutation | Idempotent, server-resolved hit claim |
| `queries:spectatorSnapshot` | query | Read-only, sanitized spectator projection |

Not yet implemented (later slices): `setReady`, `heartbeat`, `startReload`, host `end`, the
phone `matchSnapshot` query, and the scheduled internal mutations for reload completion,
respawn, and finish. Duel expiry and respawn readiness are currently derived from
`endsAt`/`respawnAt` on read, so a delayed scheduled job can never show a live duel that
should have ended.

## Match state

The explicit duel state machine is `setup → waiting → active → ended`:

- `setup`: created by the host, no opponent yet, joinable.
- `waiting`: two players present, awaiting the host start.
- `active`: running until the server-owned `endsAt`.
- `ended`: terminal; no gameplay accepted.

Snapshots also carry the specification's frozen `MatchPhase` projection
(`lobby | countdown | running | finished | cancelled`) so iOS and spectator work can consume
either vocabulary.

## Sessions

Each phone generates a random device ID and a random match-scoped session secret, and sends
only their SHA-256 digests to `createMatch`/`joinMatch`. Gameplay mutations send the raw
secret, which is hashed with a deterministic pure-JavaScript SHA-256 (`@noble/hashes`) and
compared against the stored digest for that exact player, so one player's secret can never
drive the opponent. No query returns a session secret, session digest, or device identifier.

## Scripts

```sh
pnpm --filter @vkz/backend lint
pnpm --filter @vkz/backend typecheck
pnpm --filter @vkz/backend test
pnpm --filter @vkz/backend build
```

`pnpm verify` at the repository root runs all four across the workspace.

`functions/_generated/` is produced by the Convex CLI against a deployment and is not
committed; the function builders in `functions/lib/server.ts` derive their types from the
committed schema so the package typechecks without a deployment.
