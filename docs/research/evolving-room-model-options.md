# Evolving room model for zero-step Quick Play: spatial representations, background map fusion, and the on-device / Durable Object split (BIO-36)

Status: Research complete — 2026-09-26. Read-only spike; no code, protocol, or ADR changes are proposed as part of this document.

Method: One repository-fact pass (every claim about the current product carries a path and line reference, checked against `main` on 2026-09-26); one Apple primary-documentation pass (ARKit planes, scene reconstruction, mesh anchors, scene depth, raw feature points, raycasting, collaboration, body tracking); one Cloudflare primary-documentation pass (Durable Object limits, WebSocket hibernation, lifecycle, alarms; Workers memory/CPU limits); one literature pass over the six candidate spatial representations and multi-agent map fusion (KinectFusion, voxel hashing, OctoMap, BVHs, ORB-SLAM3 Atlas, Kimera-Multi); one derivation pass (payload sizes from documented data layouts and the repo's own byte caps); one synthesis. Every non-obvious claim carries a numbered source. Practitioner sources are marked **[practitioner]**. Speculation is marked **[speculation]**. Where no authoritative figure exists, that absence is stated as an absence.

Companion: `docs/research/shared-arena-frame-options.md` (error budget and alignment methods, 2026-08-24) and `docs/decisions/0013-quick-play-sighting-hits.md` (accepted 2026-09-26). This brief does not re-derive the shared-frame error budget; it takes ADR 0013's `sighting` geometry as the playable baseline and asks what an *optional, background* room model would need.

---

## 1. Product goal restated as constraints

From the BIO-36 brief (product intent, not a repository fact):

- G1. Two-player combat starts as soon as both players are ready. No blocking scan, alignment, relocalization, map-linking, or shared-frame ritual.
- G2. Each phone continuously maps while play is active.
- G3. A match-scoped Cloudflare Durable Object is authoritative for combat.
- G4. Phones may stream trajectory and *bounded* map patches; the system may align and fuse them opportunistically into an evolving shared room model.
- G5. Combat remains playable before shared-map convergence, with explicit confidence and fallback policies.
- G6. Saved arenas remain an optional higher-fidelity mode, not a prerequisite for normal play.

Consequences that follow directly (derivation, not sourced):

- G1 + G5 mean the room model is *never* on the critical path to a hit verdict in Quick Play. Whatever representation is chosen, its absence must degrade to the current `sighting` behaviour, not to "cannot fire".
- G3 + Cloudflare's single-threaded Durable Object model (§6) mean the authority can *store, version and gate* spatial state, but should not be the place where dense geometry is fused per frame.
- G2 + G4 mean the on-device representation and the wire representation can differ: phones may keep a rich local model and export only a compact, bounded summary.

---

## 2. Repository facts verified (2026-09-26, `main`)

Each statement below was checked in the working tree. Line numbers refer to `main` at the time of writing.

### 2.1 iOS uses ARKit + Vision and already has plane-detection paths — CONFIRMED, with a qualifier

- `ios/VictoriaKillZone/VictoriaKillZone/Targeting/TargetingSession.swift:1431` sets `configuration.planeDetection = [.horizontal, .vertical]` on an `ARWorldTrackingConfiguration` in `beginFrameMapping(epoch:mode:)` (L1411); L1432 sets `isCollaborationEnabled = mode == .collaborative`.
- The same flag is set at `TargetingSession.swift:1666` and `:1676` on `ARBodyTrackingConfiguration` / `ARWorldTrackingConfiguration` (measured/body path), and in `Targeting/MapLab/MapLabARDriver.swift:137` (Scan & Save, world tracking only — L86).
- Vision body pose: `TargetingSession.swift:808` (`VNDetectHumanBodyPoseRequest()`); `usesBodyTracking = ARBodyTrackingConfiguration.isSupported` at L798.
- One raycast call exists: `TargetingSession.swift:1627` `arSession.raycast(query)` (measured DuelFrame path).
- **Qualifier (absence):** there are **zero** occurrences of `ARPlaneAnchor`, `ARMeshAnchor`, `sceneReconstruction`, `sceneDepth` or `smoothedSceneDepth` in the iOS tree. Plane detection is *enabled* but plane anchors are not consumed as geometry, and there is no LiDAR mesh or depth code. "Has plane-detection paths" is true at the configuration level only.

### 2.2 `sighting` fire carries body evidence, not wall/surface evidence — CONFIRMED

- `packages/combat-protocol/src/index.ts:65` — `fire` = `{kind, shotId, poseSequence, origin, direction, observation?: BodyObservation | null}`.
- `index.ts:25–31` — `BodyObservation` = `{targetPlayerId, capturedAtMs, associationConfidence, uncertaintyMeters, colliders: BodyCollider[]}`; `BodyCollider` (L22–24) is a sphere or capsule with a body `zone`.
- `packages/combat-protocol/src/validation.ts:28–29` enforces exactly those keys. No field in `CombatCommand`, `BodyObservation`, `CombatEvent` or `ProjectileState` carries wall, surface, plane, mesh or environment evidence.
- `packages/combat-simulation/src/index.ts:136` — under `sighting`, readiness is `players.every(p => p.connected)`; L216 refuses fire only on `!connected || (!frameReady && !sighting)`. `flight.ts:139–142` resolves a sighting hit "in the shooter's camera space with no shared frame or rewind", sweeping `observation.colliders` only (L146–151). `slowField` is refused under sighting (`index.ts:251`).

### 2.3 Convex handles lobby/match preparation and projects match state — CONFIRMED

- `convex/functions/combat.ts:31–36` `selectCombatGeometry`: two-player Quick Play defaults to `sighting`; `sighting` with roster > 2 falls back to `phoneProxy`; `phoneProxy` with roster ≤ 2 is upgraded to `sighting`. Rules are baked at `prepare` (L60).
- `combat.ts:67–96` issues a signed ticket (`lib/combat_ticket.ts`; 120 s lifetime; claims include `matchId, playerId, roster, authorityEpoch, frameEpoch, rules`) pointing at `${endpoint}/v1/matches/{id}/connect`.
- `combat.ts:98–114` accepts a signed `CombatProjection` from the worker (`lib/combat_projection.ts`; monotone sequence, idempotency conflict on digest mismatch). `packages/combat-protocol/src/index.ts:150–157` documents the projection as "no camera, map or body observations".
- iOS requests geometry at `Features/Lobby/LobbyStore.swift:365` (`savedArena == nil ? "phoneProxy" : "trackedBody"`); Convex then applies the ADR 0013 upgrade.

### 2.4 A Cloudflare Durable Object runs the real-time combat simulation — CONFIRMED

- `services/combat-worker/src/room.ts:28` `CombatRoom extends DurableObject<Env>`, one object per `matchId` (`index.ts:24`, `getByName`).
- Routes (`routes.ts`): `/v1/matches/:id/(connect|report|frames/:epoch/map)`.
- `/connect` WebSocket: player cap → `409 roomFull` (`room.ts:138`); text-only messages, `LIMITS.messageBytes = 16_384`, `collabMessageBytes = 386_000`, `collabBytes = 384_000` (`combat-protocol/src/index.ts:4`); per-connection token buckets; `QueueFullError` → close 4008 "input-queue-full" (`serial-queue.ts`); alarm set on connect (L163).
- `collab` messages (`room.ts:218–227`) relay opaque base64 `ARCollaborationData` to *other* connections under a per-peer byte budget; the DO never decodes it. `niToken` (L229–234) is relayed the same way.
- `/frames/:epoch/map` (`maps.ts`): GET/PUT of an opaque `ARWorldMap` archive, ≤ `LIMITS.mapBytes` = 8 MiB, 15 s deadline, one concurrent upload, SHA-256 frame id, chunked into 128 KiB `map_chunks` rows in DO SQLite; PUT is host-only (`room.ts:99–108`).
- Persistence: `store.ts` checkpoints the simulation; on boot it restores with `authorityEpoch + 1` and closes hibernated sockets with 1012 "authority-restarted" (`room.ts` ~L52–70).
- **Absence:** the DO holds no decoded geometry of any kind. It stores bytes it cannot interpret.

### 2.5 Normal Deploy does not deploy the combat worker; a guarded operator script does — CONFIRMED

- `.github/workflows/deploy.yml` deploys Convex and the spectator Pages site after green CI on `main` (gated on `vars.VKZ_DEPLOY_ENABLED`); there is no combat-worker job.
- `scripts/release/combat-deploy.mjs` (with `combat-deploy-self-test.mjs`): requires a 40-hex `VKZ_CANDIDATE_SHA`, `VKZ_CONVEX_CONFIGURATION_CONFIRMED === "true"` (else `convex-operator-handoff-required`), an evidence path outside the checkout, secrets over stdin (TTY rejected), dry-run by default (`preflight-passed`, `externalWrites:false`), deploy only with an explicit flag, and a post-deploy health receipt `service === "vkz-combat"`.

### 2.6 Other repository facts relevant to this brief

- **ADR 0012 is absent from `main`.** `docs/decisions/` goes 0011 → 0013. Commit `8f043ed` (`0012-quick-play-ni-rendezvous.md`) exists only on unmerged branch `origin/docs/adr-0012-ni-rendezvous` (PR #105). Its implementation slices (#112–#115, `niToken` relay, `NISession` per peer) *did* merge. ADR 0013 cites 0012 as "PR #105" and records that none of ADR 0010/0011/0012 achieved device alignment.
- **No spatial-model vocabulary exists yet.** Zero hits for voxel/TSDF/occupancy/BVH across docs, code and outputs. "mesh" appears only as SceneKit skeleton geometry (`Features/Game/SkeletonMeshAsset.swift`).
- **Physical-device evidence (`docs/build-log.md`, last entry 2026-09-22):** no entry shows plane detection, scene mesh, or body-pose detection verified on a named device. The 2026-09-22 two-phone run (arena `5Q85SK`) reached WebSocket 101 but "both phones stalled in 'Linking play area'"; the log hypothesises collaboration archives exceeding the relay bound. 2026-09-14 relocalized lanes: "Observed on physical devices: None". This brief therefore treats *all* on-device mapping behaviour as documented-but-unverified for this app.

---

## 3. Candidate spatial representations

Evaluation axes: (a) what ARKit gives for free on iPhone; (b) what a hit/cover/projectile query needs; (c) per-patch byte cost on the wire; (d) how it tolerates two disagreeing frames and drift; (e) how it handles moving people and furniture; (f) whether the Durable Object can hold it inside documented limits (§6).

### 3.1 ARKit plane anchors

- ARKit reports observed planar surfaces as `ARPlaneAnchor` with geometry, extent, alignment and (on supported configurations) a classification [1]. Plane detection is available on both `ARWorldTrackingConfiguration` and `ARBodyTrackingConfiguration` [2], which matters because the current targeting session already runs body tracking (§2.1).
- Raycasts can target existing plane geometry, infinite extensions of planes, or estimated planes [3].
- Cost: a plane is a transform + extent (+ optional polygon). Derivation: transform 4×4 f32 = 64 B, extent 2 f32 = 8 B, classification 1 B → ~73 B per plane uncompressed; a room with 30 planes ≈ 2.2 KB. Fits in one 16 KiB `LIMITS.messageBytes` frame (§2.4).
- Strengths: cheapest; semantically labelled (floor/wall/table/ceiling/seat/door/window on supporting devices [1]); ARKit smooths the LiDAR mesh where it detects planes [4], so planes and meshes agree on flat surfaces; no LiDAR required.
- Weaknesses: only flat surfaces; no occupancy of the space between planes; a plane's extent grows and merges over time, so "the same wall" is not a stable identity across two phones without matching.
- Verdict: **the right first wire format for bounded patches.** Everything cover-related for two players in a room (walls, big furniture tops, doorways) is a plane at game scale.

### 3.2 ARKit scene-reconstruction meshes (`ARMeshAnchor`)

- With `sceneReconstruction` enabled on a *world-tracking* configuration, ARKit provides a polygonal mesh estimating the physical environment, subdivided into mesh anchors that ARKit updates constantly as it refines the scene [4][5]. Requires a LiDAR device; call `supportsSceneReconstruction(_:)` first [6]. `ARMeshGeometry` exposes vertices, normals, faces, and per-face classification (wall, floor, ceiling, table, seat, window, door, none) [7][8].
- **Apple states the mesh is not intended to reflect physical changes in real time** [5]. People occlusion removes mesh where people are detected [4][9].
- **Configuration conflict (Apple, explicit):** Apple's configuration guide says to use `ARBodyTrackingConfiguration` "if you don't need user face-tracking, collaboration, or scene reconstruction" [2] — i.e. scene reconstruction and collaboration are world-tracking features. Whether a session can alternate configurations while keeping environment data is documented in general ("Where possible, ARKit maintains all the information collected during the session under the prior configuration" [2]) but not for this specific pairing. **The current live sighting path runs body tracking (§2.1); adding meshes would force either a config switch or Vision-only body pose on a world-tracking session. This is the single largest engineering unknown and must be measured on device.**
- Cost derivation (from the documented layout [7]: vertex 3×f32, normal 3×f32, face 3×uint32): a 1 m² patch at ~5 cm triangle edge ≈ 800 faces, ≈ 450 vertices → ~10.8 KB vertices+normals + 9.6 KB faces ≈ 20 KB uncompressed per m² of surface. A 4 × 5 m room with ~2.4 m ceiling has ~100 m² of wall/floor/ceiling surface → ~2 MB uncompressed before furniture. That exceeds the 16 KiB WebSocket cap by ~125× per full push and sits at the 2 MB DO row/value limit [10]. **No official Apple figure exists for mesh-anchor block size or update rate; the above is derivation, not a benchmark.**
- Verdict: **on-device only.** Excellent local query surface (raycast, cover, projectile occlusion) on LiDAR phones; wrong thing to stream raw. Export as planes (§3.1) or as decimated patches (§3.5).

### 3.3 Triangle soup + BVH

- A BVH partitions primitives into a hierarchy of bounding boxes so a ray skips whole subtrees; memory is bounded at 2n−1 nodes for n primitives; BVHs are cheaper to build and more numerically robust than kd-trees [11].
- In this game the "soup" would be the union of mesh-anchor triangles (§3.2) or plane polygons (§3.1). A BVH is an *index* over a representation, not a representation. It answers "first surface along this ray" — exactly the cover/projectile query a world-aware mode needs.
- Cost: rebuild per mesh-anchor update; ARKit updates anchors constantly [5], so a per-anchor BVH with a top-level BVH over anchors (two-level) avoids global rebuilds. This is standard practice, not a sourced claim about ARKit.
- Verdict: **on-device query structure over whatever geometry the phone holds.** Never on the wire; never in the DO.

### 3.4 Rolling voxel occupancy grid

- Occupancy grids model occupied, free *and unknown* space probabilistically; probabilistic updates absorb sensor noise and dynamic changes; multiple robots can contribute to one map; octree storage keeps them compact and multi-resolution [12].
- Fit: "unknown" is a first-class value, which is exactly what a confidence policy (§8) needs — a cover query that hits unknown space can say "no verdict" instead of "clear". Probabilistic decay handles a chair that moved (§7). A rolling window keyed to the player's position bounds memory.
- Cost derivation: 10 cm voxels over 5 × 5 × 2.5 m = 62,500 cells; at 1 byte log-odds each = 61 KB dense, far less sparse. A 1 m³ block = 1,000 cells = 1 KB → one block per 16 KiB message with headroom. **Two phones with unaligned frames cannot share cells until a transform is known** (§4); before that, occupancy is local only.
- Input: needs depth. On LiDAR phones `sceneDepth` / `smoothedSceneDepth` supply per-pixel distance with a confidence map when the frame semantic is requested and supported [13][14]. On non-LiDAR phones only plane anchors and `rawFeaturePoints` exist; raw feature points are "not guaranteed … stable between … subsequent frames" and are described by Apple as a debugging aid [15]. **Absence:** Apple publishes no depth-accuracy figure for LiDAR scene depth.
- Verdict: **best candidate for the *shared* model if a shared model is built**, because it is the only representation here that natively encodes uncertainty and free space and merges by cell update rather than by geometry surgery. Coarse (10–20 cm) is enough for cover; not for rendering.

### 3.5 TSDF-style volumetric models

- KinectFusion fuses live depth maps into a truncated signed-distance volume in real time on GPU [16]; voxel hashing stores TSDF only near observed surfaces, streams blocks in/out with sensor motion, and scales to large scenes [17].
- Fit: produces smooth surfaces and supports raycasting directly (§3.6). Apple's own scene reconstruction is, in effect, a productised depth-fusion pipeline whose output is the mesh in §3.2; Apple does not document its internals, so calling it "TSDF" is **[speculation]**.
- Cost: TSDF blocks carry a distance and weight per voxel — 2–4× the bytes of occupancy at the same resolution, and they need dense depth (LiDAR) to be worth it. On non-LiDAR phones there is no input.
- Verdict: **do not build one.** On LiDAR devices ARKit already gives the fused result as a mesh; building a second fusion pipeline duplicates Apple's work and costs battery. Its ideas (per-voxel weight = confidence, block streaming = rolling window) transfer to §3.4.

### 3.6 Sparse surface patches

- Meaning here: planar or gently curved patches with an origin, normal, extent, confidence and observation count — a superset of §3.1 planes that can also come from a decimated mesh region.
- Fit: bounded, cheap, semantic, and *the unit that the two phones can match*: two patches with parallel normals, similar extents and the same classification are a correspondence hypothesis for alignment (§4.1). Kimera-Multi's robots exchange compact place-recognition data, not dense meshes, and deform their local meshes after alignment [18] — the same shape as "exchange patches, keep dense geometry local".
- Cost: ~100 B per patch (derivation as §3.1 plus confidence, count, timestamps). Even 200 patches ≈ 20 KB → two messages.
- Verdict: **the wire format.** A patch stream is what "bounded map patches" (G4) should mean concretely.

### 3.7 Signed-distance / raycast representations

- A signed-distance field answers "how far to the nearest surface, and on which side" in O(1) per lookup, which makes sphere-tracing raycasts and swept-capsule tests trivial. It is the query view of a TSDF (§3.5) or can be derived from planes/occupancy on the fly.
- Fit: the game's queries are all rays and swept volumes (`flight.ts` already sweeps colliders, §2.2). A local SDF over planes is cheap: distance to the nearest of N planes is N dot products.
- Cost: dense SDF grids are the largest option; analytic SDFs over planes are the smallest. Never on the wire.
- Verdict: **on-device query layer**, either analytic over planes/patches (non-LiDAR) or a BVH over the mesh (LiDAR). Which one to use is a device-capability decision made at session start, not a product decision.

### 3.8 Summary table

| Representation | Source on iPhone | Wire? | DO? | Handles unknown/dynamic | Verdict |
|---|---|---|---|---|---|
| Plane anchors | All devices (world or body config) [1][2] | Yes (~73 B/plane) | Store as patches | Weak / grows monotonically | First wire format |
| Mesh anchors | LiDAR + world tracking only [5][6] | No (~20 KB/m²) | No | Not real-time by design [5] | Local query surface |
| Triangle soup + BVH | Derived | No | No | Rebuild per update | Local index |
| Occupancy grid (rolling) | Needs depth for free space; planes only otherwise | Blocks (~1 KB/m³ @10 cm) | Store blocks after alignment | Yes — native | Shared model, if any |
| TSDF | LiDAR; duplicates ARKit | No | No | Weighted | Do not build |
| Sparse surface patches | Derived from planes/mesh | Yes (~100 B) | Yes | Confidence + age | Wire format + matching unit |
| SDF / raycast | Derived | No | No | Inherits | Local query layer |

---

## 4. Background alignment and fusion of two independently originated maps

Two phones start Quick Play with two unrelated world origins. Everything in this section is about estimating **T₍B→A₎**, the rigid transform (6-DoF; scale is metric on ARKit) taking phone B's frame into phone A's, *without* either player doing anything.

### 4.1 Candidate correspondence sources

1. **ARKit collaboration data.** ARKit "regularly outputs" `ARSession.CollaborationData` that participants share so everyone sees the same content; each datum carries a `priority` hint for transport [19]. When the maps merge, ARKit surfaces the other device as an `ARParticipantAnchor` (see the 2026-08-24 brief, §4.2). This *is* automatic background alignment — Apple does the feature matching. What the repo has shown: the relay exists (§2.4), but the 2026-09-22 two-phone run stalled in "Linking play area" (§2.6); the log's hypothesis is oversize archives. **Apple publishes no byte rate, no merge-time bound, and no overlap requirement** (absence, restated from the 2026-08-24 brief). Collaboration requires world tracking, not body tracking [2].
2. **Relative device/player observations.** Phone A sees player B's body (Vision pose) at a bearing and estimated range in A's frame; if B simultaneously reports its own pose in B's frame, each mutual observation is one constraint on T₍B→A₎. A single observation fixes translation up to the range error and one rotation axis poorly; several observations from different positions over the first ~30 s of play over-determine the transform (derivation). The `sighting` fire and `coverage` messages already carry exactly this body evidence (§2.2) — so the alignment estimator can be fed by *combat traffic that already exists*, at zero extra bandwidth. Error is dominated by monocular body-range estimation; the repo's `uncertaintyMeters` field is the natural weight.
3. **UWB / Nearby Interaction.** Per-peer `NISession` code is live (§2.1). Distance is precise where supported; direction requires `supportsCameraAssistance` / direction-capable hardware (the repo checks both). One range is one constraint; not enough alone, strong as a scale-free sanity check on 2.
4. **Feature/patch correspondences.** Match sparse patches (§3.6) by classification, normal, extent, and mutual geometry (e.g. floor plane fixes roll/pitch/height immediately; a wall pair fixes yaw up to a discrete ambiguity). Cheap, but a rectangular room has 4-fold yaw ambiguity and 2-fold mirror ambiguity that only 1–3 can break. ORB-SLAM3's Atlas merges disconnected maps via place recognition with geometric verification [20]; Kimera-Multi rejects wrong inter-robot loop closures with graduated non-convexity because perceptual aliasing "often results in wrong inter-robot data associations … which in turn cause catastrophic failures" [18]. **[practitioner-adjacent inference]** rooms in the same building are highly aliased; patch matching alone must never be trusted to commit a transform.

### 4.2 Confidence-scored transform

Recommended estimator shape (design, not sourced): a single 6-DoF pose graph node per phone-pair with a covariance, updated by weighted constraints from 4.1.1–4.1.4, with robust (Huber/GNC-style [18]) rejection. Expose a scalar `frameConfidence ∈ [0,1]` plus a translation/yaw 1σ. Policy thresholds (proposal, to be measured): `< 0.4` unaligned, `0.4–0.8` coarse (cover hints only), `≥ 0.8` aligned (world-aware verdicts allowed).

### 4.3 Where fusion runs

- **Transform estimation: on the phone(s)**, symmetrically. Each phone estimates T from what it observes plus what the peer reports; the DO receives both estimates with confidence and picks/averages, or simply records both. The DO never runs ICP or bundle adjustment: it is single-threaded, has 128 MB per isolate and a CPU-time budget per invocation [10][21].
- **Geometry fusion (occupancy cell updates, patch merging): on the phone that queries it.** Once T is known, B's patches/blocks are transformed into A's frame *on A*, and vice versa. The DO relays and stores; it does not fuse.
- **What the DO fuses:** metadata only — the current best T, its confidence, the patch/block manifest (ids, hashes, versions), and the policy state (§8). That is the "evolving shared room model" at the authority: a *manifest with a confidence*, not a mesh.

---

## 5. Drift, loop closure, and map lifecycle

- **Intra-phone drift.** ARKit corrects its own drift internally; the app sees it as anchor transforms changing. Anything the phone exported (a patch at pose P) is stale after correction. Mitigation: export patches *relative to an ARKit anchor id*, not in raw world coordinates, and re-send a small "anchor moved" delta rather than the patch. Loop closure inside one phone is Apple's business [20 gives the general mechanism: short/mid/long-term data association; Apple does not document its own].
- **Inter-phone loop closure = re-estimating T.** Every new mutual observation (§4.1.2) is a loop-closure candidate for the pair graph. Treat T as a time series with a confidence, never as a constant; ADR 0013's framing that `frameReady` is not a gate makes this safe.
- **Tracking loss.** `ARCamera.trackingState` `.limited` / `.notAvailable` (2026-08-24 brief §4) should freeze patch export and drop `frameConfidence` toward zero until relocalised; combat continues in `sighting`.
- **Lifecycle bound.** The room model is match-scoped, like the DO. Durable Objects hibernate after ~10 s idle when hibernatable and are evicted entirely after 70–140 s of inactivity; in-memory state resets on wake and the constructor re-runs [22][23]. Anything worth keeping across a hibernation must be in DO storage (SQLite; 10 GB per object, 2 MB per row/value [10]) or in the WebSocket attachment. Alarms give at-least-once wake-ups for GC of stale patches [24]. Saved arenas (G6) are the *only* persistence beyond a match; that path already exists (`ARWorldMap`, §2.4) and is untouched by this proposal.

---

## 6. Bandwidth and storage bounds

Documented limits, then how the design fits inside them.

| Limit | Value | Source |
|---|---|---|
| DO WebSocket received message | 32 MiB | [10] |
| Repo text message cap | 16,384 B (`LIMITS.messageBytes`) | §2.4 |
| Repo collab message / per-peer budget | 386,000 B / 384,000 B | §2.4 |
| Repo map PUT cap | 8 MiB, one concurrent upload, 15 s | §2.4 |
| DO SQLite storage per object | 10 GB (Paid) | [10] |
| DO key+value / row / BLOB size | 2 MB | [10] |
| DO requests per object (soft) | ~1,000 req/s; overload errors after queuing | [10] |
| DO concurrency | single-threaded per object | [10] |
| Isolate memory | 128 MB | [21] |
| CPU per invocation | 30 s default, configurable to 5 min (Paid) | [10][21] |
| Hibernation idle | ~10 s (hibernatable) / 70–140 s eviction | [22][23] |

Design fit (derivation):

- **Patch stream.** ≤ 100 B/patch, ≤ 50 patches per 16 KiB message, at ≤ 1 message/s per phone → ≤ 16 KiB/s per phone, ≤ 32 KiB/s into the DO for two players; ~2 req/s against a ~1,000 req/s soft cap. A 10-minute match accumulates ≤ 19 MB per phone *if never deduplicated*; with version/hash dedupe on the manifest it is orders of magnitude less. Fits the 2 MB row limit if each patch (or each 1 m³ occupancy block) is its own row.
- **Occupancy blocks (optional, LiDAR phones).** 1 KB per 1 m³ block at 10 cm; a 5 × 5 × 2.5 m room = 63 blocks = 63 KB per full push; deltas are smaller. Trivial against every limit above.
- **Raw mesh.** ~2 MB per room per push (§3.2). Fits the 32 MiB socket limit and *exactly* touches the 2 MB row limit; at "constant" update rates [5] it would dominate CPU in a single-threaded object. **Not on the wire.**
- **ARWorldMap (saved arenas).** Already handled by the 8 MiB bulk path; unchanged.
- **Absences:** Apple publishes no `ARCollaborationData` byte rate, no mesh-anchor block size or update cadence, and no plane-anchor count bound. Cloudflare publishes no per-object bandwidth figure separate from message size and request rate. All per-second numbers above are derived budgets, not measurements.

---

## 7. Dynamic objects: players, furniture, doors

- **People.** Apple's scene reconstruction removes mesh that overlaps detected people when person segmentation is enabled [4][9]; `personSegmentationWithDepth` populates `estimatedDepthData` and `segmentationBuffer` [9]. Whether person frame semantics coexist with body tracking in one configuration is device/configuration dependent (`supportsFrameSemantics`) and is **unverified for this app** (§2.6). Rule: player bodies are *never* part of the room model; they are `BodyObservation`s (§2.2). A cover query that would be blocked by the opponent's own body is a hit, not cover.
- **Furniture and doors.** Apple's mesh is explicitly not real-time for physical changes [5]. Only an occupancy model with decay (§3.4) or patch age/observation-count (§3.6) degrades gracefully: a patch not re-observed for N seconds loses confidence and stops counting as cover. OctoMap's probabilistic update was designed for exactly this [12].
- **Policy.** Cover blocks a shot only if the blocking patch/cell has confidence above threshold *and* was observed by the **shooter's** phone within the last N seconds; peer-only geometry never overrides the shooter's own view. This keeps the ADR 0013 principle — the shooter's camera is the evidence — intact when a room model is added.

---

## 8. Combat before convergence: confidence and fallback policies

State machine per match (proposal):

| State | Condition | Hit geometry | World features |
|---|---|---|---|
| S0 `sighting` | default; always available | ADR 0013 `sighting` (§2.2) | none; camera-relative tracers |
| S1 `sighting + local cover` | shooter's phone has ≥ K planes/patches with confidence ≥ c₁ | `sighting` verdict, but a shot may be *voided* (not redirected) if the shooter's own recent geometry blocks the ray to the observed body | per-phone cover, no shared coordinates needed |
| S2 `coarse shared frame` | `frameConfidence ≥ 0.4` | still `sighting` | peer's approximate position drawn as a hint; shared patches shown faded |
| S3 `world-aware` | `frameConfidence ≥ 0.8` for ≥ T seconds and both phones agree within tolerance | world-space projectiles and cover (a new geometry value, not `sighting`) | full shared room model |
| Saved arena | host-selected saved map, existing `trackedBody` path | as today | as today |

Rules: transitions *down* are immediate on any confidence drop, tracking loss, or disconnect; transitions *up* require hysteresis. S1 requires **no** networking beyond today. S2/S3 are gated on measurements that do not exist yet (§10). S0→S1 is the only step recommended for engineering next, because it is the first step that touches wall/surface evidence and it is entirely on-device.

Protocol implication (not proposed here, only noted): S1 needs the `fire` command or a sibling to carry a `voidedByCover` reason or a surface evidence block — the first wall/surface evidence in the protocol (§2.2 currently has none). S3 would need a new `CombatRules.geometry` value; ADR 0013 lists the current three.

---

## 9. Recommendations

1. **Keep `sighting` as the unconditional floor.** No room-model state may gate `start`, `coverage` or `fire`. (G1, G5; §2.2.)
2. **Start consuming the plane anchors the session already detects.** Zero new ARKit features, no LiDAR requirement, no configuration change: `TargetingSession` enables plane detection today but discards the anchors (§2.1). Build the on-device SDF/BVH query layer over planes first (§3.7), and measure on a named device whether plane anchors arrive usefully while body tracking runs.
3. **Define the wire unit as a sparse surface patch (§3.6), ≤ ~100 B, anchored to an ARKit anchor id, with confidence, observation count and last-seen time.** Never stream raw mesh. Fit inside the existing 16 KiB text-message cap and token buckets; no new DO route is required for S1, and S2/S3 would need only a `patch` message and a small manifest table.
4. **Estimate T₍B→A₎ on-device from evidence that already flows** — body observations in `coverage`/`fire`, NI ranges — with ARKit collaboration data as an *additional* input if the "Linking play area" stall (§2.6) is fixed, never as a prerequisite. The DO stores `{T, confidence, σ}` per pair and the patch manifest; it fuses nothing dense (§4.3, §6).
5. **If a shared dense model is ever wanted, make it a coarse rolling occupancy grid (10–20 cm) on LiDAR phones (§3.4)**, fused on the phone that queries it. Do not build a TSDF pipeline (§3.5); do not put a BVH in the DO (§3.3).
6. **Treat furniture/door changes with patch decay and shooter-side precedence (§7).** Player bodies are never room geometry.
7. **Resolve the body-tracking vs world-tracking configuration question on device before committing to meshes.** Apple's guidance puts collaboration and scene reconstruction on the world-tracking configuration [2]; the live sighting path uses body tracking (§2.1). Options are a configuration switch, Vision-only pose on world tracking (already partially present via `VNDetectHumanBodyPoseRequest`), or planes-only (which body tracking supports [2]). This is the gating measurement for anything beyond S1.
8. **Saved arenas stay as-is** (`ARWorldMap`, 8 MiB bulk path, `trackedBody`) and become the S3-quality mode without waiting on live fusion (G6).
9. **Do not write an ADR from this brief alone.** The recommendations above depend on §10 measurements that AGENTS.md requires to name a device, iOS version and build.

---

## 10. What cannot be known without device experiments

Each item names the measurement and why the literature cannot substitute for it.

1. Plane-anchor yield while `ARBodyTrackingConfiguration` is running with Vision body pose: count, time-to-first-floor, time-to-first-wall, in the rooms players actually use. No Apple figure exists.
2. Whether switching between body-tracking and world-tracking configurations mid-match preserves planes/anchors, and its cost in tracking-state dips. Apple documents preservation only "where possible" [2].
3. On LiDAR iPhones: mesh-anchor block count and update cadence in a residential room; bytes per anchor as delivered by `ARMeshGeometry`. Needed to validate the §3.2 derivation.
4. Actual `ARCollaborationData` sizes and cadence for two phones in one room, against the raised relay budget noted in the 2026-09-22 build-log entry, and the observed time-to-`ARParticipantAnchor`. This decides whether 4.1.1 is a usable input at all.
5. Monocular body-range error (`uncertaintyMeters`) at 2–8 m indoors, which bounds how fast §4.1.2 converges to a usable T.
6. Battery and thermal cost of plane detection + body tracking + (optionally) scene reconstruction over a 10-minute match on the minimum supported iPhone.
7. Person-segmentation frame semantics coexisting with body detection on the shipping configuration (`supportsFrameSemantics`), which decides whether §7's "never map people" is free or needs app-side masking.

Until 1–2 are measured on a named device, only S0 (today) and the on-device parts of S1 should be engineered.

---

## Sources

Apple primary documentation (accessed 2026-09-26 unless noted)

1. Apple — `ARPlaneAnchor`. https://developer.apple.com/documentation/arkit/arplaneanchor
2. Apple — Configuration Objects ("use `ARBodyTrackingConfiguration` … if you don't need user face-tracking, collaboration, or scene reconstruction"; "Where possible, ARKit maintains all the information collected during the session under the prior configuration"). https://developer.apple.com/documentation/arkit/configuration-objects — and `ARBodyTrackingConfiguration` (`planeDetection`, `initialWorldMap`). https://developer.apple.com/documentation/arkit/arbodytrackingconfiguration
3. Apple — `ARRaycastQuery.Target` (existing plane geometry, infinite planes, estimated planes). https://developer.apple.com/documentation/arkit/arraycastquery/target-swift.enum
4. Apple — `ARWorldTrackingConfiguration.sceneReconstruction` (polygonal mesh estimate; plane detection smooths mesh; people occlusion adjusts mesh). https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/scenereconstruction
5. Apple — `ARMeshAnchor` (scene subdivided into mesh anchors; data "constantly updates"; "not intended to reflect physical changes in real time"). https://developer.apple.com/documentation/arkit/armeshanchor
6. Apple — `supportsSceneReconstruction(_:)` ("requires a device with a LiDAR Scanner"). https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/supportsscenereconstruction(_:)
7. Apple — `ARMeshGeometry` (vertices, normals, faces, per-face classification; classification 0 = none). https://developer.apple.com/documentation/arkit/armeshgeometry
8. Apple — `ARMeshClassification` (ceiling, door, floor, none, seat, table, wall, window). https://developer.apple.com/documentation/arkit/armeshclassification
9. Apple — `ARConfiguration.FrameSemantics.personSegmentationWithDepth` (populates `estimatedDepthData`, `segmentationBuffer`); and `frameSemantics` note that scene reconstruction removes mesh overlapping detected people. https://developer.apple.com/documentation/arkit/arconfiguration/framesemantics-swift.struct/personsegmentationwithdepth ; https://developer.apple.com/documentation/arkit/arconfiguration/framesemantics-swift.property
10. Cloudflare — Durable Objects Limits (10 GB SQLite per object on Paid; 2 MB key+value / row / BLOB; 32 MiB received WebSocket message; 30 s default CPU, configurable to 5 min; single-threaded; ~1,000 req/s soft limit with overload errors after queuing). https://developers.cloudflare.com/durable-objects/platform/limits/
11. Pharr, Jakob, Humphreys — *Physically Based Rendering*, 4th ed., §7.3 Bounding Volume Hierarchies (2n−1 node bound; build cost and robustness vs kd-trees). Textbook. https://pbr-book.org/4ed/Primitives_and_Intersection_Acceleration/Bounding_Volume_Hierarchies
12. Hornung, Wurm, Bennewitz, Stachniss, Burgard — *OctoMap: An Efficient Probabilistic 3D Mapping Framework Based on Octrees*, Autonomous Robots 2013; project page (occupied/free/unknown; probabilistic updates for noise and dynamic changes; multi-robot contribution; compact exchange). Peer-reviewed + project site. https://octomap.github.io/
13. Apple — `ARFrame.sceneDepth` (nil by default; request `sceneDepth` frame semantic; LiDAR; distance + confidence). https://developer.apple.com/documentation/arkit/arframe/scenedepth
14. Apple — `ARFrame.smoothedSceneDepth` (temporally smoothed; `supportsFrameSemantics`). https://developer.apple.com/documentation/arkit/arframe/smoothedscenedepth
15. Apple — `ARFrame.rawFeaturePoints` (not stable between releases or frames; "useful when debugging"). https://developer.apple.com/documentation/arkit/arframe/rawfeaturepoints
16. Izadi et al. — *KinectFusion: Real-time 3D Reconstruction and Interaction Using a Moving Depth Camera*, UIST 2011. Peer-reviewed. https://www.microsoft.com/en-us/research/publication/kinectfusion-real-time-3d-reconstruction-and-interaction-using-a-moving-depth-camera/
17. Nießner, Zollhöfer, Izadi, Stamminger — *Real-time 3D Reconstruction at Scale using Voxel Hashing*, ACM TOG 2013 (surface data stored only where observed; block streaming in/out with sensor motion). Peer-reviewed. https://niessnerlab.org/papers/2013/4hashing/niessner2013hashing.pdf
18. Tian et al. — *Kimera-Multi: Robust, Distributed, Dense Metric-Semantic SLAM for Multi-Robot Systems*, IEEE T-RO 2022 (arXiv 2106.14386); and Chang et al., *Kimera-Multi: a System for Distributed Multi-Robot Metric-Semantic SLAM*, ICRA 2021 (arXiv 2011.04087) — inter-robot loop closures, perceptual aliasing → outlier loop closures → catastrophic failure, GNC-based robust back-end, local mesh deformation after alignment. Peer-reviewed. https://arxiv.org/abs/2106.14386 ; https://arxiv.org/abs/2011.04087
19. Apple — `ARSession.CollaborationData` (ARKit "regularly outputs" data users share; `priority` transport hint). https://developer.apple.com/documentation/arkit/arsession/collaborationdata
20. Campos, Elvira, Gómez Rodríguez, Montiel, Tardós — *ORB-SLAM3: An Accurate Open-Source Library for Visual, Visual-Inertial and Multi-Map SLAM*, IEEE T-RO 2021 (short/mid/long-term data association; Atlas multi-map merging via place recognition; 9 mm hand-held accuracy on TUM-VI as "representative of AR/VR"). Peer-reviewed. https://arxiv.org/abs/2007.11898
21. Cloudflare — Workers Limits (128 MB per isolate; CPU time per request 30 s default / 5 min Paid; "offload work" guidance). https://developers.cloudflare.com/workers/platform/limits/
22. Cloudflare — Durable Objects WebSockets best practices / Hibernation API (clients stay connected while the object is out of memory; in-memory state reset; constructor re-runs; `serializeAttachment`). https://developers.cloudflare.com/durable-objects/best-practices/websockets/
23. Cloudflare — Lifecycle of a Durable Object (hibernation after ~10 s idle when hibernatable; eviction after 70–140 s inactivity; outbound connections defer eviction up to 15 min). https://developers.cloudflare.com/durable-objects/concepts/durable-object-lifecycle/
24. Cloudflare — Durable Objects Alarms (one alarm per object; at-least-once; exponential-backoff retries up to 6). https://developers.cloudflare.com/durable-objects/api/alarms/

Repository sources (read 2026-09-26, `main`)

25. `docs/decisions/0013-quick-play-sighting-hits.md` — accepted ADR: `sighting` geometry, no shared frame, `frameReady` not a gate, cap 2.
26. `docs/research/shared-arena-frame-options.md` and `.provenance.md` (2026-08-24) — error budget, `ARWorldMap`/`ARCollaborationData`/`ARParticipantAnchor`/`worldMappingStatus`/`ARTrackingState`/Nearby Interaction sources and absences reused here.
27. `docs/build-log.md` — entries 2026-09-07 … 2026-09-22 (no named-device mapping evidence; two-phone "Linking play area" stall).
28. `packages/combat-protocol/src/{index.ts,validation.ts}`, `packages/combat-simulation/src/{index.ts,flight.ts}`, `convex/functions/{combat.ts,schema.ts}`, `services/combat-worker/src/{room.ts,routes.ts,maps.ts,store.ts,serial-queue.ts}`, `scripts/release/combat-deploy.mjs`, `.github/workflows/deploy.yml`, `ios/VictoriaKillZone/VictoriaKillZone/Targeting/**` — line references in §2.

Practitioner sources consulted, not relied upon

29. **[practitioner]** Apple Developer Forums thread 130599 (wrapping `ARMeshGeometry` for SceneKit; update per `session(_:didUpdate:)`). Used only as a sanity check that mesh anchors update per-anchor, which Apple's own docs [5] already state. https://developer.apple.com/forums/thread/130599
30. **[practitioner]** Niantic Spatial ARDK `ArdkMeshingSession` docs (chunked mesh with per-chunk updated flags) — a third-party SDK's design choice, cited only as an existence proof that chunked mesh export is standard practice; not evidence about ARKit. https://nianticspatial.com/docs/nsdk/3.17.0/apiref/swift/classes/ArdkMeshingSession/
