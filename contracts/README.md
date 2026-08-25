# Shared contract fixtures

These fixtures are Integration-owned compatibility inputs for Convex, native iOS, and spectator tests. They contain synthetic public wire values only. They are not runtime seed data and their metadata is never sent over the network.

## Suites

- fixtures/g2.v1.json freezes the backward-compatible G2 snapshot, debug-fire result, error, and reconnect shapes.
- fixtures/phase0.v1.json extends g2.v1 with complete markerless gameplay, arena, reload, elimination, respawn, finish, and privacy projections.
- fixtures/match.v2.json freezes the multiplayer-first surface authorized by ADR 0003: player sets with capacity 2–4, capability arrays instead of host/guest roles, the left event, N-player fire targeting, and the generalized winner rule.
- fixtures/geofence.v1.json freezes the production geofence state machine as step-driven vectors (KIL-25): initial uncertainty, trust validation, warning grace, exit hysteresis with two consecutive outside samples, staleness, re-entry, antimeridian distance, and the OUT_OF_ARENA / LOCATION_STALE fire-gate expectations.

A released fixture is immutable. A breaking change creates a new file and an Integration-owned contract revision; it never edits an old suite in place.

## Envelope

Each suite declares:

~~~json
{
  "fixtureFormatVersion": 1,
  "contractVersion": "phase0.v1",
  "extends": "g2.v1",
  "enums": {},
  "snapshots": [],
  "mutationResults": [],
  "connectionScenarios": [],
  "errors": []
}
~~~

Every test case has a stable fixture id, an exact wire name, and a payload. Optional wire fields are omitted rather than encoded as null. IDs, display names, match codes, coordinates, and times are synthetic. No fixture may contain a session secret, digest, deployment URL, device identity, certificate, provisioning value, or real location.

## Consumer gates

Convex tests parse each file as unknown data, validate the enum catalogs, compare canonical projections and mutation results, assert database deltas, and prove that public spectator payloads exclude forbidden fields.

iOS tests load the same files through production decoder seams. They must decode every snapshot/result, exhaustively map stable errors, reject fractional integer fields, and drive the reconnect scenario through the real store. Test-only duplicate DTOs do not prove compatibility.

Spectator tests decode only spectator cases through the production adapter and reject capability, device, raw targeting, and exact coordinate fields.

Generated Convex IDs and times are canonicalized to the synthetic values before fixture comparison. Consumers compare wire payloads, not fixture metadata.

## Required invariants

- Players are host-first.
- Events are createdAt descending, then id ascending, with unique stable IDs.
- A rejection changes no gameplay state and appends no event.
- A retry returns the original result with replayed true and creates no second ledger row or event.
- A kill updates health, kills, deaths, life state, and respawnAt atomically.
- Respawn restores health and ammunition and removes respawnAt.
- Finished state includes the authoritative winner unless the tiebreak is exact.
- Reconnecting transport does not unlock mutations; a fresh matching snapshot does.
- Public spectator payloads never expose exact coordinates, location accuracy, location/presence/client-capture timestamps, session data, device data, or raw targeting evidence. Server match clocks and event timestamps remain public wire fields.
