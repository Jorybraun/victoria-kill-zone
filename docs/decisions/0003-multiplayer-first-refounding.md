# ADR 0003: Multiplayer-first re-founding (Phase 1 direction)

- **Status:** Proposed
- **Date:** 2026-08-24
- **Decision owners:** Product and integration

## Context

The Phase 0 prototype (ADR 0001) proved the core experience is fun on two phones, and its delivery discipline (contracts, gates, device evidence) worked. It also revealed structural limits recorded in [docs/roadmap.md](../roadmap.md): 1v1 identity is baked into contracts, validation, and targeting; hit registration is a shooter-local screen-space claim; there is no realtime simulation plane, no transport/authority abstraction, and no shared spatial frame. These limits block the product goals now on record: 4-player matches soon, larger and eventually non-co-located play later, persistent accountable projectiles, and personal bullet time.

Product direction (owner statement, 2026-08-24): design for 4 players now and plan to scale; co-located play now with a lean architecture able to grow toward open-world encounters.

## Decision

Phase 1 re-founds the architecture as the layered model defined in [docs/roadmap.md](../roadmap.md):

- **Multiplayer-first contracts.** New `match.v2` contracts model player sets (target cap 4 for Phase 1), capability-based roles instead of the `host`/`guest` binary, and per-player targeting. No new contract may assume exactly two players.
- **A realtime combat plane (L1) distinct from durable authority (L2).** A pure, deterministic, platform-neutral simulation core owns match time, pose history, bounded-rewind hit verdicts, and projectile worldlines. It runs behind an `AuthorityHost` interface (host phone first; edge/server later) and a `CombatTransport` interface (co-located peer transport first; relay later).
- **Convex remains the durable authority (L2)** for lifecycle, entitlements, terminal verdicts, scores, replay evidence, and spectator projections — and stays out of the frame loop. Any change to this split requires ADR 0004, informed by [docs/research/realtime-backend-options.md](../research/realtime-backend-options.md) and KIL-21 physical-device latency measurements.
- **A shared spatial layer (L3)** behind a `SharedArenaFrame` provider interface: peer relocalization now; VPS/geo-anchor providers are a Phase 3 spike, not a Phase 1 dependency.
- **Perception demotes to claims (L4).** Vision targeting generates aim claims; spatial verdicts decide hits. The G2 debug-fire path survives until spatial hitscan has device evidence, per AGENTS.md.
- **Phase 0 constraints superseded:** the "exactly 1v1" limit and the prohibition on 3+ player targeting are replaced by the Phase 1 cap of 4 players. All other ADR 0001 exclusions (persistent accounts, WebRTC video, App Store submission, production anti-cheat claims, physical accessories) remain in force.

The Phase 0 build remains playable throughout; re-founding proceeds in slices beside it, never through it.

## Consequences

- Contract revision work lands first (`match.v2`, spatial-hit vocabulary generalized to N players) and every downstream owner builds against it.
- The Convex domain-layer pattern is retained; its 1v1 assumptions are removed rather than the layer being rewritten.
- 4-phone hardware evidence becomes the promotion bar for combat slices (extends the two-phone G-gates; gate definitions updated by integration when Phase 1 slices are cut).
- Bullet time, weapon variety, and open-world presence become content and provider decisions on stable interfaces instead of architecture rewrites (ADRs 0005, 0006).
- Cost: re-founding spends effort on interfaces and a simulation core before new visible features; the roadmap's parallel B-track keeps the current game improving in the meantime.

## Reconsider when

Reconsider if Phase 1 device evidence shows 4-phone co-located transport or shared-frame quality is not achievable within the roadmap's stated budgets, or if measured Convex verdict latency forces consolidating L1 and L2 (ADR 0004 owns that call). Any replacement must preserve the acceptance experience: acquire → fire → agreed verdict → death → respawn across all connected devices and the spectator.
