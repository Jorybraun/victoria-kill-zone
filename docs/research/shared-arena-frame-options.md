# Shared Arena Frame options for 2–4 phones outdoors (L3 / KIL-20)

Status: Research complete — 2026-08-24. Feeds the KIL-20 two-phone Shared Arena Frame prototype and the L3 `SharedArenaFrame` provider decision in [docs/roadmap.md](../roadmap.md). Builds on — does not repeat — [shared-ar-hit-registration.md](shared-ar-hit-registration.md) (phone-proxy hitscan, bounded rewind) and [realtime-backend-options.md](realtime-backend-options.md) (transport, authority).
Method: One error-budget derivation from the frozen product baselines, then six frame-alignment methods evaluated against it with primary sources (Apple documentation and WWDC sessions, academic benchmarks, shipped-product engineering posts, practitioner reports). Every non-obvious claim carries a numbered source; provenance sidecar lists access dates and rejections.

## 1. The question

2–4 iPhones in a park must establish and maintain ONE shared, metre-based, right-handed coordinate frame — the Shared Arena Frame — so all phones agree where players and bullets are, markerlessly, in a 20–60 m outdoor arena with sparse visual features and changing light. Which alignment method (or combination) meets the frozen fairness baselines, and what must KIL-20 measure on physical devices before an ADR freezes the L3 provider?

## 2. Frozen constraints this document must satisfy

From [docs/features/shared-spatial-hit-registration/requirements.md](../features/shared-spatial-hit-registration/requirements.md): proxy sphere radius **0.35 m**; shot lane **3–15 m**; max rewind **250 ms**; max pose age **100 ms**; firing requires both phones aligned with normal tracking; tracking failure locks input immediately. From [AGENTS.md](../../AGENTS.md): no visible target markers (rules out fiducial/QR alignment), Phase 1 cap 4 players, iOS-native only. From CONTEXT.md: Tracking Quality and Phone Pose Sample vocabulary generalizes to whatever provider is chosen.

## 3. Error budget: what the 0.35 m proxy at 3–15 m actually tolerates

This section is derivation (geometry from frozen baselines), not sourced claims. It drives every verdict in §4.

### 3.1 Angular subtense of the target

The proxy sphere subtends a half-angle `θ = arcsin(0.35/d)`:

| Range d | Half-angle θ | Lateral error that consumes the whole radius |
|---|---|---|
| 3 m | 6.7° | 0.35 m |
| 8 m | 2.5° | 0.35 m |
| 15 m | 1.34° | 0.35 m |

A perfectly centred shot registers only if the **sum of all spatial errors, expressed laterally at the target**, stays under 0.35 m. Errors and their scaling:

1. **Relative frame translation `e_t`** (the two local origins disagree in the shared frame): direct, distance-independent.
2. **Relative frame rotation (yaw) `δφ`**: displaces every reported remote position by ≈ `r·δφ` where `r` is the target's distance from the alignment origin. **1° of yaw = 0.26 m at 15 m, 0.52 m at 30 m, 1.05 m at 60 m.** Yaw is the dominant, arena-scale-limiting term. (Pitch/roll are constrained because ARKit world frames are gravity-aligned by default, leaving only 4 unknown DoF: yaw + 3 translation [1].)
3. **Shooter aim/pose capture error `δψ`**: lateral ≈ `d·δψ`; 0.5° at 15 m = 0.13 m.
4. **Per-phone odometry drift since last correction `e_d`**: direct.
5. **Pose-age motion error**: without rewind, the frozen 100 ms max pose age at 1–3 m/s dodge speed contributes **0.10–0.30 m alone** — at 3 m/s it consumes ~86 % of the entire budget. With the frozen bounded-rewind design the term collapses to `clock-sync error × target speed` ≈ 10 ms × 3 m/s = 0.03 m. Bounded rewind is therefore not optional for fairness; this independently re-confirms the frozen 250 ms rewind baseline.

### 3.2 Proposed budget split (worst-case linear sum at 15 m)

| Term | Budget | Lateral at 15 m |
|---|---|---|
| Relative frame translation `e_t` | ≤ 0.10 m | 0.10 m |
| Relative frame yaw `δφ` | ≤ 0.5° | 0.13 m |
| Drift since last correction, per phone ×2 | ≤ 0.03 m each | 0.06 m |
| Clock-sync residual × 3 m/s | ≤ 10 ms | 0.03 m |
| Aim capture / frame-alignment jitter reserve | — | 0.03 m |
| **Total** | | **0.35 m** |

**Consequences:** (i) the alignment quality gate for `SPATIAL LOCK READY` should be ≈ **0.10 m translation + 0.5° yaw residual**; (ii) at 30–60 m arena spans the same 0.35 m proxy needs ≤ 0.25°–0.13° yaw — unreachable open-loop, so larger arenas require continuous correction and calibration near the centre of play; (iii) these splits are engineering proposals set by this document, to be validated or re-cut by KIL-20 measurements, not vendor or literature claims.

### 3.3 Drift eats the budget in seconds, not minutes

- A peer-reviewed four-way VIO benchmark measured ARKit — the **best** of the four systems tested — at a relative pose error of **≈ 0.02 m per second of movement** in realistic indoor/outdoor sequences [2]. At that rate the 0.03 m per-phone drift budget is consumed in ~1.5 s of continuous walking; even if real-world performance is 10× better, open-loop hold across a 3-minute match is impossible.
- A hologram-stability study (iPhone 11, ARKit 4/5, 200+ environments) measured mean virtual-object drift from **1.0 cm to 43.2 cm depending on user action**, with "walk away and return" the worst on ARKit (25.1 cm mean) — exactly the motion pattern of a strafing player [3][4].
- **Conclusion (evidence-based inference):** maintenance is not periodic re-calibration; it must be a continuous correction loop (co-mapping merges, ranging cross-checks) plus quality-gated re-lock. The frozen Tracking Quality gate needs a drift/residual signal, not only `ARCamera.trackingState`.

## 4. Options compared

### Option A — ARWorldMap one-shot handoff (`getCurrentWorldMap` → `initialWorldMap`) — the existing baseline

- **Mechanics:** host serializes its map once; guest relocalizes against it; both then exchange only compact pose/action data. Apple documents map capture/transfer as "time-consuming, bandwidth-intensive" one-time operations and recommends guests be next to the sender viewing similar scenery [5][6]. Capture should be gated on `worldMappingStatus == .mapped` [7][8].
- **Size:** serialized maps in Apple's own multi-device sample ecosystem run **hundreds of kilobytes** for a small scanned play space [9]; practitioner reports show in-memory footprints of tens of MB and **20 MB+ serialized maps causing render lag and crashes on non-LiDAR devices** for large scans [10][11]. A 20–60 m park arena pushes toward the large end.
- **Outdoor reliability:** Apple states relocalization "speed and success rate … can vary depending on real-world conditions" and recommends a timeout-and-reset UX [12]. Relocalization is appearance-based; a practitioner reports maps recorded in bright light **failing to relocalize under medium light** (and vice versa) [13] — directly relevant to dusk play. Grass/field scenes risk `insufficientFeatures` limited tracking (Apple's documented failure reason for low-texture/low-light scenes) [14]; an indoor/outdoor AR measurement study confirms camera-based tracking degrades sharply with lighting variation [15]. No Apple benchmark for outdoor relocalization exists (absence of evidence, noted, not a claim).
- **Verdict: fallback, not primary.** One-shot alignment with zero maintenance; drift after join is uncorrected (§3.3). Keep because it is the simplest path already described in prior research, iOS 12+, and a good control condition for measurements.

### Option B — ARKit collaborative session (`isCollaborationEnabled` / `ARCollaborationData`)

- **Mechanics:** each phone periodically emits `ARCollaborationData` which the app transports (any network; we already chose Network.framework [16]); peers merge maps **continuously** as they observe overlapping areas, and each phone receives an `ARParticipantAnchor` for every other user [17][18][19]. Apple positions this as the successor to one-shot maps for live multiuser AR: decentralized, no host, works in unseen environments, tracking improves as everyone maps together [19].
- **Peer count:** "Collaborative sessions work best with up to four participants" — guidance, not a hard cap; exactly the Phase 1 cap [20].
- **Bandwidth:** two data classes — *critical* (periodic; send reliable) and *optional* (≈ every frame; send unreliable, includes device location) [17][21]. Apple publishes no byte rates; must be measured (KIL-20).
- **Continuous co-mapping vs one-shot:** collaboration keeps re-merging as the session runs, which is the only Apple-native mechanism that addresses §3.3 maintenance rather than just establishment [19].
- **Outdoors:** same visual-feature dependency as Option A for the *initial* merge (peers must see overlapping areas [18]); no Apple outdoor benchmark. iOS 13+.
- **Verdict: primary.** It is the only candidate that both establishes and maintains the frame with continuous corrections, matches the 4-player cap, and needs no cloud service.

### Option C — Nearby Interaction / UWB with camera assistance

- **Mechanics:** `NINearbyPeerConfiguration` gives distance + direction between two UWB iPhones; one `NISession` per peer [22][23]. With `isCameraAssistanceEnabled` (iOS 16+) NI fuses ARKit 6-DoF tracking with UWB, widens the usable field of view, adds `horizontalAngle`/`verticalDirectionEstimate`, and — decisively for us — `NISession.worldTransform(for:)` returns the **peer's position in the local ARKit world frame** [24][25][26]. Exchange those observations plus self-reported local poses over several vantage points and the 4-DoF inter-frame transform (yaw + translation, gravity removes the rest [1]) is solvable by least squares — the direct-solve pattern academically validated by SynchronizAR (UWB distances + SLAM, no mutual visibility needed) [27] and Cappella (UWB + VIO particle filter, median 3D error < 1 m across buildings) [28].
- **Devices:** U1 chip on iPhone 11 and later (except 16e/17e); second-generation U2 on iPhone 15 and later [29]. Camera assistance requires iOS 16 [24]; Extended Distance Measurement (EDM) requires two U2 devices on iOS 17+ and Apple's own sample treats **10–50 m** as its working envelope [30][31].
- **Limits:** Apple's stated best-operation envelope for first-gen UWB is **within ~9 m**, portrait, back cameras facing, clear line of sight; direction is only produced inside a narrow rear-facing cone and goes `nil` outside it [23]. Our 3–15 m lane exceeds 9 m on U1-only pairs. Measured NI peer update rates are ≈ 5 Hz — far below a 20–30 Hz pose loop [32]. Smartphone UWB ranging errors measure < 20 cm across devices in controlled studies [33]; practitioners report usable iPhone-to-accessory ranging out to 30–40 m in the open but severe degradation through obstacles/bodies [34]. Multi-peer: one session per peer, with an undocumented platform cap surfaced only as the `activeSessionsLimitExceeded` error [22][35]. WWDC22 notes camera assistance is "best used for interacting with stationary devices" [26] — a moving-player caveat to verify.
- **Verdict: not a standalone frame source — but the best independent alignment-residual and calibration signal.** UWB distance is drift-free and lighting-independent: `|shared-frame inter-phone distance − UWB distance|` is a cheap continuous residual to drive the frozen Tracking Quality gate, and camera-assisted `worldTransform(for:)` during a face-each-other ritual gives a direct transform estimate that does not depend on shared visual features. Fleet-restriction note: requires iPhone 11+ on both phones; the game must degrade gracefully without it.

### Option D — Mutual visual observation (A's camera sees B while B self-reports pose)

- **Evidence:** the pattern ships on Snap Spectacles as *EyeConnect* — two users look at each other; each device detects the other's glasses in 2D, exchanges ego-poses + 2D detections, and a solver aligns the two frames, typically in **< 5 s** [36]. The closed-form minimal solver for exactly this problem (ego-poses + mutual face/device detections) is published [37]. SynchronizAR's related work notes the core difficulty on handheld devices: estimating a phone's full 6-DoF pose from another phone's camera is hard because the device is small, hand-occluded, and must be segmented from the user [27].
- **Fit:** pairs naturally with the existing Vision body-pose targeting (L4): Vision already yields 2D person/head observations of the opponent, and the opponent self-reports its phone pose at 20–30 Hz. Bearing-only correspondences over a few seconds of relative motion condition a 4-DoF solve [37]. No Apple API provides this; it is custom estimation code plus an association step.
- **Verdict: credible R&D fallback, not for KIL-20.** Marked **speculation** at implementation level (no iOS precedent found for phone-to-phone); strategically attractive because it re-uses the Vision pipeline and works exactly when players do what the game demands — aim at each other.

### Option E — GeoAnchors / GPS + compass as a coarse prior

- **ARGeoAnchor:** A12+, outdoors only, works **only where Apple has street-level localization imagery**; availability must be runtime-checked via `checkAvailability`, and imagery "doesn't include gated or pedestrian-only areas" — i.e., park interiors may fail even inside a covered metro [38]. Coverage grew from 5 US metros to 25+ US cities plus London by WWDC21 [39]; Apple publishes no current city list, and **no evidence was found that Victoria BC is covered** — unverifiable without an on-device check (this is a finding: run `checkAvailability` in the actual park before assuming anything).
- **GPS + compass:** measured iPhone horizontal GPS accuracy is ≈ 3–4 m open-sky, degrading to ~8.6 m under canopy [40][41]; smartphone compass azimuth RMSE is ~2–4° in the field with outliers of 13–25° [42], and an AR-focused study measured mean compass errors of 10–30° [43]. Against §3.2 (0.10 m / 0.5°), GPS+compass misses the budget by 1–2 orders of magnitude in both terms.
- **Verdict: rejected for hit-scale alignment; retained for what it already does** (geofence, venue context, spectator map — consistent with prior research's "never use latitude/longitude for metre-scale hit registration"). As a *coarse initializer* it can pre-orient a 20–60 m arena to ~5 m / ~15° — useful only to seed discovery/UI, never to seed the verdict frame.

### Option F — What shipped products actually do

- **Apple SwiftShot** (WWDC18, 2–6 players): one-shot world-map share at join + host-authoritative compact state — the Option A pattern [44].
- **Niantic Buddy Adventure** (Pokémon GO shared AR): bounded room-scale shared-frame feature separate from the server-side geo-state game [45]. Niantic's current platform does colocalization via **VPS-activated locations or image tracking** (up to 10 users, relay server) — i.e., a *pre-mapped anchor or a marker*, not peer co-mapping [46]; its built-in SharedAR was removed from NSDK in May 2026 [47], and VPS requires scanned Sites plus per-query credits (Phase 3 material per [realtime-backend-options.md](realtime-backend-options.md) §4, not Phase 1).
- **Google Cloud Anchors** (iOS-supported): host uploads visual features to Google's cloud; peers resolve by viewing the same physical spot; powers shipped cross-platform apps (Just a Line) [48][49]. Proof that hosted visual anchors work in production — at the cost of a cloud dependency, quotas, and the same "look at the same scenery" constraint. Rejected for Phase 1 (offline park requirement, external service).
- **Apple SharePlay / GroupActivities:** synchronizes activities and media over FaceTime; provides **no cross-device spatial registration API on iPhone** [50] — not a candidate.
- **Pattern:** every shipped system uses (anchor establishment: one-shot map, hosted anchor, or VPS) + (own compact state channel) + (explicit user ritual to acquire overlap). Nobody ships GPS-aligned combat, and nobody relies on markerless peer alignment without a user ritual.

### Decision table

| Method | Establishes | Maintains | 3–15 m lane outdoors | HW/iOS floor | Verdict |
|---|---|---|---|---|---|
| A. ARWorldMap handoff | one-shot | none | fragile: lighting/feature-dependent reloc [12][13][14] | iOS 12+ | **Fallback + control condition** |
| B. Collaborative session | continuous merge | continuous [19] | unbenchmarked outdoors; ≤4 peers guidance [20] | iOS 13+ | **Primary** |
| C. NI/UWB + camera assist | pairwise 4-DoF solve [24][27] | drift-free residual monitor | ~9 m (U1) [23]; 10–50 m EDM (U2, iOS 17) [30][31] | iPhone 11+/iOS 16+ | **Co-primary quality signal + calibration assist** |
| D. Mutual visual observation | research-grade solver [36][37] | possible | plausible; unproven on iPhone | none (Vision) | R&D later (speculative) |
| E. GeoAnchors / GPS+compass | coarse (~5 m/15°) [40][42] | n/a | GeoAnchor coverage in Victoria unverified [38] | A12+ | Rejected for hit scale; keep for geofence |
| F. Shipped hybrids | — | — | — | — | Pattern evidence for A/B + ritual |

## 5. Drift, maintenance, and quality signals

1. **Drift rate to plan against:** ≈ 0.02 m per second of motion (ARKit, best-in-class in benchmark) [2]; 1–43 cm per user action in the field, worst for walk-away-and-return [3][4]. Expect the 0.35 m budget to be threatened within tens of seconds of active play without correction.
2. **Re-alignment cadence:** with Option B the correction is continuous (merges as views overlap [19]); the KIL-20 question is not "how often to re-calibrate" but "how large does the residual grow between merges during a 3-minute match" — measurable, not derivable.
3. **Quality signals available to drive the frozen Tracking Quality gates:**
   - `ARCamera.trackingState` (+ `.limited` reasons incl. `insufficientFeatures`, `relocalizing`) — per-phone hard gate [12][14].
   - `ARFrame.worldMappingStatus` — gates map capture and calibration readiness [7][8].
   - `ARParticipantAnchor` presence/updates — proof the merge is live [18].
   - NI `distance` vs shared-frame inter-phone distance — continuous cross-check residual, lighting-independent [23].
   - NI `didUpdateAlgorithmConvergence` (`NIAlgorithmConvergence`) — camera-assist convergence state during calibration [51].
   - Mutual-aim angular residual (this repo's own signal, from the calibration ritual, §6.2) — direct measurement of the fairness quantity.
4. **Rule (proposal):** firing unlocks only when *both* per-phone tracking is `.normal` *and* the pairwise residual (UWB and/or mutual-aim) is under the §3.2 gate; residual breach demotes to `TRACKING LOST — FIRE LOCKED` per the frozen copy.

## 6. Recommendation (for KIL-20; ADR after device evidence)

### 6.1 Architecture

1. **Primary: ARKit collaborative session** (`isCollaborationEnabled`) carried over the already-chosen Network.framework transport — critical data on the reliable QUIC stream, optional data on datagrams, matching Apple's priority hints [16][17][21]. The `SharedArenaFrame` provider interface (L3) wraps it, exposing establish/maintain/quality exactly as the roadmap requires.
2. **Fallback: one-shot ARWorldMap handoff** (Option A) behind the same interface — also the experimental control.
3. **Cross-check channel: NI/UWB camera-assisted ranging** when both devices are iPhone 11+/iOS 16+ — used for (a) calibration-time direct transform estimate via `worldTransform(for:)`, (b) continuous distance residual in play. Never a data channel (5 Hz [32]).
4. GPS/compass stays where it is (geofence, coarse venue). GeoAnchors: run a one-time `checkAvailability` probe in the target park and record the answer in the build log; do not build on it.

### 6.2 Calibration ritual (proposal — copy pending design freeze)

1. **Huddle (side-by-side scan):** players stand shoulder-to-shoulder, phones portrait, both facing the same feature-rich structure 3–5 m away (bench, playground, tree line — not open grass or sky). Both pan slowly left-right ~90° until each phone reaches `worldMappingStatus == .mapped` and the collaborative merge lands (`ARParticipantAnchor` received). UI: `ALIGNING SHARED ARENA…` with per-phone progress [7][18].
2. **Face-off (3 m, aim, hold 3 s):** players walk to marks ~3 m apart and aim at each other's phone, holding steady 3 s. During the hold: NI camera-assist converges (back cameras facing = inside the UWB direction cone [23]); each phone records ≥ 30 samples of (peer position per shared frame, peer position per `worldTransform(for:)`, UWB distance, own aim ray). The pairwise residual and yaw estimate come from this window.
3. **Lock check:** both phones show `SPATIAL LOCK READY` only if translation residual ≤ 0.10 m and yaw residual ≤ 0.5° (§3.2). Fail → repeat step 2 at a different spot.
4. **Expected setup time:** 60–120 s end-to-end (**speculation** — EyeConnect-class solvers converge < 5 s on glasses [36], SwiftShot-era map sharing took tens of seconds; the outdoor number is precisely what KIL-20 measures).

### 6.3 Measurement plan (what to log on devices)

Per session: device models, iOS versions, weather/light (day/dusk), surface. Per run, timestamped CSV: `trackingState`, `worldMappingStatus`, merge events, `PhonePoseSample` stream (existing contract), UWB distance + convergence state, computed inter-phone distance, mutual-aim angular residual, collaboration-data bytes in/out per second, battery/thermal state. Derived metrics: time-to-lock, alignment residual at 3/8/15 m vs tape measure, residual growth over a 3-minute scripted match, re-lock frequency and recovery time, dusk deltas.

### 6.4 What CANNOT be known without device experiments

1. Whether collaborative merges succeed at all — and how fast — on a grass field at 20–60 m scale and at dusk (no Apple or third-party outdoor benchmark exists for Option B).
2. Actual `ARCollaborationData` bandwidth and its interaction with the 20–30 Hz pose exchange on the same P2P link.
3. Achievable steady-state alignment residual (whether the 0.10 m / 0.5° gate of §3.2 is generous or impossible) and residual growth rate during play.
4. NI camera-assist behavior between two *moving* phones outdoors (Apple hints it favors stationary targets [26]) and the practical UWB range on our U1/U2 device mix.
5. Setup-time distribution for the §6.2 ritual with real players, and battery/thermal cost of camera+UWB+P2P concurrently.

## 7. Proposed KIL-20 experiment protocol (two phones, operator + assistant)

**Site & kit:** flat park area ≥ 20 × 20 m (candidate: a Victoria park lawn edge with structures in view); 30 m tape measure; chalk/cones at 3 m, 8 m, 15 m marks; two iPhones (record exact models — ideally one U1-era and one U2-era to cover both UWB generations); tripods or cones to rest phones for static reads; fully charged, logging build installed.

1. **Static baseline (10 min):** run the §6.2 ritual; record time-to-lock ×5 attempts (report success rate). Place phones at the 3 m marks on tripods facing each other. Log 60 s of: shared-frame inter-phone distance, UWB distance, mutual-aim residual. Repeat at 8 m and 15 m. Evidence: residual-vs-range table.
2. **Control comparison (10 min):** repeat step 1 once using the ARWorldMap one-shot fallback instead of collaboration. Evidence: same table, method column.
3. **Match-motion drift (3 × 3 min):** assistant walks a figure-8 between the 3 m and 15 m marks at ~1–2 m/s while the operator strafes near one mark, both phones aiming naturally. Every 15 s both players stand on chalk marks for a 2 s residual snapshot. Evidence: residual time series; count of merges/corrections; max residual.
4. **Interruption & re-lock (10 min):** cover one camera 5 s; pocket one phone 10 s; measure recovery time to `SPATIAL LOCK RESTORED` and post-recovery residual, ×5 each. Evidence: recovery table.
5. **Dusk repeat (20 min):** repeat steps 1 and 3 at civil twilight. Evidence: day-vs-dusk delta table.
6. **GeoAnchor probe (2 min):** run `ARGeoTrackingConfiguration.checkAvailability` at the site; record boolean + location description.
7. **Record for [docs/build-log.md](../build-log.md):** device names + iOS versions, per-step tables, CSV artifacts, pass/fail against the §3.2 gate (0.10 m / 0.5°), bandwidth figures, battery/thermal notes, and an explicit verdict: does Option B hold the budget for 3 minutes outdoors, or does the fallback ladder engage?

## Sources

1. Apple — ARConfiguration.WorldAlignment.gravity (world frame gravity-aligned by default) — https://developer.apple.com/documentation/arkit/arconfiguration/worldalignment-swift.enum/gravity
2. Sensors 22(24):9873 (2022) — A Benchmark Comparison of Four Off-the-Shelf Proprietary Visual–Inertial Odometry Systems (ARKit most stable; relative pose drift ≈ 0.02 m/s) — https://doi.org/10.3390/s22249873
3. Scargill, Chen, Gorlatova — Here to Stay: Measuring Hologram Stability in Markerless Smartphone Augmented Reality (mean drift 1.0–43.2 cm by action; ARKit walk-away 25.1 cm) — https://arxiv.org/abs/2109.14757
4. Scargill et al. — Here To Stay: A Quantitative Comparison of Virtual Object Stability in Markerless Mobile AR (IEEE CPHS 2022) — https://doi.org/10.1109/cphs56133.2022.9804545
5. Apple — Creating a multiuser AR experience (share map once; time-consuming, bandwidth-intensive; receiver near sender) — https://developer.apple.com/documentation/arkit/creating-a-multiuser-ar-experience
6. Apple — ARWorldMap — https://developer.apple.com/documentation/arkit/arworldmap
7. Apple — Saving and loading world data (gate capture on worldMappingStatus; prefer .mapped) — https://developer.apple.com/documentation/arkit/saving-and-loading-world-data
8. Apple — ARFrame.worldMappingStatus — https://developer.apple.com/documentation/arkit/arframe/worldmappingstatus-swift.property
9. Unity-Technologies/SharedSpheres (ARWorldMap "can be hundreds of kilobytes"; chunked transfer) — https://github.com/Unity-Technologies/SharedSpheres
10. Stack Overflow — How much data does an ARKit WorldMap take up ("seems to be around 50mb" in-memory observation) — https://stackoverflow.com/questions/60359368/swift-how-much-data-does-an-arkit-worldmap-take-up
11. Stack Overflow — Loading big ARWorldMap file (20 MB+) causing lag / crash on non-LiDAR devices — https://stackoverflow.com/questions/70123587/loading-ar-of-big-arworldmap-file-causing-delay-on-the-screen
12. Apple — ARTrackingStateReasonRelocalizing (relocalization speed/success varies with real-world conditions; timeout-and-reset advice) — https://developer.apple.com/documentation/arkit/artrackingstatereason/artrackingstatereasonrelocalizing
13. Stack Overflow — ARWorldMap lighting conditions (map saved in bright light fails to relocalize in medium light) — https://stackoverflow.com/questions/64735564/arworldmap-lighting-conditions
14. Apple — ARCamera.TrackingState.Reason.insufficientFeatures — https://developer.apple.com/documentation/arkit/arcamera/trackingstate-swift.enum/reason/insufficientfeatures
15. Experience: Practical Challenges for Indoor AR Applications (ACM MobiCom 2024; camera-based tracking degrades with lighting variation; LiDAR immune to ambient light) — https://doi.org/10.1145/3636534.3690676
16. Apple — TN3213 Moving from Multipeer Connectivity to Network framework (QUIC streams + datagram channel; P2P Wi-Fi) — https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework
17. Apple — ARSession.CollaborationData (+ priority hint for reliable/unreliable send) — https://developer.apple.com/documentation/arkit/arsession/collaborationdata
18. Apple — Creating a collaborative session (app transports data; merge requires overlapping views; ARParticipantAnchor per peer) — https://developer.apple.com/documentation/arkit/creating-a-collaborative-session
19. Apple — WWDC19 session 610, Building Collaborative AR Experiences (continuous map/anchor sharing; decentralized; merge on overlap; designed for live multiuser) — https://developer.apple.com/videos/play/wwdc2019/610/
20. Apple — ARWorldTrackingConfiguration.isCollaborationEnabled ("works best with up to four participants") — https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/iscollaborationenabled
21. Unity AR Foundation — AR Collaboration Data sample (critical: periodic/reliable; optional: near every frame/unreliable; shares participant poses + reference points only) — https://docs.unity3d.com/Packages/com.unity.xr.arfoundation@6.5/manual/samples/arkit/collaboration-data.html
22. Apple — NISession (one session per nearby object; setARSession; worldTransform(for:)) — https://developer.apple.com/documentation/nearbyinteraction/nisession
23. Apple — Initiating and maintaining a session (best within ~9 m, portrait, back cameras facing, clear line of sight; direction only in rear cone) — https://developer.apple.com/documentation/nearbyinteraction/initiating-and-maintaining-a-session
24. Apple — NINearbyPeerConfiguration (iOS 16 camera assistance; AirTag-class precision finding between peers) — https://developer.apple.com/documentation/nearbyinteraction/ninearbypeerconfiguration
25. Apple — NINearbyPeerConfiguration.isCameraAssistanceEnabled — https://developer.apple.com/documentation/nearbyinteraction/ninearbypeerconfiguration/iscameraassistanceenabled
26. Apple — WWDC22 session 10008, What's new in Nearby Interaction (camera assistance widens UWB FoV; "best used for interacting with stationary devices"; horizontalAngle) — https://developer.apple.com/videos/play/wwdc2022/10008/
27. Huo et al. — SynchronizAR: Instant Synchronization for Spontaneous and Spatial Collaborations in Augmented Reality (ACM UIST 2018; UWB-distance registration across independent SLAM frames, no mutual visibility) — https://doi.org/10.1145/3242587.3242595
28. Cappella: Establishing Multi-User Augmented Reality Sessions Using Inertial Estimates and Peer-to-Peer Ranging (IPSN 2022; UWB+VIO collaborative particle filter; median 3D error < 1 m) — https://conferences.computer.org/cpsiot/pdfs/IPSN2022-6R1M30NXCSXmbVKUqzz1Of/962400a416/962400a416.pdf
29. Apple Support — Learn about Ultra Wideband availability (U1: iPhone 11+; second-generation chip: iPhone 15+ excluding 16e/17e; regional variation) — https://support.apple.com/en-us/109512
30. Apple — Finding devices with precision (EDM sample: two iPhone 15+, iOS 17; distance-quality estimator with 10 m/50 m working constants; activeSessionsLimitExceeded handling) — https://developer.apple.com/documentation/nearbyinteraction/finding-devices-with-precision
31. Apple — NINearbyPeerConfiguration.isExtendedDistanceMeasurementEnabled — https://developer.apple.com/documentation/nearbyinteraction/ninearbypeerconfiguration/isextendeddistancemeasurementenabled
32. DeVrio, Mollyn, Harrison — SmartPoser (UIST 2023; Nearby Interaction distance updates ≈ 5 Hz) — https://arxiv.org/abs/2509.03451
33. Jutterström — Mind the Gap: UWB Fare Validation Under Apple Nearby Interaction Constraints (Uppsala 2026; summarizes Heinrich et al.: consumer smartphone UWB average ranging errors < 20 cm; NI pairwise session model) — https://uu.diva-portal.org/smash/get/diva2:2069308/FULLTEXT01.pdf
34. Apple Developer Forums — UWB (Nearby Interaction) distance measurement thread (practitioner: 5–10 m indoor phone-to-accessory; 30–40 m open with UWB beacons; U2 range expectations) — https://developer.apple.com/forums/thread/744326
35. objc2-nearby-interaction — NIErrorCodeActiveSessionsLimitExceeded (numeric error code; Apple publishes no session-count number) — https://docs.rs/objc2-nearby-interaction/latest/aarch64-apple-watchos/src/objc2_nearby_interaction/generated/NIError.rs.html
36. Snap Engineering — EyeConnect on Spectacles (mutual-look alignment from ego-poses + 2D device detections; preliminary alignment in seconds, join < 5 s typical) — https://eng.snap.com/eyeconnect
37. Ego-Motion Alignment from Face Detections for Collaborative Augmented Reality (arXiv 2020; closed-form minimal solver from ego-poses + mutual detections) — https://arxiv.org/abs/2010.02153
38. Apple — ARGeoTrackingConfiguration (A12+GPS; outdoors only; runtime checkAvailability; street-captured localization imagery excludes gated/pedestrian-only areas; 20+ countries, no city list) — https://developer.apple.com/documentation/arkit/argeotrackingconfiguration
39. Apple — WWDC21 session 10073, Explore ARKit 5 (location-anchor coverage: 5 metros → 25+ US cities + London) — https://developer.apple.com/videos/play/wwdc2021/10073/
40. TerraLab — Mobile phones and mobile GIS (iPhone 13: 3.95 m horizontal accuracy open sky; 8.6 m heavy canopy) — https://www.terralabgis.com/blog/mobile-phones-and-mobile-gis
41. Dike (Cal Poly 2024/25) — GPS Accuracy of Smartphones for Crowdsourcing Research (overall mean error ≈ 3.2 m; best iPhones ≈ 1.5 m) — https://digitalcommons.calpoly.edu/nres_rpt/53
42. Lviv Polytechnic (2026) — Use of smartphones for determining orientation angles in the field (first azimuth after calibration 1–3°; RMSE mostly ≤ 2–4°; outliers 13–25°) — https://doi.org/10.23939/istcgcap2026.103.005
43. Smartphone Sensor Reliability for Augmented Reality Applications (MOBIQUITOUS, publ. 2013; mean compass errors ~10–30°, high variance) — https://eudl.eu/doi/10.1007/978-3-642-40238-8_11
44. SwiftShot (Apple WWDC18 sample; third-party README mirror — original Apple page offline) — https://github.com/GaoGuohao/SwiftShot/blob/master/README.md
45. Niantic (archived) — Buddy Adventure shared AR (room-scale shared frame as a bounded feature) — https://web.archive.org/web/2022/https://nianticlabs.com/blog/devinsights-buddyadventuresharedar
46. Niantic Spatial — Shared AR (colocalization via VPS-activated location or image tracking; up to 10 users; relay server) — https://nianticspatial.com/docs/nsdk/features/shared_ar/
47. Niantic Spatial — NSDK migration guide (built-in SharedAR removed May 2026) — https://www.nianticspatial.com/docs/llms-nsdk/migration_guide.txt
48. Google — Cloud Anchors developer guide for iOS (host uploads visual data; resolve requires viewing same environment; 30 host/300 resolve per minute quotas) — https://developers.google.com/ar/develop/ios/cloud-anchors/developer-guide
49. Google Creative Lab — Just a Line iOS (shipped cross-platform shared drawing paired via Cloud Anchors) — https://github.com/googlecreativelab/justaline-ios
50. Apple — GroupActivities (SharePlay: shared activities/media sync; no spatial registration API on iPhone) — https://developer.apple.com/documentation/groupactivities
51. Apple — NISession didUpdateAlgorithmConvergence / NIAlgorithmConvergence (camera-assist convergence coaching) — https://developer.apple.com/documentation/nearbyinteraction/nisessiondelegate/session(_:didupdatealgorithmconvergence:for:)
