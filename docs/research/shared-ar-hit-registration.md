# Shared AR hit registration research

> **Status: research, not authority.** This brief is the investigation that led to the frozen packet. Where it differs from [the requirements](../features/shared-spatial-hit-registration/requirements.md), the requirements win. Two things have changed since it was written: the player set is **2–4**, not two, and the product decisions it lists at the end are now mostly answered — see "Decisions taken since this brief". It still uses the older prototype name; the current product is Victoria Kill Zone.

## Question

Can the game treat each phone as the player's networked target, place 2–4 phones in one shared 3D arena, and use FPS-style latency compensation to decide whether a shot hit?

## Conclusion

Yes. This is a credible first shared-space hit model and substantially simpler than reconstructing a full human body in 3D.

The recommended first implementation is **phone-proxy hitscan with bounded server rewind**:

1. Every phone in the match relocalizes into one shared ARKit arena frame.
2. Each phone samples its camera transform against a monotonic clock.
3. Each phone sends a bounded history of timestamped transforms.
4. The shooter submits a shot ray and shot timestamp.
5. The authority estimates when the shot occurred in arena time.
6. It rewinds each candidate phone proxy to its interpolated historical transform.
7. It tests the shot ray against the historical proxy volumes.
8. It records one authoritative hit or miss.

This is the established shape of latency-compensated hitscan: the server retains recent target history and temporarily evaluates a shot against the target state the shooter saw. Valve documents server rewind explicitly and reports retaining one second of player location and animation history by default.[1] A client/server shooter still keeps the server authoritative over simulation and rules while clients use prediction and interpolation to hide network delay.[2]

This should be implemented before persistent visible projectiles or personal bullet time. It gives PEW PEW a measurable shared 3D hit model without requiring a 60 Hz Convex physics loop.

## Latency architecture

Convex must not sit inside the frame-by-frame spatial loop. Convex provides reactive WebSocket subscriptions and consistent snapshots,[4] but its documentation does not promise a fixed game tick rate or a numeric upper-bound latency suitable for 60 Hz physics.

Split the system into two clocks:

### Local realtime plane

- ARKit tracking and rendering: 60 fps when the device sustains it.
- Phone transform exchange: prototype at 20–30 Hz over a nearby peer transport, for every member of the set.
- Transform history, interpolation, rewind, ray intersection, and visible projectile reconstruction: local/host computation.
- Muzzle flash, haptics, audio, and predicted tracer: immediate local feedback.

### Convex authority and sync plane

- match identity, capability authentication, ammo, health, score, cooldown, and lifecycle;
- accepted shot/projectile spawn and terminal outcome;
- idempotency and conflict handling;
- spectator and reconnect snapshots;
- durable evidence and replay inputs.

The host may produce a provisional spatial verdict immediately, but damage is committed once through Convex. Clients render feedback optimistically, then reconcile to the Convex result. A rejected or conflicting result must visibly correct local prediction.

Initial budgets to validate, not assume:

```text
render frame                 <= 16.7 ms at 60 fps
phone pose sample interval   <= 50 ms at 20 Hz
peer pose age at evaluation  <= 100 ms
local fire feedback          same frame
host spatial verdict         <= 50 ms after receiving claim
Convex authoritative result  measure p50 / p95 / p99 on real devices
```

The prototype gate must record end-to-end timestamps for fire input, peer receipt, host verdict, Convex mutation completion, subscription delivery, and rendered reconciliation. If Convex p95 causes noticeable damage confirmation delay, retain Convex as the durable authority while allowing the host verdict to drive provisional UI. If the game later supports remote players rather than two devices in one physical arena, replace the peer host with a dedicated realtime simulation service; Convex can remain the control and persistence plane.

## What is publicly known about Call of Duty

Public discussion commonly describes Call of Duty hit registration using latency compensation and historical target state. I did not find an official Activision engineering source that specifies the current production algorithm, rewind window, tick rate, trust model, or exact hitbox policy. We should therefore say **FPS-style server rewind**, not claim that PEW PEW reproduces Call of Duty's implementation.

Valve's public documentation provides a concrete, inspectable reference implementation for the same general family of techniques.[1][2]

## Current PEW PEW behavior

The current game does not perform shared 3D hit registration:

- Vision creates a 2D head or torso region in the shooter's camera image.
- The local crosshair intersects that screen-space region.
- ARKit provides the shooter's camera origin and forward direction.
- The phone submits the claimed opponent, zone, confidence, origin, direction, and client time.
- Convex validates the game rules but immediately applies damage from the claimed target and zone.
- Convex does not persist the 3D ray or calculate an intersection.
- The visible `SCNSphere` is a local SceneKit effect, not a shared projectile.

Relevant implementation:

- `ios/VictoriaKillZone/VictoriaKillZone/Features/Lobby/LobbyStore.swift:461-503`
- `ios/VictoriaKillZone/VictoriaKillZone/Features/Game/LaserFX.swift:23-109`
- `convex/functions/shots.ts:126-197`
- `convex/functions/schema.ts:104-124`
- `convex/domain/fire.ts:130-159`

## Why the phone can be the first target

ARKit already estimates each phone camera's 6-DoF transform. After the devices share an `ARWorldMap`, they can render content at the same real-world positions. Apple describes using a host-provided world map, guest relocalization, and compact world-space action data after alignment.[3]

For the first shared hit model, define the target as a collision volume attached to the target phone transform:

```text
PhonePoseSample
  playerId
  sampledAtMonotonic
  sampledAtServerEstimate
  arenaFromPhone: 4x4 transform
  trackingQuality
  sequence
```

```text
PhoneTargetProxy
  center: phone position in arena coordinates
  orientation: phone orientation in arena coordinates
  shape: sphere, capsule, or oriented box
  dimensionsMeters
```

The simplest prototype is a sphere around the phone. An oriented box more closely represents the device but is too small for enjoyable play. A capsule or sphere with a configurable radius gives a deliberate game target rather than pretending to model anatomy.

### Advantages

- The target has a real 3D position and stable player identity.
- No cross-device body-skeleton association is required.
- Historical transforms are compact enough to retain and test deterministically.
- Hit registration can be visualized as a ray, rewound proxy, and intersection.
- It works without requiring GPS accuracy.
- It creates the foundation for a spectator arena grid.

### Limitations

- It proves a hit on the phone proxy, not the player's body.
- A player can move the phone independently of their body.
- Target size is a game-design choice and must be disclosed.
- ARKit drift can dominate network-latency error.
- Tracking failure must pause spatial hit registration rather than reuse stale transforms.
- Players may move phones aggressively near one another, so safety and minimum-range rules matter.

## Shared spatial frame

Use one host-defined, right-handed, metre-based arena coordinate frame. Apple recommends sharing the world map once, then transmitting only the data needed to recreate ongoing actions; it specifically gives initial projectile position and velocity as an example of compact shared action data.[3]

The geographic arena and projectile arena have different jobs:

- Core Location: coarse venue position, geofence, spectator context.
- Shared ARKit frame: phone poses, shot rays, proxy volumes, projectile motion, collision.

Never use latitude and longitude for metre-scale hit registration.

## FPS-style hitscan algorithm

### Input histories

Retain a rolling history for each phone:

```text
transformHistory[playerId] = [
  { sequence, sampledAt, arenaFromPhone, trackingQuality }
]
```

A first prototype should test history windows between 250 ms and 1 second. Valve's documented default is one second, but PEW PEW should choose its own bounded maximum based on measured local and internet latency rather than copying it blindly.[1]

### Shot claim

```text
ShotClaim
  clientShotId
  shooterId
  firedAtMonotonic
  serverTimeEstimate
  originArena
  directionArena
  localPoseSequence
  targetId
```

The origin and direction must come from the same AR frame and timestamp. The current implementation combines Vision evidence with the latest independently updated camera ray; that must be replaced by one frame-aligned sample before authoritative 3D checks are credible.

### Rewind time

Conceptually:

```text
rewindTime = serverReceiveTime
             - boundedEstimatedOneWayDelay
             - boundedClientInterpolationDelay
```

Do not trust an arbitrary client timestamp. Estimate clock offset through repeated ping/pong samples, reject implausible values, cap maximum rewind, and require monotonically increasing sequences.

### Intersection

1. Interpolate the target phone transform between the two history samples surrounding `rewindTime`.
2. Construct the target proxy at that historical transform.
3. Raycast from `originArena` along normalized `directionArena`.
4. Apply range, cooldown, ammunition, tracking-quality, and rewind-window checks.
5. Record one idempotent authoritative result.

This follows the attacker-favoring logic of evaluating what the shooter saw. The trade-off is that the target may be hit after moving away, because the historical proxy still intersects the shot. That fairness policy needs an explicit maximum rewind and product decision; it is now 250 ms, and the consequence is disclosed to players.

## Hitscan versus visible projectiles

### Hitscan

A hitscan shot is an instantaneous ray evaluated at one historical time. Server rewind is a good fit:

- compact input;
- one historical target lookup;
- one ray/proxy intersection;
- immediate result;
- easy deterministic tests.

This is the recommended next slice.

### Persistent visible projectile

A visible bullet occupies a path over time. Rewinding only the target at the trigger moment is insufficient. The authority must evaluate the projectile worldline against target history over an interval:

```text
projectilePosition(t) = origin + direction * speed * (t - spawnedAt)
```

For each interval, use a swept collision test between projectile motion and the target proxy trajectory. Store the spawn and terminal state, not every frame. Convex can distribute compact spawn/resolution snapshots consistently to subscribers,[4] while phones and spectator render intermediate positions locally.

This is where personal bullet time eventually belongs: it modifies the projectile's effective worldline or target interaction policy. It should not be introduced until normal-time shared collision passes.

## Convex role

Convex is suitable for authoritative event state, idempotency, ammunition, damage, score, projectile spawn records, terminal outcomes, and consistent reactive snapshots.[4]

Convex should not receive or broadcast every render frame. For the first hitscan slice:

- phones or a designated local host maintain high-rate transform history;
- the shot resolution mutation receives bounded historical evidence or a signed host verdict;
- Convex validates identity, sequence, limits, cooldown, ammo, and idempotency;
- Convex records the authoritative result.

Before implementation, choose one authority model:

1. **Convex computes the rewind intersection.** Strongest central authority, but requires uploading enough transform history and implementing deterministic matrix/intersection math in TypeScript.
2. **Target phone computes and attests the intersection; Convex requires compatible shooter and target claims.** Better access to high-rate local history, but depends on both clients.
3. **Host phone arbitrates; Convex validates and records the verdict.** Lowest latency and simplest prototype, but host trust is explicit.

Recommendation for Phase 0: prototype option 3, then compare option 1 once the transform contract and evidence format are stable. Do not imply production anti-cheat.

**Accepted:** option 3 is the Phase 1 behavior. Whether authority stays on the host phone or moves to a server process is KIL-21 measurement work feeding ADR 0004.

## Proposed implementation sequence

### H1: Shared phone transforms

- Align every phone in the match to one AR world map.
- Broadcast timestamped `arenaFromPhone` transforms at 10–20 Hz.
- Retain a 1-second local ring buffer.
- Render each phone's proxy on both devices.
- Measure transform disagreement and recovery after tracking interruption.

### H2: Offline rewind evaluator

- Pure deterministic module.
- Interpolate historical transforms.
- Construct sphere/capsule proxies.
- Perform ray intersections.
- Test clock skew, late packets, missing history, stale tracking, and bounded rewind.

### H3: Live phone-proxy hitscan

- Submit one frame-aligned shot claim.
- Rewind the target proxy.
- Resolve hit/miss once.
- Persist the evidence and result.
- Display the shot ray and rewound proxy in a debug view.

### H4: Spectator reconstruction

- Show current phone poses.
- Show shot rays and historical intersection points.
- Label rewound versus current target position.
- Display latency and tracking-quality diagnostics.

### H5: Persistent projectile worldlines

- Add projectile identity, spawn state, speed, lifetime, and terminal state.
- Reconstruct positions locally.
- Test swept collision against target transform history.

### H6: Personal time

- Decide whether the temporal effect changes the authoritative worldline, target collision policy, or presentation only.
- Add it only after H5 passes in normal time.

## Required product decisions

1. Is the target a sphere, capsule, or oriented box around the phone?
2. What target dimensions are fair and safe?
3. What is the maximum rewind window?
4. Is the authority Convex, the target phone, or the host phone?
5. What tracking-quality threshold pauses firing?
6. What transform disagreement is acceptable at 3, 8, and 15 metres?
7. Does the phone proxy represent the player's whole body or a deliberate game objective?
8. What minimum player separation prevents unsafe close-range play?

## Decisions taken since this brief

KIL-18 answers the questions that fix meaning. The requirements document is the authority for each; they are listed here only so this brief is not read as still open.

| Question | Decision |
|---|---|
| 1, 2, 7 | Sphere of exactly 0.35 m radius, uniform for every player, device, and distance. It is a deliberate game objective, never a body claim. Capsule or oriented box is Phase 2. |
| 3 | 250 ms maximum rewind, inclusive, never clamped or extended. This repository's own prototype cap, not a claim about any commercial title. |
| 4 | Option 3: the `authorityHost` phone produces a provisional verdict, and Convex commits the authoritative state change exactly once. Host trust is disclosed, and no production anti-cheat is claimed. Option 1 stays the candidate hardening for ADR 0004. |
| 5 | Anything short of a confidently relocalized, normally tracking frame is `lost` and locks fire on that phone only. The device-side signal that maps to "normal" is KIL-20 measurement work. |
| 6 | Deliberately still open. It is measurement work owned by KIL-20; until then no tolerance is claimed and a perceptibly wrong verdict blocks the physical-device gate. |
| 8 | 3 m minimum and 15 m maximum, as a property of a candidate target and as safety guidance — never as a trigger lock. |

Two mechanics were settled by the product owner after this brief and are not reflected in the algorithm sketches above:

- **A lock is never a precondition for firing.** While the fire gates are open, a trigger press always produces one shot from the current normalized camera ray, and a shot with no candidate is an authoritative **miss** that consumes ammunition and is recorded. Proxy or Vision detection is advisory feedback. The sketches above that pass a `targetId` with every claim describe an older contract shape, not the accepted mechanic: `match.v2` already carries `targetId` as optional and the Convex fire path already resolves a no-target shot as a miss. The one place that still requires a target is `ShotClaim.targetID` in `shared/simulation`, and aligning it is KIL-22 shared-contract work with an Integration handoff — not KIL-19, which is an isolated iOS targeting/domain prototype.
- **Every member sees shot presentation.** The shooter gets an immediate predicted tracer, and every other member gets one transient incoming-shot tracer per shot identity, drawn from the shared-arena origin and direction, including for misses. It is deduplicated by shot identity, never replayed on confirmation or reconnect, and remains hitscan presentation — the persistent-projectile section below stays future work.

## Recommendation

Build **shared phone-proxy hitscan with bounded rewind** first. It combines the useful part of FPS networking with what ARKit can actually measure:

- the phone is a known target with a timestamped 3D transform;
- the shot is a frame-aligned ray in the same arena coordinates;
- latency compensation evaluates the historical target state;
- Convex owns the resulting game-state transition;
- Vision remains optional for later body-zone refinement.

Once this works across the 2–4 phones in a match, evolve the same spatial and temporal history into persistent visible bullets. Do not design personal time directly on top of the current screen-space hit claim.

## Sources

[1] https://developer.valvesoftware.com/wiki/Lag_Compensation — Valve: Lag Compensation
[2] https://developer.valvesoftware.com/wiki/Source_Multiplayer_Networking — Valve: Source Multiplayer Networking
[3] https://developer.apple.com/documentation/arkit/creating-a-multiuser-ar-experience — Apple: Creating a multiuser AR experience
[4] https://docs.convex.dev/realtime — Convex: Realtime
