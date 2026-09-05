# ADR 0006: Duel shared frame — map-seeded body tracking over `CombatTransport`

Implementation correction, 2026-09-05: this historical proposal's head/neck-to-phone offset and saved-anchor readback are **not independent alignment measurements**. Its assumption that the target's head is at their camera is also invalid. Do not implement those shortcuts or the degraded-state spatial-fire fallback below. [ADR 0008](0008-realtime-combat-implementation.md) owns the current authority/geometry implementation scope; [ADR 0009](0009-natural-scene-calibration-candidate.md) specifies the fresh natural-scene reference candidate and its visibility limitation. This proposal remains unaccepted pending physical evidence.

| Field | Value |
|---|---|
| Status | **Proposed** (2026-09-04). Becomes Accepted only with the two-phone evidence in §7 recorded in `docs/build-log.md`. |
| Owner | Integration (decision, contracts, sequencing); iOS targeting (calibration + frame provider); iOS game (duel UX + beams); Backend (ledger fields); Hardware/Operator (evidence). |
| Supersedes | The "body tracking cannot coexist with world-map sessions" consequence in [ADR 0005](0005-duel-body-tracking-and-visible-shots.md) (corrected below). Narrows the collaborative-session preference in [docs/research/shared-arena-frame-options.md](../research/shared-arena-frame-options.md) for the duel. |
| Does not change | [ADR 0004](0004-realtime-combat-authority-and-transport.md) host authority, `CombatTransport`, Convex as the durable ledger. `shots:debugFire` and the `DEBUG TORSO FALLBACK` button stay until physical-device evidence exists. `archive/` untouched. |

## TL;DR

1. **The problem:** a shot is rendered on the shooter's phone from the shooter's camera to the opponent's skeleton, and on the target's phone from "somewhere ahead". The two phones have unrelated coordinate origins, so today the beam is not the same real-world line on both screens. ADR 0004 assumed a shared frame that ADR 0005's body tracking appeared to forbid.
2. **The decision:** align once, then track bodies. Both phones spend a ~10 s calibration step in `ARWorldTrackingConfiguration` looking at the same scenery; the host captures an `ARWorldMap` and sends it over the `CombatTransport` bulk stream; **both phones then restart in `ARBodyTrackingConfiguration` with `initialWorldMap` set to that same map**, which Apple documents as supported. From then on both phones share one origin, stream their own camera pose at 20 Hz over the peer plane, and the skeleton from ADR 0005 keeps working for aiming.
3. **Drift is real and measured, not assumed.** ARKit VIO error published in benchmarks is on the order of 0.02 m per second of motion and 1–43 cm per relocalization event; our residual budget from prior research is 0.10 m / 0.5°. The receiver's own body tracking of the shooter gives a free, continuous alignment check (observed skeleton vs. the shooter's self-reported pose); if it exceeds budget, the beam falls back to a coarse render and spatial fire is locked (fail closed) until re-alignment.
4. **Rejected as the primary frame:** collaborative sessions (world-tracking only), Vision 3D body pose instead of ARKit body tracking (single skeleton, 1.8 m reference-height scale error without depth), GPS + heading / `ARGeoTrackingConfiguration` (metres of error; coverage limited to publicly driveable streets and must be probed at runtime — no public evidence Victoria, BC is covered). Receiver-confirmed hits are adopted as a **signal**, not as a substitute for a frame.
5. **What follows:** eight PR-sized slices (§9), the first of which is a two-phone spike proving body tracking relocalizes into a peer's map outdoors. Under this decision `ArenaPeerLink`, the collaborative branch of `SharedArenaSession`, the legacy `ArenaHitEvaluator`, and the "screen-top, 3 m ahead" incoming-beam fallback become unfit and are deleted in named slices (§8).

## 1. Context

- ADR 0004 (target architecture): host-phone `MatchSimulation` verdicts, `CombatTransport` peer plane (QUIC reliable streams + datagrams, Bonjour discovery; **not yet linked into the app**), capsule hit zones anchored to each phone's pose, Convex as ledger. Its shot geometry assumes every phone pose is expressed in one shared frame.
- ADR 0005 (shipped, PR #44 / TestFlight build 16; hardened in PR #46): `ARBodyTrackingConfiguration` locks the opponent's skeleton, the shooter fires along its camera ray, Convex stores `origin/direction/impact` **in the shooter's own frame**, and every phone renders incoming beams from Convex events plus the harness-grade `ArenaPeerLink` (Bonjour + TCP) fast path. Because the receiving phone has no frame relationship with the shooter, `ActiveDuelView` draws the incoming beam from a point 3 m ahead of its own screen top when it does not happen to be tracking the shooter's body.
- Code today picks one configuration or the other (`ARVisionTargetingSession.startWorldTracking`: `ARBodyTrackingConfiguration` when supported, else `ARWorldTrackingConfiguration`), and the KIL-20 shared-arena harness (`SharedArenaSession`) uses world tracking with either collaboration or a world-map handoff. Nothing bridges the two.
- Product direction (owner, 2026-09-04): shots visible in real time on both phones with a beginning and an end; local-network transport between players; body tracking for targeting; Convex stays authoritative and durable; delete code that isn't fit.

### Apple facts this decision rests on (primary sources)

| Fact | Source |
|---|---|
| `ARWorldMap` generation requires a world-tracking session; `getCurrentWorldMap` on another configuration returns an error. Apple's documented use of a map is exactly "two devices tracking the same world map" for a shared experience. | [ARSession.getCurrentWorldMap](https://developer.apple.com/documentation/arkit/arsession/getcurrentworldmap(completionhandler:)), [ARWorldMap](https://developer.apple.com/documentation/arkit/arworldmap) |
| `ARBodyTrackingConfiguration` exposes `initialWorldMap`; i.e. a body-tracking session **can be seeded with (relocalize into) a world map**, it just cannot produce one. | [ARBodyTrackingConfiguration](https://developer.apple.com/documentation/arkit/arbodytrackingconfiguration) |
| Running a configuration of a *different type* than the current one **always resets tracking** (origin and anchors). A world→body switch therefore destroys the frame unless the body session is re-seeded with the map. | [ARSession.run(_:options:)](https://developer.apple.com/documentation/arkit/arsession/run(_:options:)), [RunOptions.resetTracking](https://developer.apple.com/documentation/arkit/arsession/runoptions/resettracking) |
| Collaborative sessions (`isCollaborationEnabled`, `ARSession.CollaborationData`, `ARParticipantAnchor`) are a property of `ARWorldTrackingConfiguration`; Apple recommends up to four participants. | [isCollaborationEnabled](https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/iscollaborationenabled), [WWDC19 session 610](https://developer.apple.com/videos/play/wwdc2019/610/) |
| Body tracking yields one `ARBodyAnchor` (the "most prominent" person) per frame; hardware gate is `ARBodyTrackingConfiguration.isSupported` (A12-class or later). | [ARBodyAnchor](https://developer.apple.com/documentation/arkit/arbodyanchor), [ARFrame.detectedBody](https://developer.apple.com/documentation/arkit/arframe/detectedbody), [WWDC19 session 607](https://developer.apple.com/videos/play/wwdc2019/607/) |
| Vision `VNDetectHumanBodyPose3DRequest` returns 17 joints for **one** most-prominent person, camera-relative; height is measured only with depth data, otherwise a **1.8 m reference height** is assumed. | [VNDetectHumanBodyPose3DRequest](https://developer.apple.com/documentation/vision/vndetecthumanbodypose3drequest), [VNHumanBodyPose3DObservation](https://developer.apple.com/documentation/vision/vnhumanbodypose3dobservation), [WWDC23 session 111241](https://developer.apple.com/videos/play/wwdc2023/111241/) |
| `ARGeoTrackingConfiguration` needs GPS, network, and Apple localization imagery captured from **public streets accessible by car**; availability must be probed with `checkAvailability`; gated/pedestrian-only areas are excluded. | [ARGeoTrackingConfiguration](https://developer.apple.com/documentation/arkit/argeotrackingconfiguration), [checkAvailability](https://developer.apple.com/documentation/arkit/argeotrackingconfiguration/checkavailability(completionhandler:)) |

## 2. Error budget (what "the same line on both phones" means numerically)

Carried over from [shared-arena-frame-options.md §3](../research/shared-arena-frame-options.md) and the frozen `shared/simulation` constants (proxy radius 0.35 m, lane 3–15 m, pose age ≤ 100 ms, rewind ≤ 250 ms):

- **Translation residual ≤ 0.10 m** and **yaw residual ≤ 0.5°** between the two phones' estimates of the same physical point. 0.5° of yaw is ≈ 0.13 m of lateral error at 15 m; 1° is ≈ 0.26 m, which is most of a 0.35 m proxy.
- **Drift planning values** (published benchmarks and field reports, *not* measurements of this app): ARKit VIO ≈ 0.02 m per second of motion; 1–43 cm error per relocalization/user action; ≈ 25 cm after a walk-away-and-return. These are the numbers §7 must replace with our own.
- **Consequence:** with no correction, a phone that walks for ~5 s can consume the whole translation budget. The design therefore needs (a) a good initial alignment, (b) ARKit's own relocalization against the seeded map while moving through mapped space, and (c) an independent, continuous residual signal that can lock fire when the budget is exceeded.

## 3. Options evaluated

| | Option | Gives a shared frame? | Works with ADR 0005 body tracking? | Verdict |
|---|---|---|---|---|
| A | Phone-pose sharing over `CombatTransport` + one-time `ARWorldMap` alignment, then VIO dead-reckoning | Yes, one origin for both phones | **Yes** — the body session is seeded with `initialWorldMap`; the switch resets tracking, the map restores it | **Recommended**, with the drift monitor from D |
| B | World tracking (+ collaboration) with Vision `VNDetectHumanBodyPose3DRequest` for targeting instead of ARKit body tracking | Yes (collaboration or map) | Replaces it | Rejected as primary: one skeleton, camera-relative, 1.8 m reference-height scale error on non-LiDAR phones, no ARKit tracking continuity for the skeleton. Kept as a fallback for phones where `isSupported == false`. |
| C | GPS + heading (Core Location) or `ARGeoTrackingConfiguration` | Coarse only | Geo tracking is another configuration type; cannot run with body tracking | Rejected for hit scale (metres, multi-degree compass). Core Location stays for the venue geofence; geo tracking availability is probed once and logged, never relied on. |
| D | Receiver-confirmed hits: target also tracks the shooter; host compares verdicts | No | Yes (both phones already run body tracking) | **Adopted as a signal**: cuts false hits and, in a shared frame, gives a live alignment residual (observed skeleton vs. peer's reported pose). Not a frame by itself. |
| E | 3+ players: what replaces single-body tracking | n/a | n/a | Shared frame + phone-pose capsules become the verdict source (ADR 0004); the single ARKit skeleton becomes aim assist only; Vision 2D multi-person detection associates detections to capsules. Direction only — nothing implemented. |

### A — recommended: one-time alignment, then body tracking, then dead-reckon with a monitor

Flow (both phones, orchestrated by the host over `CombatTransport`):

1. **Calibrate** — both phones run `ARWorldTrackingConfiguration` (gravity-aligned) and film the same ~90° of scenery from ~1 m apart until `worldMappingStatus == .mapped`. Host calls `getCurrentWorldMap`, archives it, and sends it on the bulk stream (already prototyped by `BulkTransfer`).
2. **Relocalize** — guest runs world tracking with `initialWorldMap`; success = tracking state `.normal` with no `.relocalizing` reason. Host and guest each confirm by placing a shared reference anchor and reading it back in metres (this is the §7 residual measurement).
3. **Switch** — both call `run(ARBodyTrackingConfiguration(initialWorldMap: sharedMap))`. Apple documents that a different configuration type resets tracking; seeding with the map is what makes the new session's origin equal the map's origin on both phones. Same fail signal as step 2.
4. **Play** — each phone streams `(matchClockMs, cameraTransform)` at 20 Hz on datagrams (ADR 0004 pose channel). A shot packet carries `origin` and `direction` in the shared frame plus the ADR 0005 skeleton hit zone. The receiver renders the beam from the shooter's pose to its **own** camera position (the target's head is at its own phone), so the beam's beginning and end are the same real-world line on both screens.
5. **Monitor** — whenever a phone's body tracking sees the opponent, compare the observed head/neck joint (in the shared frame) with the opponent's reported pose plus a fixed head offset. That difference is the live residual. Above budget: HUD shows "re-align", beam degrades to a coarse render, host suppresses spatial verdicts (fail closed, `shots:debugFire` still callable). Re-align = repeat steps 1–3 (≈ 10 s), not a match restart.

Why this beats the alternatives: it is the only option that keeps ADR 0005's skeleton lock unchanged, uses only documented API (no configuration is run outside its documented capability), needs one bulk transfer per match instead of continuous collaboration traffic, and has a built-in independent check of its own weakest assumption (drift).

Risks that only two phones can answer (all in §7): whether a body-tracking session relocalizes into a *peer's* map outdoors as reliably as a world-tracking session does; how fast residual grows in a 3-minute duel with players walking; transfer time and size of an outdoor map over the bulk stream; thermal cost of body tracking + 20 Hz streaming.

### B — Vision 3D pose in a world-tracking/collaborative session

Attractive because collaboration (or a map) runs natively and the frame stays a first-class ARKit concern. Rejected as the primary path because WWDC23 states the request returns one skeleton for the most prominent person, camera-relative, and measures height only with depth — otherwise it assumes 1.8 m. On non-LiDAR rear cameras that turns a 1.6 m opponent into a ~12% depth error at every range, well over budget at 15 m. It also loses ARKit's frame-to-frame body tracking. Retained only as the targeting fallback where `ARBodyTrackingConfiguration.isSupported` is false, and as the harness control in `SharedArenaSession`.

### C — GPS + heading / ARGeoTracking

Core Location outdoors is metres, heading is degrees; both are two orders of magnitude outside budget (§2). `ARGeoTrackingConfiguration` is precise where available, but Apple limits it to areas with localization imagery captured from car-accessible public streets and requires `checkAvailability` at runtime; prior research found no public evidence of Victoria, BC coverage, and our play areas are parks and fields. Slice S1 adds a one-line availability probe to the harness so the answer is logged, nothing more.

### D — receiver-confirmed hits

Both phones already run body tracking, so the target's phone frequently sees the shooter. Host can require, for a `hit`, that (i) the shooter's skeleton hit zone test passed **and** (ii) the target's phone observed the shooter's body within a bearing cone consistent with the claimed ray in the last 250 ms. This reduces false positives (a shooter locking a bystander, or firing at a stale skeleton) without any frame. It cannot make two beams coincide, which is the owner's ask, so it is adopted as a confidence/residual signal inside A, not as the answer. Gate it behind a flag; measure the false-hit reduction in §7 before making it required.

### E — beyond 1v1

ARKit tracks one body. For 3–4 players the shared frame from A is the enabler: every phone's pose is known to the host, ADR 0004 capsules (0.35 m, later body volumes) are the verdict geometry, and the shooter's single skeleton lock becomes an aim-assist that must agree with one capsule (association by projected bearing). Vision 2D multi-person body pose can label which capsule is which person on screen. No new API is needed; the duel slices below leave every packet N-player-capable.

## 4. Decision

Adopt option A with D as its monitor. Concretely:

- Introduce a `DuelFrameProvider` (iOS targeting) that owns the calibrate → relocalize → switch state machine and publishes `frameState ∈ {unaligned, calibrating, aligned(residual), degraded, lost}`. Fire gates (`docs/features/shared-spatial-hit-registration/requirements.md` §3A) require `aligned`.
- Extend `spatial-hit.v1` (Integration) with a `frameId` (map hash) and shared-frame `origin/direction`; ADR 0005's `impact` and `zone` stay. Convex stores them unchanged in meaning: the ledger is still the durable authority.
- Map, poses, shots, and frame state travel on `CombatTransport` (ADR 0004). `ArenaPeerLink` is retired when that lands.
- Any frame state other than `aligned` fails closed: coarse beam, no spatial verdict, `shots:debugFire` available.

## 5. Consequences

- **Positive:** same beam on both phones; ADR 0005 code path preserved; one documented API set; works offline; N-player-ready packets.
- **Negative:** a 10 s calibration ritual per match (Design owns the copy/states); an extra bulk transfer; relocalization can fail in featureless or low-light venues — the fail-closed path must be good UX, not an error string.
- **Correction to ADR 0005:** its statement that body tracking "cannot coexist with collaborative/world-map sessions" is half right — it cannot coexist with *collaboration* or *produce* a map, but it can be *seeded* with one. A one-line note is added to ADR 0005 pointing here.

## 6. Fail-closed behaviour

| Condition | Beam on target phone | Verdicts | Fire |
|---|---|---|---|
| `aligned`, residual ≤ 0.10 m / 0.5° | Shooter pose → own camera | Host spatial verdict | Open |
| `degraded` (residual over budget or pose age > 100 ms) | Coarse render (current "ahead" fallback, labelled) | Skeleton-only verdict from shooter, flagged `degraded` in ledger | Open, HUD asks to re-align |
| `lost` / `unaligned` | Coarse render | None spatial | Locked except `shots:debugFire` |

## 7. Two-phone acceptance plan (physical devices; nothing here is claimable from simulator or CI)

**Setup:** two iPhones with `ARBodyTrackingConfiguration.isSupported == true` (record model + iOS version only — never UDIDs), same Wi-Fi/peer-to-peer link, an outdoor field with visible structure, tape measure, three ground marks at 3 m, 8 m, 15 m from a common origin mark, iOS 17+ for the harness. Run at least one session in flat overcast light and one in low sun.

**Procedure (per session, repeat 5×):**

1. Calibrate per §3A steps 1–3. Record calibration wall time, map byte size, transfer time, relocalization success/failure and time-to-`.normal` for both the world-tracking and the body-tracking relocalization.
2. Each phone places an anchor on each ground mark by camera ray; read both phones' coordinates → translation residual and yaw residual at 3/8/15 m.
3. Play a scripted 3-minute duel (walk 5 m, fire, return, fire; both players). Every 30 s re-read the 8 m mark → drift-over-time; log the skeleton-vs-pose residual stream at 20 Hz.
4. Fire 20 shots: 10 aimed hits, 10 deliberate misses. For each, record the beam's start/end on both phones (screenshots or the harness's world-space log), host verdict, Convex confirmation, and whether receiver confirmation agreed.
5. Note battery %, thermal state (`ProcessInfo.thermalState`) at start and end.

**Metrics and pass thresholds:**

| Metric | Pass |
|---|---|
| Relocalization into peer map (world-tracking and body-tracking steps) | ≥ 9/10 attempts, each ≤ 15 s |
| Translation residual at 3/8/15 m | p95 ≤ 0.10 m |
| Yaw residual | p95 ≤ 0.5° |
| Drift over 3-minute scripted duel | residual stays ≤ 0.10 m without re-align, or a re-align is triggered by the monitor and completes ≤ 15 s |
| Skeleton-vs-pose residual (monitor) | p95 ≤ 0.15 m when the body is tracked (allows head-offset variance) |
| Pose update interval | p99 ≤ 100 ms; loss < 2%; recovery after 5 s link loss ≤ 2 s (ADR 0004 budgets) |
| Fire → host verdict | p95 ≤ 100 ms; fire → Convex confirmation p95 ≤ 1.5 s |
| Cross-phone beam discrepancy (start and end, in metres, from the world-space log) | p95 ≤ 0.35 m |
| False hits / false misses over 20 shots | 0 false hits; ≤ 1 false miss |
| Clean cycles | Five consecutive fire → verdict → ledger → both HUDs + spectator agree |
| Thermal | No `.serious` thermal state within 10 minutes |

**Recording in `docs/build-log.md`:** use the existing entry template. Put the raw per-attempt rows in `docs/evidence/adr-0006/<date>-<session>.csv` (columns: `timestampMs, phone(A|B), metric, value, unit, notes`, sanitized), and in the log entry state device models + iOS versions, light condition, the table above with measured values and PASS/FAIL per row, screenshots of one matching beam pair, and the exact commit SHA. "Observed on physical devices" must list only what was seen; anything not run stays under "Mocked or unproven". `physicalDeviceEvidence` moves from `not-claimed` only when every row passes in two sessions.

## 8. Code that becomes unfit under this decision (delete in the named slice, not before)

| Code | Why unfit | Deleted in |
|---|---|---|
| `Targeting/SharedArena/ArenaPeerLink.swift`, `ArenaLinkMessage.swift`, the tracer relay in `LobbyStore` | Harness-grade Bonjour+TCP fast path; ADR 0004 `CombatTransport` carries poses, shots, and the map | S5 |
| `SharedArenaSession` `.collaborative` method and `ARParticipantAnchor` residual logic in `SharedArenaLockPolicy` | Collaboration is world-tracking only and cannot coexist with body tracking; the `.worldMap` method becomes the production calibration | S2 (after S0 evidence) |
| `ArenaHitEvaluator` and the `Arena*` prototype types at the end of `TargetingSession.swift` (`ArenaShotTracer` currently reads its constants) | Screen/shooter-frame hit prototype superseded by shared-frame `MatchSimulation` verdicts (already slated by ADR 0004) | S6 |
| `ActiveDuelView` incoming-beam origin heuristic ("screen-top, 3 m ahead" / body-derived guess) as the *primary* render | Replaced by shooter pose in the shared frame; retained only as the labelled `degraded` fallback | S5 |
| `IncomingShot` as `{eventId, hit, zone}` | Replaced by a frame-aligned shot segment; Convex events still drive the hit spark/haptic | S5 |
| Shooter-frame meaning of `origin/direction` in the Convex shot ledger | Fields stay; semantics change to shared frame + `frameId` (contract amendment, no data deletion) | S4 |

**Never deleted:** `shots:debugFire`, the `DEBUG TORSO FALLBACK` button, `archive/`, the Vision 2D targeting fallback for unsupported devices.

## 9. Implementation slices (one PR each)

| # | Slice | Owner workstream | Done when |
|---|---|---|---|
| S0 | **Spike:** harness mode `bodyTrackingWorldMap` in `SharedArenaSession` — world-tracking calibrate → map handoff (existing) → both phones re-run `ARBodyTrackingConfiguration(initialWorldMap:)`; residual + relocalization logging; `ARGeoTrackingConfiguration.checkAvailability` probe logged once | iOS targeting | Two-phone build-log entry with §7 rows 1–3 (relocalization, residual, drift). **Gate for everything below.** |
| S1 | Link `CombatTransport` into the app target; Xcode project wiring; bulk stream carries the archived map | Integration | Map round-trips between two phones over `CombatTransport` in the harness; `ios-gate` green |
| S2 | `DuelFrameProvider` state machine (pure core + tests) replacing the collaborative branch; fire gate reads `frameState` | iOS targeting (tests under `ios/**/Targeting/**`) | Unit tests for every transition and fail-closed rule; collaborative code deleted |
| S3 | Calibration UX: "look at the same scenery" ritual, aligned/degraded/lost HUD states, re-align prompt | Design (slice + states) → iOS game | Design slice accepted, then screens on device |
| S4 | `spatial-hit.v1` amendment: `frameId`, shared-frame `origin/direction`; Convex ledger + `shots:fire` validation; spectator projection reads frame id | Integration (contract) → Backend → Spectator | `pnpm verify` green; contract frozen in `docs/interface-contracts.md` |
| S5 | Beam from shooter pose to receiver camera; delete `ArenaPeerLink`, old `IncomingShot`, primary "ahead" heuristic | iOS game | §7 beam-discrepancy row measured |
| S6 | Host verdict against capsules + skeleton zone with receiver-confirmation flag; delete `ArenaHitEvaluator` | Integration (`shared/simulation`) → iOS targeting | §7 false-hit/miss and clean-cycle rows measured |
| S7 | 3+ player association (Vision 2D multi-person → capsule) behind a flag | iOS targeting | Design direction validated on 3 phones; separate build-log entry |

Handoff notes are required at each arrow (AGENTS.md ownership). No slice may claim physical-device evidence from CI or simulator.

## 10. What still needs the two-phone TestFlight run

Everything in §7. In particular this ADR does **not** know yet: outdoor relocalization rate of a body-tracking session into a peer's map, residual growth over a real duel, map size/transfer time on peer-to-peer Wi-Fi, thermal headroom of body tracking + 20 Hz streaming, and whether receiver confirmation removes false hits in practice. Until S0 reports, this ADR stays Proposed and the shipping ADR 0005 behaviour (shooter-frame shot, Convex + peer-link beams, debug fire) remains the product.
