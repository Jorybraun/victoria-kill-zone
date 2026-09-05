# PEW PEW Projectile Time, Shared Space, and Content Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Research and define a credible PEW PEW projectile system in which one player can perceive and react to slowed incoming bullets, every participant can see every active bullet, and a spectator can view the arena grid and projectile traffic in realtime, then turn the work into educational content.

**Architecture:** Keep Convex authoritative for discrete gameplay state, projectile spawn/resolution records, ammunition, damage, and the spectator ledger. Use ARKit plus MultipeerConnectivity to establish a shared local coordinate frame, then reconstruct projectile motion locally from compact spawn data rather than streaming 60 Hz positions through Convex. Treat personal bullet time as a gameplay rule that changes the target's effective incoming projectile timeline, not merely a post-processing effect.

**Tech Stack:** Swift, SwiftUI, ARKit, Vision, MultipeerConnectivity, Core Location, Convex, React, TypeScript, Vite.

---

## Why this is a new product slice

The current prototype is intentionally hitscan. It evaluates the latest Vision pose in screen space, sends a discrete claim, and lets Convex atomically apply ammunition, damage, score, events, and respawn. The current specification explicitly keeps high-frequency movement local and retains the ARKit ray only for future spatial validation.

The current iOS code already creates a spatial `SCNSphere` at the camera muzzle and moves it 25 metres forward through the local SceneKit scene over 0.4 seconds. It also creates a spatial beam and synthetic impact. These are real local AR scene nodes, but they are short-lived visual effects on one phone. They have no shared projectile identity, authoritative lifetime, collision state, target-relative time scale, or spectator representation.

The proposed experience is materially different:

- Existing local spatial bullet effects become persistent shared gameplay entities with position, direction, speed, lifetime, owner, target, and resolution.
- Each player sees all active bullets in the same physical arena.
- One player can experience slowed incoming hostile bullets without globally slowing the other player.
- The spectator sees a top-down arena grid with live projectile paths.
- Physical movement becomes part of the dodge mechanic, so collision can no longer be decided only at trigger time.

This should not be presented as a visual polish pass. It changes targeting, networking, authority, synchronization, spatial alignment, replay, UI, and game balance.

## Product thesis

The interesting idea is not conventional slow motion. It is **personal time** inside a shared physical arena.

A shooter fires in normal time. The target sees the same incoming projectile stretched across a longer local reaction window. The shooter continues moving normally. The spectator can see both the projectile's shared spatial path and the temporal effect applied to its target.

The central design challenge is causality: two players cannot independently decide when the same projectile hits. The system needs one authoritative resolution rule while permitting different local presentations of time.

## Research hypothesis: target-local temporal field

Research three possible semantics before implementation:

1. **Cinematic-only slowdown:** The target sees a slower bullet, but server collision time does not change. Reject unless testing shows it still communicates useful information, because it creates no real dodge opportunity.
2. **Target-local dodge time:** Incoming hostile projectiles receive a target-specific time scale. The authoritative hit deadline is extended for that target, while the shooter remains in normal time. This is the recommended hypothesis because it matches the stated player experience.
3. **World-space time bubble:** Projectiles slow when they enter a physical volume around a player, and all observers see that spatial effect. This is easier to explain but no longer affects only one player's experience.

A prior multiplayer bullet-time design localized temporal distortion around a player and treated deterministic projectiles differently from unpredictable players. It also identified causality, jitter, proximity, and visible discontinuities as core risks.[5]

## Proposed spatial model

### Spatial foundation gate

This gate comes before networking, Convex projectile persistence, collision, spectator rendering, or personal time.

A projectile is not itself a matrix. It is a spatial state expressed inside a coordinate frame:

- position: homogeneous point `[x, y, z, 1]`;
- direction or velocity: vector `[x, y, z, 0]`;
- frame conversion: a 4×4 transform matrix;
- motion: a deterministic function of spawn state and elapsed time.

The first architecture requirement is therefore: **every projectile spawn must be represented in one canonical shared 3D arena frame, and both phones must be able to transform that same spawn into their local ARKit render frames.**

Before this gate passes, the existing `SCNSphere` remains a local spatial effect. After it passes, both phones can identify and render the same projectile at the same measured physical location.

Required invariants:

- use right-handed, metre-based coordinates consistent with ARKit;
- freeze axis meanings and matrix multiplication convention in the shared contract;
- distinguish points from direction vectors so translation never changes velocity;
- normalize projectile direction before accepting a spawn;
- reject non-finite and non-invertible transforms;
- bind every transform and projectile spawn to a monotonic sample time;
- retain one canonical `arenaFromDevice` transform per participant and derive its inverse rather than maintaining two independent transforms;
- keep geographic latitude/longitude outside projectile collision math;
- pause spatial gameplay when relocalization or transform quality falls below the accepted threshold.

Spatial acceptance proof:

1. Place at least three non-collinear test anchors in the host arena frame.
2. Relocalize the guest into that frame.
3. Render the same anchor IDs and one moving projectile on both phones.
4. Measure positional disagreement at 3, 8, and 15 metres.
5. Move both phones, interrupt tracking, recover, and repeat the measurements.
6. Do not proceed to personal time until the agreed error and recovery thresholds pass.

### Shared local arena coordinates

Use a host-defined AR world coordinate frame for projectile simulation. The host captures an `ARWorldMap`; the guest receives it and relocalizes. Apple documents this host-guest pattern and recommends sharing only the compact information required to recreate subsequent actions after devices share the same map.[1]

The arena frame should define:

- origin: host's shared-world anchor;
- horizontal axes: local metre-space X/Z plane;
- vertical axis: ARKit Y;
- arena radius and optional rectangular visualization bounds;
- transform from each participant's AR session into the shared frame;
- mapping quality and relocalization status;
- a coarse geographic origin and heading for presentation only.

Core Location must not determine metre-scale projectile collision. Apple defines `horizontalAccuracy` as the radius of uncertainty around the reported latitude/longitude.[2] GPS remains useful for arena discovery, geofence safety, and placing the local arena approximately on a geographic map.

### Projectile representation

Research and freeze a compact projectile contract similar to:

```text
projectileId
matchId
shooterId
targetId
spawnedAtServer
originShared[3]
directionShared[3]
speedMetersPerSecond
radiusMeters
maxLifetimeMs
targetTimeScale
state: active | hit | missed | expired | cancelled
resolvedAtServer
```

Do not stream projectile positions. Persist the spawn parameters and terminal resolution. Each surface computes position from authoritative time and the projectile curve. Apple explicitly gives shared AR projectiles as an example where peers can exchange initial position and velocity as a custom data type.[1]

### Convex boundary

Convex should own:

- projectile spawn acceptance;
- ammunition and cooldown;
- target time-scale entitlement;
- terminal hit, miss, expiry, or cancellation;
- damage and score;
- immutable projectile/event history;
- sanitized spectator projection.

Convex should not own:

- camera frames;
- Vision joints;
- per-frame AR transforms;
- 60 Hz projectile positions;
- rendering interpolation.

Convex queries automatically update subscribed clients when their database dependencies change, and subscriptions receive a consistent database snapshot.[3] Its deterministic mutations are atomic and use optimistic concurrency control with serializable results, which fits one mutation changing ammunition, projectile state, health, and events together.[4]

### Realtime grid visualization

Build two related visualizations:

1. **In-phone spatial overlay:** visible projectiles, trails, ownership colour, inbound warning, time-scale halo, shared-origin diagnostics, and relocalization quality.
2. **Spectator command grid:** top-down local metre grid, both player transforms, active projectiles, trails, spawn and resolution markers, temporal-field radius, event list, and optional coarse geographic context.

The spectator should reconstruct paths from spawn data and `serverNow`, then animate locally. A fresh Convex snapshot replaces authoritative projectile state; the browser must de-duplicate projectiles and events by record identity.

## Research questions to answer before freezing design

### Time semantics

- What activates personal bullet time: passive ability, limited charge, pickup, kill streak, or manual trigger?
- What is slowed: all hostile bullets, only bullets inside a radius, or one selected threat?
- What is the target time scale: start with `0.25`, `0.5`, and `0.75` prototypes.
- How long can the effect remain active?
- Does the target move at normal physical speed while incoming bullets slow?
- When does the shooter receive hit or miss confirmation?
- Can multiple temporal fields affect one projectile?

### Collision and fairness

- Is collision a swept sphere against a body volume or a target pose history?
- Which device supplies the target transform history?
- How much history is retained and at what sample rate?
- What happens when peer spatial data drops but Convex remains connected?
- What happens when shared-world relocalization quality degrades?
- What is the maximum acceptable divergence between the two rendered projectile positions?
- How is cheating disclosed and bounded for the prototype?

### Visibility and readability

- How many projectiles can be active before the phone view becomes unreadable?
- Which bullets receive full trails versus compact indicators?
- How is an inbound projectile distinguished from an outbound or expired one without relying only on colour?
- Does the target see predicted impact time and closest approach?
- Does the shooter see the target's temporal field, or only delayed resolution?
- Which view is the spectator showing: shared world time, target-local time, or both?

### Spatial calibration

- How long does host mapping and guest relocalization take outdoors?
- What environmental features are required for stable shared mapping?
- How does drift change at 3, 8, 15, and 30 metres?
- Can the grid be re-anchored without invalidating active projectiles?
- Is a manual shared anchor or printed floor calibration needed as a fallback?

## Research prototypes, in order

### Prototype R1: Deterministic 3D transform simulator

Prove the coordinate conventions and projectile math without ARKit, networking, or Convex.

Acceptance evidence:

- canonical arena frame plus two simulated device frames;
- round-trip point/vector transforms within a frozen numerical tolerance;
- translation changes points but not direction vectors;
- projectile spawn from shared origin, normalized direction, speed, and monotonic timestamp;
- both simulated devices reconstruct the same shared projectile position;
- invalid and non-invertible matrices fail closed;
- deterministic tests freeze matrix order, handedness, axes, units, and time semantics.

### Prototype R2: One-phone AR projectile field

Render multiple synthetic projectiles in one ARKit world frame.

Acceptance evidence:

- projectile paths remain anchored while the phone moves;
- visible trail and inbound warning remain readable;
- frame time and thermal behavior recorded on the target phone;
- no networking claim.

### Prototype R3: Two-phone shared coordinates

Share an AR world map and confirm both phones render static anchors and moving projectiles in the same physical locations.

Acceptance evidence:

- host and guest device models and OS versions;
- mapping/relocalization state shown on screen;
- measured alignment error at several distances;
- recovery behavior after temporary tracking loss;
- no Convex damage yet.

### Prototype R4: Desktop personal-time simulation

Add temporal behavior only after the shared 3D projectile model is proven.

Acceptance evidence:

- two players and projectiles in the canonical 3D arena frame;
- normal-time shooter view;
- target-local slowed inbound view;
- one authoritative hit or miss outcome;
- top-down spectator grid;
- repeatable recording showing shared space under all three timelines.

### Prototype R5: Convex projectile ledger

Add compact spawn and terminal events to authoritative state while keeping animation local.

Acceptance evidence:

- one spawn decrements ammunition once;
- replaying a `clientProjectileId` is idempotent;
- both phones and spectator receive the same projectile identity;
- one terminal resolution applies damage once;
- reconnect reconstructs active projectiles without duplicate trails or damage.

### Prototype R6: Personal bullet-time duel

Apply target-local incoming time scaling and physical dodge resolution.

Acceptance evidence:

- shooter remains in normal time;
- target sees inbound projectile at the configured slower scale;
- target physically dodges one projectile and is hit by another;
- shooter, target, and spectator converge on one outcome for each projectile;
- spectator displays the temporal effect without pretending all observers share one visual clock.

## Educational content series

Every item publishes only after its named evidence exists.

### 1. Why hitscan was the right first lie

Explain why the current prototype uses screen-space hit claims and discrete Convex mutations. The point is not to apologize for the prototype. The point is to show how a constrained first system proves identity, authority, synchronization, and feedback before adding spatial projectiles.

Evidence required: existing dual-phone debug/markerless recording, current shot mutation, and synchronized spectator state.

### 2. Convex runs the battle, not the frame loop

Teach the boundary between authoritative events and local simulation: Convex owns spawn, ammo, damage, score, and the ledger; phones reconstruct smooth motion from timestamps.

Evidence required: architecture diagram, one atomic projectile mutation, idempotent retry test, and three-surface recording.

### 3. Giving two iPhones the same space

Show the host world map, guest relocalization, shared anchor, coordinate transforms, drift measurement, and failure state.

Evidence required: R3 recording and measured alignment table.

### 4. Designing personal time in multiplayer

Introduce target-local temporal fields, explain why the shooter cannot simply be globally slowed, visualize the projectile worldline under multiple clocks, and show the chosen causality rule.

Evidence required: R4 simulator plus written product decision on time semantics.

### 5. Making every bullet visible

Explain projectile reconstruction, trails, impact prediction, clutter limits, and why initial position, velocity, timestamp, and terminal state are enough for smooth rendering.

Evidence required: R2 performance capture and R5 synchronized identities.

### 6. Turning the arena into a live data sculpture

Show the top-down metre grid, player positions, bullet paths, time fields, impacts, misses, and the relationship between the shared AR frame and coarse geographic arena placement.

Evidence required: spectator grid recording and an honest GPS-versus-AR coordinate explanation.

### 7. The finished PEW PEW build story

Combine ARKit, Vision, Convex, personal bullet time, physical dodging, the command grid, and the agent-assisted build workflow into one X Article and one short native video.

Evidence required: continuous physical-device duel on one Git SHA and one Convex deployment, with device models, OS versions, browser version, and observed outcomes.

## Content formats

For each technical chapter, produce:

- one 30–60 second native X video;
- one short post with a single argument;
- one diagram or annotated frame;
- one longer X Article or project-page section;
- one source/evidence reply containing code, paper, or documentation links;
- one build log entry stating what failed and what changed, without turning the story into complaint content.

## Likely implementation ownership and files

This plan does not authorize edits. Future implementation crosses multiple exclusive write boundaries and requires separate owners.

- Integration: shared contracts, Xcode project/workspace, root verification, evidence wiring.
- Backend: `convex/functions/schema.ts`, `convex/functions/shots.ts`, new projectile functions, `convex/domain/**`, backend tests.
- iOS targeting: `ios/**/Targeting/**`, AR world sharing, projectile reconstruction, collision inputs, targeting tests.
- Spectator: `spectator/**`, command-grid rendering and tests.
- Design: a new accepted slice under `design/slices/`, fixed states, temporal-field language, grid tokens, accessibility, and evidence.
- Product authority: `victoria-kill-zone-technical-spec.md` only after a decision record accepts projectile and personal-time behavior.

## Verification gates

- Run targeted tests during each slice.
- Run `pnpm verify` before review.
- Record physical-device evidence for camera, AR mapping, networking, haptics, and mirroring.
- Record device model, OS version, Git SHA, Convex deployment, browser/version, and observed result.
- Treat simulator runs as development evidence only.
- Do not remove the current debug-fire path until physical-device evidence proves the replacement.
- Do not claim metre-accurate GPS projectile placement.
- Do not claim 3+ player markerless identity until shared spatial association is implemented and demonstrated.

## Open product decisions

1. Choose personal-time semantics: cinematic, target-local dodge, or world-space bubble.
2. Choose activation and resource model.
3. Choose projectile speed, radius, lifetime, and maximum active count.
4. Choose authoritative collision source: target confirmation, host arbiter, or Convex resolution from submitted histories.
5. Choose the spectator's time representation.
6. Choose outdoor calibration and fallback procedure.
7. Choose whether the first release remains 1v1 or introduces 3+ player identity later.
8. Decide whether “geo grid” means a local metre grid with geographic context, or a true geospatial cell system. The recommended first version is the local metre grid.

## Sources

[1] https://developer.apple.com/documentation/arkit/creating-a-multiuser-ar-experience — Apple: Creating a multiuser AR experience
[2] https://developer.apple.com/documentation/corelocation/cllocation/horizontalaccuracy — Apple: CLLocation horizontalAccuracy
[3] https://docs.convex.dev/realtime — Convex Realtime
[4] https://docs.convex.dev/database/advanced/occ — Convex OCC and Atomicity
[5] https://staff.cs.utu.fi/~jounsmed/papers/NG04_BulletTime-Slides.pdf — Realizing Bullet Time in Multiplayer Games with Local Perception Filters
