# ADR 0005: Duel view — ARKit body tracking, skeleton lock overlay, and shots visible on every phone

- **Status:** Proposed (2026-09-04). Acceptance requires the two-phone physical-device evidence named below.
- **Date:** 2026-09-04
- **Decision owners:** Product and integration

## Context

The playable duel (`ActiveDuelView`) renders only the shooter's own beam (`LaserFXEngine`, #18). The opponent's shot never appears on the other phone: KIL-22 tracers (#36) exist only in the Shared Arena Harness, and the duel has no shared spatial frame. Targeting is 2D (`VNDetectHumanBodyPoseRequest`), so the HUD can show a reticle state but not the opponent's body.

Two further findings from tracing the fire path:

1. The shipping iOS build sends no location and no `arenaCenter`, and `shots:fire` applies the geofence gate unconditionally, so every markerless shot is rejected `LOCATION_STALE`. Only the host's `debugFire` produces a durable shot/event. The interface contract (§ "a match without a valid center cannot use shots:fire") makes the game unplayable on the current client.
2. `shots:fire` accepts `origin`/`direction` but the ledger does not persist them; the shot has no durable beginning or end.

Product direction (Slack, 2026-09-04): use ARKit body tracking, show a skeletal view on lock, make every shot show up in real time on all players' screens with a beginning and an end, prefer the local network between phones when available, keep shots durable.

## Decision

1. **Duel targeting runs `ARBodyTrackingConfiguration` when supported**, falling back to the existing world-tracking + Vision path otherwise. Body mode enables ARKit's automatic skeleton scale estimation so the geometric hit volumes remain useful across body sizes. Zones are resolved geometrically from the `ARBodyAnchor` skeleton against the camera ray: head sphere (0.12 m at the head joint), torso capsule (0.18 m radius, hips root → neck). The 3D verdict is carried in `TargetingObservation.aimZone3D` and takes precedence over the 2D region test in `TargetingStateMachine`; the state machine's stability/lock rules are unchanged. `TargetingSnapshot` gains `skeleton` (world-space joints + bone pairs) so the UI can draw it.
2. **Skeleton lock overlay.** While the snapshot is in a lock state (`bodyLock`, `torsoLock`, `targetReacquired`) with a fresh skeleton, the duel draws the joints and bones as SceneKit nodes in the existing `ARSCNView` (the same scene `LaserFXEngine` uses), tinted by zone (head = danger red, torso = ready green). Nothing is drawn while searching or lost.
3. **Every shot has a durable beginning and end.** `shots:fire` gains optional `impact: number[3]`; the ledger persists `origin`, `direction`, `impact`. The iOS client sends the shooter-frame muzzle, direction, and impact point (target joint on a hit; 25 m along the ray on a miss). Coordinates are shooter-frame and are stored for replay/spectator; they are not interpreted by the other phone (no shared frame in the duel — see ADR 0004 for the transport that will bring one).
4. **Centerless matches are not geofence-gated.** `shots:fire` applies the location gate only when the match recorded a valid `arenaCenter`, exactly as `debugFire` already does. The contract sentence is amended accordingly. Arena-centered matches keep the full gate.
5. **Incoming shots render on the other phone from durable events, with a peer fast path.** `LobbyStore` consumes new `shot`/`hit`/`eliminated` events whose `actorPlayerId` is the opponent (dedup by event id, only events after subscribe — the kill-banner pattern) and publishes an `IncomingShot { eventId, hit, zone }`. The duel renders it as a beam from the opponent's tracked body (head joint when the skeleton is fresh; otherwise from the screen-top centre 3 m ahead) to the local camera (hit: red spark 0.3 m in front of the camera + haptic) or past the camera (miss). When both phones are on the same Wi‑Fi, the host advertises and the guest browses a match-scoped instance of the existing KIL-20 `ArenaPeerLink` (`_pewpew-arena._tcp`) for the duel's lifetime; a `shotTracer` frame renders the beam immediately (no verdict yet) and suppresses only the Convex-driven miss render for that shooter within 2 s; a `hit`/`eliminated` event still renders so the receiver gets the spark and haptic. Convex remains the authority: peer frames never change health, ammo, or the ledger.

## Consequences

- The spec's "Vision" targeting is superseded for devices that support body tracking; the Vision path remains as fallback and for the harness (body tracking cannot coexist with collaborative sessions and cannot produce a world map; it *can* be seeded with one via `initialWorldMap` — see [ADR 0006](0006-duel-shared-frame.md), which defines the duel's shared frame on that basis).
- Body tracking tracks one person; automatic skeleton scale estimation improves the fixed hit volumes across body sizes. This remains acceptable for 1v1 and the Phase 1 co-located game until ADR 0004's phone-pose capsules land.
- The harness peer link is reused as an interim duel fast path with a match-scoped Bonjour service name; ADR 0004 retires it in favour of `CombatTransport`.
- Write set: `ios/**/Targeting/**` (targeting), `ios/**/Features/Game/**` and `Features/Lobby/**`, `Domain/GameSessionModels.swift`, `Services/**` (game), `convex/**` (backend), `docs/interface-contracts.md` and this record (integration).

## Acceptance evidence (turns Proposed into Accepted)

On two named physical iPhones (model + iOS, sanitized) recorded in `docs/build-log.md`:

- lock state shows the skeleton on the opponent; loss of tracking removes it;
- a markerless shot from either phone is accepted by Convex (no `LOCATION_STALE`) and the ledger row has origin/direction/impact;
- the other phone shows the incoming beam within one snapshot round-trip, and immediately when the peer link is connected;
- five consecutive shots where both HUDs and the spectator agree on hit/miss.
