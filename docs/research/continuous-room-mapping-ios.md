# Continuous, nonblocking room mapping on iPhone (BIO-36 spike, Apple-platform track)

Status: Research complete — 2026-09-26. Feeds the BIO-36 zero-step spike (Linear `BIO-36`). Builds on — does not repeat — [room-scanning.md](room-scanning.md) (Quick Play must not require scan/map/arena sizing; saved maps optional), [shared-arena-frame-options.md](shared-arena-frame-options.md) (frame-alignment options, outdoor error budget, world-map/NI limits) and ADRs [0010](../decisions/0010-quick-play-relocalized-frame-and-phone-proxy.md), [0011](../decisions/0011-quick-play-continuous-collaboration.md), [0013](../decisions/0013-quick-play-sighting-hits.md). Read-only research; no code, branch, PR, or deploy was produced.
Method: One read-only repository pass to verify the five "facts to verify" and to inventory which ARKit APIs the iOS target already uses; then Apple primary documentation (ARKit reference pages, ARKit articles, WWDC 19/20/21) for each capability in scope; Cloudflare Durable Objects docs for the authority side; practitioner reports only where Apple publishes no number and always marked **[practitioner]**. Engineering proposals are marked **[proposal]**; guesses are marked **[speculation]**; missing evidence is stated as an absence. Nothing here is physical-device evidence — the repository has none for this feature yet (§9).

## 1. The question

Two iPhones must start combat the moment both players are ready, with no blocking scan, alignment, relocalization, map-linking or shared-frame ritual, while each phone keeps mapping its surroundings during play and a match-scoped Cloudflare Durable Object stays authoritative for combat. Which Apple platform capabilities can genuinely run continuously in the background of gameplay on supported iPhones, which are LiDAR-only, what can be *promised* versus merely *attempted*, and what measurable gates should decide when map-derived data is allowed to influence combat?

## 2. Repository facts — verified, not assumed

All five statements in the assignment were checked against the working tree at `main` (read-only).

| Claim | Verdict | Evidence |
|---|---|---|
| iOS uses ARKit/Vision and already has local plane-detection paths | **Confirmed** | `ARWorldTrackingConfiguration` with `planeDetection` in `ios/**/Targeting/TargetingSession.swift`, `SharedArenaSession.swift`, `SharedArena/DuelFrame/DuelFrameARSupport.swift`, `Features/MapLab/MapLabARDriver.swift`; Vision human body pose in the targeting path [S37]. |
| Sighting fire carries body evidence, not wall/surface evidence | **Confirmed** | `packages/combat-protocol/src/index.ts`: `fire { shotId, poseSequence, origin, direction, observation?: BodyObservation \| null }`; `BodyObservation { targetPlayerId, capturedAtMs, associationConfidence, uncertaintyMeters, colliders }`; colliders are `head/torso/limbs` spheres/capsules. No wall, plane, mesh or depth field exists in protocol, simulation, or iOS wire types; ADR 0013 models cover as "no observation → no hit" [S37][S39]. |
| Convex handles lobby/match preparation and projects match state | **Confirmed** | `convex/functions/matches.ts` (`create/join/setReady/start`), `combat.ts` (`prepare/ticket/publishProjection`), `queries.ts` (`matchSnapshot/spectatorSnapshot`) [S37]. |
| A Cloudflare Durable Object runs the real-time combat simulation | **Confirmed** | `services/combat-worker/src/room.ts`: `class CombatRoom extends DurableObject<Env>` driving `@vkz/combat-simulation` (`create/restore`, checkpoints, candidate commits). `wrangler.jsonc` binds `COMBAT_ROOMS` → `CombatRoom` with `new_sqlite_classes` (SQLite-backed storage) [S37]. |
| Normal Deploy does not deploy the combat worker; a guarded operator script does | **Confirmed** | `.github/workflows/deploy.yml` deploys Convex + spectator only; no `wrangler deploy` in workflows. `scripts/release/combat-deploy.mjs` has `--preflight`/`--deploy` modes, environment guards, post-deploy health checks and evidence requirements [S37]. |

Additional inventory relevant to this spike (confirmed by grep, read-only): the iOS target already uses `initialWorldMap`, `getCurrentWorldMap`, `worldMappingStatus`, `isCollaborationEnabled`, `ARSession.CollaborationData`, `ARParticipantAnchor`, `trackingState`, and raycasts against detected planes, plus Nearby Interaction camera assistance. It does **not** use `sceneReconstruction`, `ARMeshAnchor`, `sceneDepth`, `smoothedSceneDepth`, `ARDepthData`, or typed `ARPlaneAnchor` geometry. The combat worker already has a bounded map upload path (`services/combat-worker/src/maps.ts`, `LIMITS.mapBytes = 8 MiB`, 128 KiB SQLite chunks) built for whole `ARWorldMap` blobs, not for incremental patches [S37]. Deployment target is iOS 17 (`IPHONEOS_DEPLOYMENT_TARGET = 17.0`, Package.swift `.iOS(.v17)`) [S37].

## 3. What ARKit actually does continuously (Apple primary docs)

### 3.1 Visual-inertial odometry and world tracking

- `ARWorldTrackingConfiguration` tracks six degrees of freedom (roll, pitch, yaw, translation) [S2]. Apple describes the method as visual-inertial odometry: motion-sensor data fused with computer-vision analysis of the scene visible to the camera [S1].
- "Every world-tracking session builds an internal world map, which ARKit uses to determine the device's position in the user's environment" [S18]. This is the continuous, always-on mapping that the product goal asks for — **it already exists on every supported device and requires no user ritual**. The design question is not "how do we make the phone map continuously" but "what can be read out of that map, how often, and at what cost".
- Apple's stated degradation conditions: blank walls, dark scenes, excessive motion, blur; tracking quality is *reduced*, not stopped, and ARKit raises `ARCamera.TrackingState.limited(reason)` [S1][S16][S17].
- All ARKit configurations require A9 or later [S14]; iOS 17 (the app's deployment target) only installs on A12-class or newer iPhones — **[inference]** so every phone that can run the app supports world tracking, but `ARWorldTrackingConfiguration.isSupported` must still be checked at runtime per Apple guidance [S14].

### 3.2 Plane detection

- Horizontal and/or vertical plane detection is a configuration flag; ARKit reports `ARPlaneAnchor` instances and *keeps refining* extent, centre and (when classified) semantics as the session runs — "ARKit's understanding of plane geometry refines over time" [S1][S3][S4]. No LiDAR requirement is stated [S3].
- Apple constraint: while tracking is `.limited`, plane detection does not add or update plane anchors [S17]. So plane data freezes exactly when tracking degrades, which the gating in §7 must reflect.
- Plane anchors are already flowing in the app (§2) but only their raycast results are consumed; the plane geometry itself is not typed or streamed [S37].

### 3.3 Raycasts

- `ARSession.raycast(_:)` "checks once for intersections between a ray and real-world surfaces" [S5]; `trackedRaycast(_:updateHandler:)` "repeats a ray-cast query over time to notify you of updated surfaces" [S6]. Targets can be existing plane geometry, estimated planes, or (with reconstruction) the mesh [S5][S6].
- Apple: hit-testing/raycast methods may return no result while tracking is limited [S17]. Raycasts are cheap continuous queries but are only as good as the surfaces already in the map; they are not a mapping mechanism themselves.

### 3.4 Scene depth and smoothed scene depth (LiDAR only)

- `ARFrame.sceneDepth` provides per-frame camera-to-world depth and is populated only when the `.sceneDepth` frame semantic is enabled [S10][S12]. `smoothedSceneDepth` is the temporally averaged variant [S11][S12].
- Apple: "ARKit supports scene depth only on LiDAR-capable devices, so call `supportsFrameSemantics(_:)` to ensure device support before attempting to enable scene depth" [S12][S14].
- `ARDepthData` carries `depthMap` plus a `confidenceMap` with `ARConfidenceLevel` `.low/.medium/.high`; Apple notes accuracy is affected by reflective or highly light-absorptive surfaces [S13].
- **[practitioner]** The delivered depth map is 256×192 (upsampled from a much sparser emitter array) at up to 60 Hz on iPhone 12 Pro/iPad Pro; Apple has not published these numbers in the reference docs, only in a forum thread [S31]. Apple's WWDC20 session confirms the depth API exposes "a dense depth image where a pixel corresponds to depth in meters" and that scene geometry is built from it [S28].
- Absence: Apple documents no maximum range for scene depth in the ARKit reference pages consulted. The marketing figure of ~5 m appears only in third-party copy and is not cited here as a fact.

### 3.5 Scene reconstruction meshes (LiDAR only)

- `sceneReconstruction` (`.mesh` / `.meshWithClassification`) yields `ARMeshAnchor`s, "a polygonal mesh that estimates the shape of the physical environment"; the runtime must check `supportsSceneReconstruction(_:)` [S7]. Meshes are LiDAR-backed [S7][S28].
- `ARMeshClassification` can label faces as floor, wall, ceiling, door, seat, table, window [S9] — the only Apple API that yields *wall* semantics directly, and one only Pro-class devices can produce (§5).
- Apple caveat that matters for combat: mesh anchors update continuously, but Apple states the updates are *not* intended to reflect physical changes in real time [S8]. A mesh is a slowly converging static model, not a live occupancy sensor — a moving player will not be tracked by it.
- Absence: Apple publishes no mesh update rate, vertex budget, or range in the reference docs consulted.

### 3.6 Feature points

- `ARFrame.rawFeaturePoints` exposes the intermediate feature cloud ARKit uses for tracking, but Apple explicitly does not guarantee the arrangement or stability of points across frames or releases [S15]. Usable as a *density/quality signal* (§7), not as map geometry to stream.

### 3.7 World-map persistence

- `ARWorldMap` captures the spatial-mapping state plus anchors; `getCurrentWorldMap` is asynchronous and may return nil; Apple recommends checking `worldMappingStatus` (`.notAvailable/.limited/.extending/.mapped`) before capture [S18][S19][S22].
- Loading via `initialWorldMap` starts the session in `.limited(.relocalizing)` and only reaches `.normal` if ARKit reconciles the saved map with what the camera sees; if it cannot, the session stays relocalizing **indefinitely** and Apple recommends a reset path [S20][S21][S26].
- Apple: relocalization "depends strongly on the physical environment" and is less reliable when lighting or scene features have changed [S17].
- **[practitioner]** A Developer Forums thread reports iOS 14→15 changed whether the world origin is re-based on successful relocalization; Apple staff advised filing feedback, so the behaviour is not documented either way [S34]. Any origin logic must be anchored to a saved `ARAnchor`, not the implicit origin (this is what Apple's own sample does [S21]).
- Consequence for BIO-36: whole-map save/load is inherently a *blocking* step (capture requires mapped status; load requires relocalization). It remains the right tool for the optional saved-arena mode [S38] and the wrong tool for the zero-step path. This confirms, and does not re-argue, the existing conclusion in [room-scanning.md](room-scanning.md).

### 3.8 Collaboration data

- `isCollaborationEnabled` makes ARKit "periodically" emit `ARSession.CollaborationData`; the app owns serialization and transport and feeds peers' data back via `session.update(with:)` [S23][S24]. Payload contains detected surfaces, the participant's position relative to them, and user anchors [S23].
- Merge condition: "for ARKit to know where two users are with respect to each other, it has to recognize overlap across their respective world maps" — Apple's sample instructs users to point devices at areas the other has viewed and to hold devices side by side [S24]. This is continuous *in the API* but the merge event is opportunistic and environment-dependent; Apple gives no time-to-merge figure.
- Apple: "collaborative sessions work best with up to four participants"; devices should run the same OS version because unarchiving `CollaborationData` from a different OS version *may fail* [S23].
- Absence: Apple publishes no byte rate, message cadence, or size bound for collaboration data (already recorded as an absence in [shared-arena-frame-options.provenance.md](shared-arena-frame-options.provenance.md)). Whether the app's existing collaboration relay can stay within the combat worker's WebSocket path is therefore a measurement, not a lookup (§9).
- The existing ADR 0011 already adopts continuous collaboration exchange; BIO-36 differs only in refusing to *gate play* on the merge.

### 3.9 Tracking quality and relocalization signals

- `ARCamera.TrackingState`: `.notAvailable`, `.limited(reason)`, `.normal`; reasons include `.initializing`, `.insufficientFeatures`, `.excessiveMotion`, `.relocalizing` [S16].
- Apple's lifecycle guidance: show feedback during limited tracking; on interruption ARKit attempts relocalization if `sessionShouldAttemptRelocalization` returns true, and the app should offer a reset if relocalization does not complete [S17][S26]. `ARSession.RunOptions` (`.resetTracking`, `.removeExistingAnchors`, `.resetSceneReconstruction`) is the documented reset mechanism [S27].
- **[practitioner]** Sustained camera+ML sessions heat the device and iOS lowers the frame rate (60→30 fps reports); Apple offers no API signal for this in ARKit, per a forum answer [S32]. `ProcessInfo.thermalState` exists outside ARKit but was not evaluated in this spike — recorded as an open item, not a claim.

## 4. Capability matrix

Legend — **Continuous during play:** Yes = Apple documents it as a running property of a live `ARWorldTrackingConfiguration` session with no user step; Cond. = runs continuously but its *output* pauses/degrades under documented conditions; No = inherently a discrete/blocking step. **LiDAR:** Req. = Apple states LiDAR/`supportsFrameSemantics`/`supportsSceneReconstruction` requirement; No = no such requirement stated.

| Capability | API | Continuous during play | LiDAR | Can be promised (Apple-documented) | Cannot be promised (absence / device-dependent) | In app today |
|---|---|---|---|---|---|---|
| VIO / 6-DoF pose | `ARWorldTrackingConfiguration`, `ARCamera.transform` [S1][S2] | Yes | No | 6-DoF pose every frame while `.normal`; internal map always built [S18] | Drift magnitude, outdoor/feature-poor behaviour [S1] | Yes |
| Tracking quality | `ARCamera.trackingState` [S16] | Yes | No | State + reason each frame | Recovery time from `.limited` | Yes |
| Plane detection | `planeDetection`, `ARPlaneAnchor` [S3][S4] | Cond. (frozen while `.limited` [S17]) | No | Anchors refine over time [S1] | Time-to-first-plane, extent accuracy | Yes (raycast only) |
| Raycast / tracked raycast | `raycast`, `trackedRaycast` [S5][S6] | Cond. (may return nothing while `.limited` [S17]) | No (mesh target Req.) | Query against existing planes/mesh | Result when surface unmapped | Yes (planes) |
| Feature points | `rawFeaturePoints` [S15] | Yes | No | Count per frame as a density signal | Point stability / identity [S15] | No |
| Scene depth | `sceneDepth`, `ARDepthData` [S10][S13] | Yes | **Req.** [S12] | Per-frame depth + confidence on supported devices | Range; behaviour on reflective/absorptive surfaces [S13]; resolution (practitioner-only [S31]) | No |
| Smoothed scene depth | `smoothedSceneDepth` [S11] | Yes | **Req.** [S12] | Temporally averaged depth | Same as above | No |
| Scene reconstruction mesh | `sceneReconstruction`, `ARMeshAnchor` [S7][S8] | Yes, but *not real-time* for physical change [S8] | **Req.** [S7] | Converging static geometry; wall/floor/ceiling labels [S9] | Update rate, range, vertex budget; moving-body handling | No |
| World-map capture | `getCurrentWorldMap`, `worldMappingStatus` [S19][S22] | No (discrete, may return nil) | No | Capture when `.mapped` | Map size; success when `.limited` | Yes |
| World-map load / relocalize | `initialWorldMap` [S20][S21] | No (blocking; may never complete [S20]) | No | Anchors restored on success | Time-to-relocalize; changed-lighting success [S17] | Yes |
| Collaboration data | `isCollaborationEnabled`, `CollaborationData` [S23][S24] | Yes (emission); merge is opportunistic | No | Periodic emission; ≤4 participants guidance | Byte rate, merge latency, cross-OS unarchive [S23] | Yes |
| Relocalization after interruption | `sessionShouldAttemptRelocalization` [S26] | Cond. | No | Attempt is automatic if enabled | Completion; needs app reset path [S17] | Partial |

Reading the matrix against the product goal: everything in the "No" column of *LiDAR* runs on every device that can install the app (§3.1 inference), so a non-LiDAR-first design is feasible. Everything marked **Req.** is a Pro-only enhancement and must be designed as *additive* evidence, never as a prerequisite — consistent with [room-scanning.md](room-scanning.md) §"Quick Play baseline must work without LiDAR". Only the two world-map rows are inherently blocking; both stay in the optional saved-arena mode.

## 5. LiDAR versus non-LiDAR availability

- Apple's own model-identification page lists a "LiDAR Scanner" for iPhone 17 Pro / 17 Pro Max and iPhone 16 Pro / 16 Pro Max and not for iPhone 17, 17e, Air, 16e, 16 Plus [S30] (the fetched page section covered those models; older Pro models were not re-verified in this spike and are not asserted). Absence: Apple publishes no consolidated "ARKit scene depth device list"; the documented contract is the runtime probe [S12][S14].
- Runtime probes that must gate every LiDAR feature: `ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth / .smoothedSceneDepth)` [S14][S12] and `ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)` [S7].
- **[practitioner]** A 2020 field test (vGIS) found LiDAR did **not** materially improve long-range VIO tracking accuracy versus non-LiDAR iPhones but did improve surface detection on glossy floors and low-texture surfaces [S33]. Treat as a hypothesis to measure, not a fact: it predates iOS 17 and current hardware.
- Design consequence **[proposal]**: the shared room model must accept two classes of patch — *plane patches* (all devices) and *mesh/depth patches* (LiDAR devices) — and the Durable Object must never assume the two players contribute the same class.

## 6. Zero-step architecture implications **[proposal]**

This section is engineering proposal derived from §3–§5, not an Apple guarantee.

1. **Do not add a mapping step; change what is read from the mapping that already runs.** Both phones run `ARWorldTrackingConfiguration` with plane detection (already true) and, when `supportsSceneReconstruction` is true, `.meshWithClassification`. Nothing is shown to the player except normal tracking-quality feedback [S17].
2. **Stream trajectory continuously; stream map patches only above gates.** Pose samples (already carried by `poseSequence` in the fire payload [S37]) are cheap and every-frame. Map patches — typed `ARPlaneAnchor` (centre, extent, transform, classification, anchor ID) and, on LiDAR, `ARMeshAnchor` deltas — are emitted only when §7 gates pass, bounded in bytes, and idempotent by anchor identifier so re-sends are harmless. The worker's existing 8 MiB whole-map path [S37] is not the right shape; a patch stream needs per-message bounds well under the DO's 32 MiB received-WebSocket limit and, if persisted, under the 2 MB SQLite row/blob limit [S35].
3. **Alignment stays opportunistic on two independent channels.** (a) ARKit collaboration merge (`ARParticipantAnchor` appearing = merge happened) [S24][S25]; (b) the Durable Object aligning the two phones' plane/mesh patches server-side. Neither gates firing. When (a) happens the transform it yields is a high-confidence observation into (b), not a replacement — consistent with ADR 0011's shared-origin anchor.
4. **Combat before convergence.** ADR 0013's body-observation sighting path is already convergence-free; it remains the sole authoritative hit evidence. Map-derived data enters combat only as *negative* evidence (cover/occlusion) and only after the room model reaches the confidence tier in §7.3. Absence: no Apple API yields wall evidence on non-LiDAR devices beyond vertical `ARPlaneAnchor`s, so occlusion on non-LiDAR pairs will be plane-based and coarse.
5. **Saved arenas remain optional.** `ARWorldMap` capture/load (§3.7) stays in Scan & Save; if a saved map relocalizes mid-match it simply becomes another high-confidence alignment observation. **[speculation]** the same DO room model could be seeded from a saved map's planes to shorten convergence; not evaluated.
6. **Thermal/frame-rate budget is a first-class constraint.** **[practitioner]** evidence of frame-rate throttling in multi-minute AR sessions [S32] plus the body-pose Vision workload already in the targeting path means mesh reconstruction on LiDAR devices should be switchable off at runtime by the DO/client policy. Measurement item, §9.

## 7. Measurable quality gates **[proposal]**

Every threshold below is an engineering starting point for device measurement; none is an Apple-published number.

### 7.1 Per-frame local gates (client, all devices)

| Gate | Signal | Pass condition | Effect when failing |
|---|---|---|---|
| G1 Tracking | `ARCamera.trackingState` [S16] | `.normal` | Stop emitting map patches; keep emitting pose with `limited` flag; firing policy per existing requirements (tracking failure locks input) |
| G2 Reason | `.limited(reason)` [S16] | not `.relocalizing`, `.insufficientFeatures`, `.excessiveMotion` for > N consecutive frames | Same as G1; surface Apple-style feedback [S17] |
| G3 Feature density | `rawFeaturePoints.count` [S15] | ≥ threshold *T_feat* (device-calibrated) | Down-weight new plane patches |
| G4 Map status | `worldMappingStatus` [S22] | `.extending` or `.mapped` for patch emission; `.mapped` for optional map capture | Plane patches tagged low-confidence; no capture |

### 7.2 Patch admission gates (client → DO)

| Gate | Signal | Pass condition |
|---|---|---|
| P1 Plane maturity | `ARPlaneAnchor` update count / age | anchor observed ≥ *K* updates over ≥ *t_min* seconds before first emission |
| P2 Plane extent | `ARPlaneAnchor` extent | area ≥ *A_min* (m²) to filter spurious planes |
| P3 Depth confidence (LiDAR) | `ARDepthData.confidenceMap` [S13] | fraction of `.high` pixels in the patch ≥ *c_min*; `.low` pixels excluded |
| P4 Mesh classification (LiDAR) | `ARMeshClassification` [S9] | only `wall/floor/ceiling/door/window` faces admitted as room structure; `seat/table/none` kept as clutter, never as cover |
| P5 Bounds | serialized bytes / message rate | per-message bytes ≤ *B_msg*, patches/s ≤ *R_max*; re-send only on changed anchor |

### 7.3 Shared-model confidence tiers (Durable Object)

| Tier | Meaning | Allowed influence on combat |
|---|---|---|
| T0 Unaligned | no cross-phone alignment observation | none; body-observation hits only (ADR 0013) |
| T1 Coarse | one alignment source (collaboration merge **or** patch-alignment fit with residual ≤ *r_1*) | cosmetic/advisory only (spectator projection, HUD hints) |
| T2 Corroborated | ≥ 2 independent sources agree within *r_2*, stable for *t_stable* | negative evidence (occlusion/cover) may veto a hit; never create one |
| T3 Saved-arena | relocalized `ARWorldMap` anchor present [S20] | as T2 plus arena-bounds features |

Regression to a lower tier must be immediate on G1/G2 failure of either phone; promotion must be hysteretic. The DO already checkpoints simulation state [S37]; tier state should be part of that checkpoint so restarts do not silently re-enable occlusion.

## 8. Cloudflare authority-side constraints (primary docs)

- SQLite-backed DO limits: 2 MB max per row/BLOB/value, 100 KB max SQL statement, 32 MiB max *received* WebSocket message, soft ~1,000 req/s per object, 10 GB per object on Paid [S35]. WebSocket Hibernation is recommended and stops billable duration while idle [S36]. Absence: Cloudflare publishes no *outbound* WebSocket message-size or per-second byte guidance on these pages.
- Consequence: patch persistence (if any) must be chunked ≤ 2 MB per row — `maps.ts` already uses 128 KiB chunks [S37]; a continuous patch stream should be treated as request-rate load against the ~1,000 req/s soft limit, which is another reason for P5 rate bounds.

## 9. What cannot be known without physical-device experiments

The repository has no physical-device evidence for any BIO-36 behaviour; [room-scanning.md](room-scanning.md) already records that no two-phone freely-moving combat acceptance exists. Specifically unmeasured:

1. Time-to-first-plane and plane extent error on representative non-LiDAR and LiDAR iPhones running iOS 17+, indoors and in the outdoor arena.
2. Collaboration-data byte rate and time-to-merge when players do **not** perform the side-by-side ritual — the central zero-step bet. Apple gives no number [S23][S24].
3. Mesh reconstruction update cadence, vertex volume, and the drift of a *moving second player* through the mesh (Apple says meshes are not real-time for physical change [S8]).
4. Frame-rate and thermal behaviour of world tracking + Vision body pose + optional mesh over a full match duration [S32 practitioner].
5. Whether `rawFeaturePoints.count` correlates with subsequent tracking loss well enough to serve as G3.
6. Cross-OS-version behaviour of `CollaborationData` unarchiving between the two test phones [S23].
7. Whether LiDAR meaningfully improves alignment fit residuals versus plane-only pairs (practitioner hint only [S33]).

Until these exist, every threshold in §7 is a placeholder and no ADR should freeze the patch format.

## 10. Recommendation

Verdict: **the "continuous mapping" half of BIO-36 needs no new user-facing step — ARKit already maps continuously on every device the app installs on [S18]; the engineering work is to (a) type and stream the plane/mesh data ARKit already produces, gated by §7, (b) keep ADR 0013 body observations as the only positive hit evidence, (c) let alignment converge opportunistically on the DO from collaboration merges and server-side patch fits, and (d) keep `ARWorldMap` save/load in the optional saved-arena mode because it is inherently blocking [S20].** LiDAR depth/mesh are additive Pro-only inputs behind runtime probes [S7][S12][S14], never prerequisites. The single largest unknown is time-to-merge without a ritual (§9 item 2); that should be the first physical-device measurement before any protocol change is designed.

## Sources

Apple primary documentation (accessed 2026-09-26):

- [S1] Apple, "Understanding World Tracking" — https://developer.apple.com/documentation/arkit/understanding-world-tracking
- [S2] Apple, `ARWorldTrackingConfiguration` — https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration
- [S3] Apple, `ARWorldTrackingConfiguration.planeDetection` — https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/planedetection-swift.property
- [S4] Apple, `ARPlaneAnchor` — https://developer.apple.com/documentation/arkit/arplaneanchor
- [S5] Apple, `ARSession.raycast(_:)` / `ARRaycastQuery` — https://developer.apple.com/documentation/arkit/arsession/raycast(_:) ; https://developer.apple.com/documentation/arkit/arraycastquery
- [S6] Apple, `ARSession.trackedRaycast(_:updateHandler:)` — https://developer.apple.com/documentation/arkit/arsession/trackedraycast(_:updatehandler:)
- [S7] Apple, `ARWorldTrackingConfiguration.sceneReconstruction` — https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/scenereconstruction
- [S8] Apple, `ARMeshAnchor` — https://developer.apple.com/documentation/arkit/armeshanchor
- [S9] Apple, `ARMeshClassification` — https://developer.apple.com/documentation/arkit/armeshclassification
- [S10] Apple, `ARFrame.sceneDepth` — https://developer.apple.com/documentation/arkit/arframe/scenedepth
- [S11] Apple, `ARFrame.smoothedSceneDepth` — https://developer.apple.com/documentation/arkit/arframe/smoothedscenedepth
- [S12] Apple, `ARConfiguration.FrameSemantics.sceneDepth` / `.smoothedSceneDepth` — https://developer.apple.com/documentation/arkit/arconfiguration/framesemantics-swift.struct/scenedepth ; https://developer.apple.com/documentation/arkit/arconfiguration/framesemantics-swift.struct/smoothedscenedepth
- [S13] Apple, `ARDepthData`, `confidenceMap`, `ARConfidenceLevel` — https://developer.apple.com/documentation/arkit/ardepthdata ; https://developer.apple.com/documentation/arkit/ardepthdata/confidencemap ; https://developer.apple.com/documentation/arkit/arconfidencelevel
- [S14] Apple, `ARConfiguration.isSupported` / `supportsFrameSemantics(_:)` — https://developer.apple.com/documentation/arkit/arconfiguration/issupported ; https://developer.apple.com/documentation/arkit/arconfiguration/supportsframesemantics(_:)
- [S15] Apple, `ARFrame.rawFeaturePoints` / `ARPointCloud` — https://developer.apple.com/documentation/arkit/arframe/rawfeaturepoints ; https://developer.apple.com/documentation/arkit/arpointcloud
- [S16] Apple, `ARCamera.TrackingState` and `.Reason` — https://developer.apple.com/documentation/arkit/arcamera/trackingstate-swift.enum ; https://developer.apple.com/documentation/arkit/arcamera/trackingstate-swift.enum/reason
- [S17] Apple, "Managing Session Life Cycle and Tracking Quality" — https://developer.apple.com/documentation/arkit/managing-session-life-cycle-and-tracking-quality
- [S18] Apple, `ARWorldMap` — https://developer.apple.com/documentation/arkit/arworldmap
- [S19] Apple, `ARSession.getCurrentWorldMap(completionHandler:)` — https://developer.apple.com/documentation/arkit/arsession/getcurrentworldmap(completionhandler:)
- [S20] Apple, `ARWorldTrackingConfiguration.initialWorldMap` — https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/initialworldmap
- [S21] Apple, "Saving and Loading World Data" — https://developer.apple.com/documentation/arkit/saving-and-loading-world-data
- [S22] Apple, `ARFrame.worldMappingStatus` / `WorldMappingStatus` — https://developer.apple.com/documentation/arkit/arframe/worldmappingstatus-swift.property ; https://developer.apple.com/documentation/arkit/arframe/worldmappingstatus-swift.enum
- [S23] Apple, `ARWorldTrackingConfiguration.isCollaborationEnabled` — https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/iscollaborationenabled
- [S24] Apple, "Creating a Collaborative Session" — https://developer.apple.com/documentation/arkit/creating-a-collaborative-session
- [S25] Apple, `ARParticipantAnchor` — https://developer.apple.com/documentation/arkit/arparticipantanchor
- [S26] Apple, `ARSessionObserver.sessionShouldAttemptRelocalization(_:)` — https://developer.apple.com/documentation/arkit/arsessionobserver/sessionshouldattemptrelocalization(_:)
- [S27] Apple, `ARSession.RunOptions` — https://developer.apple.com/documentation/arkit/arsession/runoptions
- [S28] Apple, WWDC20 session 10611 "Explore ARKit 4" (scene geometry, depth API) — https://developer.apple.com/videos/play/wwdc2020/10611/
- [S29] Apple, WWDC19 session 610 "Introducing ARKit 3" (collaborative sessions) — https://developer.apple.com/videos/play/wwdc2019/610/
- [S30] Apple Support, "Identify your iPhone model" (LiDAR Scanner listed per model) — https://support.apple.com/en-us/108044

Practitioner sources (marked **[practitioner]** wherever used):

- [S31] Apple Developer Forums thread 688791, depth-map resolution/alignment (community answers, not Apple documentation) — https://developer.apple.com/forums/thread/688791
- [S32] Apple Developer Forums thread 689458, ARKit FPS drop when device gets hot — https://developer.apple.com/forums/thread/689458
- [S33] vGIS, "iPhone and iPad LiDAR spatial tracking capabilities: second test" (2020 field test, pre-iOS 17 hardware) — https://www.vgis.io/2020/12/02/lidar-in-iphone-and-ipad-spatial-tracking-capabilities-test-take-2/
- [S34] Apple Developer Forums thread 690668, `ARWorldMap` origin behaviour difference iOS 14 vs 15 — https://developer.apple.com/forums/thread/690668

Cloudflare primary documentation (accessed 2026-09-26):

- [S35] Cloudflare, Durable Objects "Limits" — https://developers.cloudflare.com/durable-objects/platform/limits/
- [S36] Cloudflare, Durable Objects "WebSockets" best practices (Hibernation API) — https://developers.cloudflare.com/durable-objects/best-practices/websockets/

Repository sources (read-only, `main` working tree, 2026-09-26):

- [S37] Repository inspection: `packages/combat-protocol/src/index.ts`, `services/combat-worker/src/room.ts`, `services/combat-worker/src/maps.ts`, `services/combat-worker/wrangler.jsonc`, `convex/functions/{matches,combat,queries,shots}.ts`, `.github/workflows/deploy.yml`, `scripts/release/combat-deploy.mjs`, `ios/VictoriaKillZone/**/Targeting/**`, `ios/VictoriaKillZone/**/Features/MapLab/MapLabARDriver.swift`, `ios/VictoriaKillZone/Package.swift`, `VictoriaKillZone.xcodeproj/project.pbxproj`.
- [S38] [docs/research/room-scanning.md](room-scanning.md) and [docs/research/shared-arena-frame-options.md](shared-arena-frame-options.md) (+ provenance).
- [S39] ADRs [0010](../decisions/0010-quick-play-relocalized-frame-and-phone-proxy.md), [0011](../decisions/0011-quick-play-continuous-collaboration.md), [0013](../decisions/0013-quick-play-sighting-hits.md).
