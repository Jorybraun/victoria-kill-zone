# Zero-step AR room understanding with authoritative combat: architecture synthesis (BIO-36)

Status: research synthesis, not a decision. Tracks [BIO-36](https://linear.app/biossphere/issue/BIO-36/spike-engineer-zero-step-ar-room-understanding-and-authoritative). Read-only: no code, branch, commit, PR, deployment, ADR or device trial was produced. Nothing in this document is physical-device evidence. Companion provenance: [zero-step-architecture-synthesis.provenance.md](zero-step-architecture-synthesis.provenance.md).

Method: seven independent BIO-36 research briefs and their provenance sidecars (§2) were read in full; every repository fact they disagree on was re-checked against `main` at `0750e9b` (2026-09-26, clean tree); platform facts were kept only where at least one brief cites an official Apple, Cloudflare or Convex page and no brief contradicts it; the result was reduced to one architecture with explicit ownership, one confidence ladder, one shot-evidence protocol, one fallback table, one release path and one physical acceptance plan.

Labels used throughout:

- **[repo]** — read directly from this repository at `0750e9b` (re-verified in this synthesis where the briefs disagreed).
- **[Apple]**, **[Cloudflare]**, **[Convex]** — official vendor documentation, cited by numbered source in §18.
- **[B1]…[B7]** — one of the input briefs (§2); used for claims this synthesis did not independently re-derive.
- **[inference]** — follows from the above but was not observed.
- **[proposal]** — a design choice made here; every number attached to a proposal is a placeholder until §15 measures it.
- **[speculation]** — plausible, unverified, and flagged as such in the source brief.
- **Absence** — something looked for and not found; stated as an absence, never converted into a claim.

## 1. Executive recommendation

1. **Keep ADR 0013 sighting as the unconditional playable floor and stop calling it a stepping stone.** Two-player combat already starts with no scan, alignment, relocalization, map-link or shared-frame ritual at the code tier [repo]. The zero-step goal is met in code and unproven on devices (absence: no completed two-phone sighting match in `docs/build-log.md`). The first thing to do is measure it (§15, rows A1–A4), not extend it.
2. **The match `CombatRoom` Durable Object should retain the evolving map — but only its authoritative, bounded, sparse form**: per-player bounded plane/surface patch sets in the sender's local frame, a bounded trajectory ring, transform hypotheses with confidence, the accepted transform per pair, a `mapEpoch`, a patch manifest (ids/hashes/versions) and the confidence tier. It should **not** retain or compute dense geometry: no mesh storage, no occupancy fusion, no ICP or bundle adjustment, no raycast index. Dense fusion and all spatial queries run on the phone that needs them (§7).
3. **Room geometry may only remove outcomes, never create them.** Body evidence is the sole positive hit primitive; a surface may pre-empt a body hit only when it is strictly closer by more than the combined uncertainty; missing, stale or low-confidence surface evidence resolves as if the surface were not there (fail-open for cover). Client confidence is a quality hint, never a trust input (§8–§9).
4. **One monotone confidence ladder for the whole system** — R0 body-only → R1 local surfaces → R2 shared provisional → R3 shared confirmed, with saved arenas as a separate opt-in mode that seeds R3 — replacing the four differently named ladders in the briefs (§7.5). Promotion is hysteretic; demotion is immediate; nothing below R3 changes a verdict rule, and no level gates start, `coverage()` or fire.
5. **Close release drift before adding surface evidence to the wire.** The protocol is strict-shape and versioned by four independent literals; iOS consumes no shared combat fixture; the promotion gate has no combat-Worker input; the Worker deploy's acceptance fields are `not-tested` [repo][B5]. Additive-optional protocol changes, Worker-first deployment order, a release manifest and an automated admission probe are prerequisites for slices 3+ (§12, §14).
6. **Every threshold in this document is a proposal.** The physical acceptance plan in §15 is mandatory before any of §7–§11 is claimed to work; a compile or simulator run does not close a row (AGENTS.md).

## 2. Inputs and how they were reconciled

| Id | Brief (uncommitted input, 2026-09-26) | Track |
|---|---|---|
| B1 | continuous-room-mapping-ios.md | Apple platform: what ARKit maps continuously; capability matrix; LiDAR gating; client gates |
| B2 | evolving-room-model-options.md | Spatial representations; alignment/fusion; drift; bandwidth; S0–S3 state machine |
| B3 | match-durable-object-evolving-map.md | Cloudflare DO constraints; DO retention/fusion split; recovery; versioning |
| B4 | zero-step-room-understanding.md | Candidate wire messages; deterministic collision ordering; freshness/degradation ladder; replay/epoch compatibility |
| B5 | zero-step-room-understanding-and-authoritative-combat.md | Release drift audit (G1–G6); release architecture; physical test matrix M1–M15 |
| B6 | client-evidence-threat-model.md | Threat matrix per evidence class; corroboration; attestation; trust tiers; privacy |
| B7 | zero-step-play-product-model.md | Product model; terminology; start/continue/degrade/refuse gating; acceptance criteria |

All seven confirm the five repository premises BIO-36 asked to verify; they disagree on nine points. Each disagreement and its resolution is in §3.1 (facts) or in the section where it matters (design), and all nine are listed in the provenance sidecar.

## 3. Repository facts (verified, with the disagreements resolved)

| Premise | Verdict | Evidence [repo] |
|---|---|---|
| iOS uses ARKit/Vision and has local plane-detection paths | **Confirmed with a qualifier that matters** | Live targeting builds `ARBodyTrackingConfiguration` (or `ARWorldTrackingConfiguration` when body tracking is unsupported) with `worldAlignment = .gravity` and **no `planeDetection`** (`ios/…/Targeting/TargetingSession.swift` L1002–1012). `planeDetection = [.horizontal, .vertical]` is set only in `beginFrameMapping` (L1431), `installFrameMap` (L1666/L1676) and `Targeting/MapLab/MapLabARDriver.swift` (L137). Under sighting, `RealtimeArenaController.configureMapIfNeeded` and `startRendezvousIfNeeded` both guard `!usesSighting`, so the duel-frame configuration is never applied. The single `arSession.raycast` call (L1627) is the reference-capture path. Absence: no `ARPlaneAnchor`, `ARMeshAnchor`, `sceneReconstruction`, `sceneDepth` consumer anywhere under `ios/`. |
| Sighting fire carries body evidence, not wall/surface evidence | **Confirmed** | `fire = {shotId, poseSequence, origin, direction, observation?}`; `BodyObservation = {targetPlayerId, capturedAtMs, associationConfidence, uncertaintyMeters, colliders}` (`packages/combat-protocol/src/index.ts` L25–31, L65). Exact-key validators reject unknown fields (`validation.ts`). iOS fills `uncertaintyMeters: 0.08` as a constant (`RealtimeArenaController.swift` L393). |
| Convex handles lobby/preparation and projects match state | **Confirmed** | `convex/functions/combat.ts`: `prepare` (host-only, all connected+ready, freezes rules, `combatPhase:"calibrating"`, epochs 1/1), `selectCombatGeometry` (sighting iff roster ≤ 2, else `phoneProxy`, L31–36), `ticket` (HS256, 120 s), `publishProjection` (HMAC, monotone `throughEventSequence`). Absence: no arena/map/transform table in `convex/functions/schema.ts`. |
| A Cloudflare Durable Object runs the real-time simulation | **Confirmed** | `services/combat-worker/src/room.ts`: `CombatRoom extends DurableObject`, 50 ms `TickCadence`, `acceptWebSocket` (hibernation API), fork → `advance` → SQLite commit → `storage.sync()` → broadcast, `authorityEpoch + 1` on restore (L58), 24 h `IDLE_RETENTION_MS` (L21). `store.ts` has `schema_migrations`, `room`, `members`, `commands`, `events`, `shared_maps`, `map_chunks`. `maps.ts`: one immutable ≤ 8 MiB map per `frameEpoch`, 128 KiB chunks. Absence: no incremental patch path, no surface state in `SimulationCheckpoint`. |
| Normal Deploy does not deploy the Worker; a guarded operator script does | **Confirmed** | `.github/workflows/deploy.yml` has no `wrangler`/`combat` reference; `scripts/release/combat-deploy.mjs` is the only Worker path (exact main SHA, green CI + Deploy evidence, OAuth `workers:write` identity, secrets via stdin/0600 file, operator attestation, `/health` check, acceptance fields written as `"not-tested"`). |

### 3.1 Factual disagreements between briefs, resolved against source

1. **"Plane detection already runs during Quick Play."** B1 (capability matrix "In app today: Yes") and B2 §2.1/§9.2 ("enabled today but discards the anchors") say yes; B4 says "enabled but unused"; B5 and B7 say it is enabled only in frame-mapping paths. **Source wins for B5/B7**: the live sighting session has no `planeDetection`. Consequence: R1 (§7.5) is a client change with unmeasured CPU/thermal cost, not a free read of existing anchors. B2's recommendation 2 ("start consuming the plane anchors the session already detects") is therefore re-scoped to "enable and consume plane detection on the live configuration, then measure".
2. **Which configuration the live session runs.** B1 §6.1 assumes `ARWorldTrackingConfiguration`; B6, B7 and source show `ARBodyTrackingConfiguration` where supported. Apple documents `planeDetection` and `initialWorldMap` on `ARBodyTrackingConfiguration` [Apple 4] and scene reconstruction / collaboration on `ARWorldTrackingConfiguration` only [Apple 5][Apple 8]. Consequence: planes are available to the live session without a configuration switch; meshes and ARKit collaboration are not (§10).
3. **Whether `ARPlaneAnchor.Classification` includes `door`/`window`.** B6 fetched the page and lists `wall/floor/ceiling/table/seat/door/window/none` [Apple 9]; B5 did not verify it. Kept as documented, with availability gated by `isClassificationSupported` and device behaviour unverified (§15 row C5).
4. **Ordering of today's `resolveFlights`.** B4 states `atMs → projectileId → distance → shield-before-body → targetId → zone`; verified at `packages/combat-simulation/src/flight.ts` L167–168. `resolveSighting` (L142–158) is a single-collider sweep with no ordering beyond nearest `u`.

Everything else the briefs report about the repository agreed across briefs and was spot-checked (limits table, thresholds `0.8` / `0.1 m` / `COVER_OBSERVATION_MS = 1_000` / `BODY_ANCHOR_METERS = 2` / `MAX_SPEED = 15`, ticket 120 s, 24 h retention, build-log entries 2026-09-17 and 2026-09-22).

## 4. Platform constraints the architecture depends on

Apple (all **[Apple]**, numbered in §18):

- World tracking is visual-inertial odometry that builds an internal world map continuously, with no user step; tracking state goes `notAvailable → limited(.initializing) → normal` and can drop to `limited` at any time; while `limited`, plane detection adds no anchors and raycasts return nothing; relocalization can remain indefinite and the app must offer a reset path [1][2][3].
- Plane detection produces refined `ARPlaneAnchor`s with alignment, extent, convex geometry and (where supported) classification; Apple states no LiDAR requirement for planes [4][6]. Scene reconstruction (`ARMeshAnchor`), `sceneDepth` and `smoothedSceneDepth` require LiDAR via runtime probes; mesh updates are refinement, "not intended" to track physical change in real time [5][7][10].
- `ARWorldMap` capture/load is discrete and blocking; reliability "strongly depends on the real-world environment" [3][11]. Collaboration requires world tracking, cannot be enabled mid-session without restarting it, and merges only on visual overlap; Apple publishes no byte rate or time-to-merge [8][12].
- Vision `VNDetectHumanBodyPoseRequest` yields joints with per-point confidence; only the client sees it [13]. App Attest authenticates an app instance and its assertions; Apple states an app cannot be trusted to check itself [14][15]. App privacy details require disclosure of data transmitted off device and retained [16].

Cloudflare (**[Cloudflare]**):

- Durable Objects are single-threaded per object; ~1,000 req/s soft limit; 30 s CPU per event by default; 128 MiB memory per isolate shared with co-located objects and no per-object memory metric; SQLite rows/values ≤ 2 MiB; ≤ 32 MiB received WebSocket message; 10 GiB (Paid) / 1 GiB (Free) per object [17][18].
- Hibernation and eviction reset in-memory state; the constructor re-runs; durable state must be committed incrementally; there is no shutdown hook; deployments restart objects [19][20][21]. Alarms are one per object, at-least-once [22].
- Rollouts are eventually consistent; a Worker and its objects can run mixed versions temporarily, so DO↔Worker changes must be forward- and backward-compatible; rollback refuses across DO class-lifecycle changes and does not touch bound resources; `wrangler versions upload` cannot carry DO migrations [23][24][25]. `secrets.required` fails deploy when a secret is missing [26].

Convex (**[Convex]**): environment variables are per deployment; `COMBAT_TICKET_SECRET` parity with the Worker is a per-deployment property no repository gate checks today [27][B5].

Absences (all briefs, all vendors): no Apple figure for plane update rate, plane count bound, mesh cadence/vertex budget, LiDAR depth range, collaboration byte rate or time-to-merge; no Cloudflare figure for geometric fusion CPU inside a DO or DO reset duration on deploy.

## 5. Architecture and ownership boundaries

```
 iPhone A ──── ticket ────► Convex (lobby, ready, prepare, rules, ticket mint, projection sink, spectator)
    │                                    ▲
    │ WebSocket (envelope v1)            │ HMAC projection (verdicts, scores; no spatial data)
    ▼                                    │
 CombatRoom DO (match-scoped) ───────────┘
    • tick/verdicts (unchanged)     • bounded patch sets + manifest   • transform hypotheses/accepted T
    • epochs + mapEpoch             • trajectory ring                  • confidence tier + policy state
    ▲
    │ WebSocket
 iPhone B
```

| Concern | iOS (`ios/**`) | Convex (`convex/**`) | `CombatRoom` DO (`services/combat-worker`, `packages/combat-*`) | Release tooling (`scripts/release`, workflows) |
|---|---|---|---|---|
| Tracking, plane detection, body observation, local drift, capability probes | **owns** | — | — | — |
| Local spatial model (planes, optional mesh/occupancy), raycast/occlusion queries | **owns**; never streams mesh | — | — | — |
| Trajectory (`pose` stream) | produces | — | ingests; retains bounded ring per player [proposal] | — |
| Surface patches | produces bounded deltas in own frame, versioned by anchor id | — | admits, validates, stores bounded per-player sets, evicts | — |
| Transform hypotheses | may propose (body sightings, NI range, collaboration merge, saved arena) | — | **owns acceptance**, confidence, `mapEpoch`, tier | — |
| Shared room model | consumes published snapshot for hints/occlusion | — | **owns the authoritative manifest + accepted surfaces**; no dense fusion | — |
| Combat verdicts | asserts observation | — | **owns** (ADR 0013 unchanged) | — |
| Lobby, readiness, prepare, tickets, trust-tier rule | UI | **owns** | enforces the rule from the ticket | — |
| Match/scoreboard projection | — | **owns** | emits | — |
| Saved arenas | captures `ARWorldMap` | metadata table (absence today) | existing `/frames/{epoch}/map` store | — |
| Release identity, fixtures, gates, Worker deploy | embeds manifest | embeds manifest | reports manifest in `/health` and snapshot | **owns** |

Write-ownership note (AGENTS.md): `convex/**` is Backend, `ios/**/Targeting/**` is iOS targeting, root configuration and shared contracts are Integration. `packages/combat-protocol`, `packages/combat-simulation`, `services/combat-worker`, `ios/**/Features/**` and `ios/**/Services/**` are not named in the ownership table; this synthesis treats the protocol and simulation packages as shared contracts (Integration) and flags Worker and iOS Features ownership as an open decision (§16) that must be declared per slice before editing.

## 6. Durable Object model

### 6.1 Should the match DO retain and reconcile the evolving map? — Yes, in bounded sparse form; no dense fusion

Arguments for retention in the DO [B3][B6][inference]: (a) the DO is the only party that can make a *rejected* patch or *demoted* transform binding on both phones; (b) wall-omission/insertion conflicts (§9) can only be resolved where both phones' observations are visible together; (c) a restart must rebuild tier and manifest from durable storage, which only the DO has; (d) dispute evidence must be tamper-evident against clients, which per-object private transactional storage gives by construction [Cloudflare 20].

Arguments against dense fusion in the DO [B2][B3][Cloudflare 17][18]: single-threaded execution steals CPU from the 50 ms tick; 128 MiB is shared across objects with no per-object metric; mesh at ~2 MiB per room per push [B2 derivation] would touch the 2 MiB row bound and dominate CPU at "constant" update rates; Apple's mesh is not real-time for physical change, so server-side mesh fusion buys nothing the phone does not already have.

**Resolution [proposal]:** the DO retains sparse patches, trajectories, hypotheses, manifest, accepted transform, tier and ledger; scores hypotheses with cheap bounded checks (plane-pair residuals, gravity consistency, agreement between two consecutive hypotheses) outside the tick; never runs ICP/bundle adjustment/mesh or occupancy fusion. B2's "manifest with a confidence, not a mesh" and B3's "DO owns transform + fused snapshot" are compatible once "fused snapshot" is defined as the union of *accepted sparse patches* re-expressed in a nominated frame only at R3.

### 6.2 State and storage [proposal; store pattern is repo]

- New SQLite tables via the existing `schema_migrations` path, written in the same `transactionSync` commit as the tick so replay and storage never disagree: `trajectory_samples(player_id, seq, captured_at_ms, pose, tracking)` ring-bounded; `surface_patches(player_id, local_epoch, patch_id, version, payload, hash, first_seen_ms, last_seen_ms, confidence)` bounded by row count and bytes per player; `transform_hypotheses(pair, method, payload, residuals, received_ms)` bounded ring; `map_state(map_epoch, tier, accepted_transform, sigma, updated_ms)` single row; `evidence_ledger(shot_id, tier, sigma, corroboration, observation_hash, surface_hash)` bounded by `commandHistory`-style caps.
- In-memory indices are caches rebuilt from SQLite on wake, as the checkpoint is today (`room.ts` L57–58) [repo][Cloudflare 19].
- Caps enforced in application code with typed refusals, never by growth: per-player patch rows, bytes, hypothesis ring, ledger rows; total per match stays in the low tens of MiB [B3 derivation], far under storage limits; existing 24 h retention deletes the new tables too.
- Checkpoint: `SimulationCheckpoint.version` bumps to 2 only when *accepted* surfaces enter the simulation (slice 4+); a v1 checkpoint restores with an empty surface set, which is the R0 rung, not a failure [B4].

### 6.3 Epochs, recovery, reconnect [repo + proposal]

- `authorityEpoch` semantics unchanged: restore bumps it, pauses, cancels projectiles, clears readiness; all tentative hypotheses are discarded (not in checkpoint). `frameEpoch` keeps meaning "the frame verdicts are expressed in"; a saved-arena map upload bumps it as today; acceptance of a fused transform bumps it the same way and emits the existing `phaseChanged`-class event [B4].
- New `mapEpoch` increments on any change to the accepted transform, tier or manifest so a client with stale shared state resyncs deterministically instead of diffing [B3]. Published in the snapshot and a ≤ 1 Hz `fusionStatus` event.
- Deploys and host moves restart the object; the 250 ms stall threshold will trip and the room will pause visibly [repo][Cloudflare 21][B5 inference]. This is expected behaviour, not a defect; the release path acknowledges it (§12).

### 6.4 Tick budget [proposal]

Per-message work O(patch); hypothesis scoring time-sliced (placeholder ≤ 5 ms per tick or ≤ 1 Hz in the alarm-multiplexed maintenance path [B3]); surface set frozen for the duration of a tick; any accepted-surface snapshot published as pages ≤ `serverMessageBytes` (128 KiB) [repo][B4]. A second DO class for fusion is rejected for now (§13) and re-opened only if measurement shows tick contention (§16).

## 7. Map and fusion model

### 7.1 Frames

Each phone owns a gravity-aligned local frame `L_p` [repo] with a `localEpoch` that increments on ARKit session reset or tracking `notAvailable` [B4]. The DO owns an optional fused frame `F` and, per pair, a transform hypothesis `T_{F←L_p}` with uncertainty. Until a hypothesis is *accepted* for both phones, every piece of evidence is used only in the frame it was captured in — which is exactly today's sighting model.

### 7.2 Representation [proposal; costs are B2 derivations]

| Representation | Where it lives | Wire? | Verdict |
|---|---|---|---|
| Sparse plane/surface patch (anchor id, alignment, classification, centre, normal, convex polygon ≤ 24 vertices, thickness, confidence, observation count, last-seen) | phone → DO → peer | **Yes**, first and only wire unit for normal play (~100 B–2 KiB) | Adopt |
| `ARPlaneAnchor` raw | phone | derived into patches | Adopt as source |
| `ARMeshAnchor` (LiDAR) | phone only | **No** (~20 KB/m²; not real-time) | Local query surface; may be collapsed to classified planar patches |
| BVH / SDF / raycast index | phone only | No | Local query layer |
| Rolling occupancy grid (10–20 cm, decaying) | phone; blocks *may* be shared later on LiDAR pairs | Later, optional | Only if a dense shared model is ever wanted |
| TSDF | — | No | Reject (duplicates ARKit's own fusion) |
| Raw feature points | phone | No | Density signal only |
| `ARWorldMap` | saved-arena path | existing 8 MiB bulk route only | Never streamed continuously |
| `ARSession.CollaborationData` | opaque relay | existing `collab` channel | Never a verdict input |

Patches are exported relative to an ARKit anchor id, not raw world coordinates, so an intra-phone drift correction is a small "anchor moved" delta rather than a re-send [B2].

### 7.3 Transform estimation — sources, cheapest first [B2][B6][speculation as to accuracy]

1. **Gravity**: both frames gravity-aligned, so the pair transform is 4-DoF (yaw + translation) from the first frame [repo].
2. **Mutual body sightings**: every accepted sighting is a ray from A through B's body while B reports its own pose; several non-parallel sightings over-determine yaw + translation at zero extra bandwidth, weighted by `uncertaintyMeters`. This is the only source that improves *by playing*.
3. **Nearby Interaction range/direction** where supported: one strong scale-free constraint per sample [repo has per-peer `NISession` code].
4. **Patch correspondences**: floor fixes roll/pitch/height immediately; wall pairs fix yaw up to a discrete ambiguity; rectangular rooms are 4-fold/2-fold ambiguous, so patch matching alone must never commit a transform (Kimera-Multi's perceptual-aliasing failure mode [B2 academic]).
5. **ARKit collaboration merge** (`ARParticipantAnchor` appears): a high-confidence observation *into* the estimator when available — only on world-tracking sessions, never a prerequisite, and only if the 2026-09-22 "Linking play area" stall is fixed [repo build-log][Apple 8].
6. **Saved arena relocalization**: strongest prior for players who opt in; `method:"savedArena"` hypothesis with the map's `frameEpoch` [repo].

Estimator shape: a single pose-graph node per pair with covariance and robust rejection, run **on the phones symmetrically**; each phone submits hypotheses; the DO accepts only when residuals are within bounds and two consecutive hypotheses agree (placeholders: `residualMeters ≤ 0.25`, `residualDegrees ≤ 5`, `inlierCount ≥ 3`, mirroring the existing `frameReady` residual fields) [B4][B2]. B1's "DO aligns patches server-side" is retained only as bounded scoring of client-proposed hypotheses (§6.1).

### 7.4 Where fusion runs

- Transform estimation: phones (symmetric); DO scores and accepts.
- Geometry fusion (transforming peer patches, occupancy updates, occlusion queries): the phone that queries it.
- DO fuses metadata only: accepted transform + σ, tier, manifest, policy state, and — at R3 — the union of accepted sparse patches published as a paged snapshot.

### 7.5 Confidence ladder (unifies B7 C0–C3, B2 S0–S3, B1 T0–T3, B3 none/coarse/aligned)

| Level | Name | Condition [proposal] | Effect on combat | Player-visible |
|---|---|---|---|---|
| **R0** | `bodyOnly` | default; always available | ADR 0013 sighting; cover = absence of body observation | nothing — this *is* normal play |
| **R1** | `localSurfaces` | shooter's phone has ≥ K mature patches with confidence ≥ c₁ and attaches surface evidence to `fire` | a surface may **void** a body hit (§8); no shared coordinates | nothing, or local cosmetic effects |
| **R2** | `sharedProvisional` | accepted transform exists but `frameConfidence` < c₂ or σ > anchor radius, or < t_stable | none on verdicts; peer position hint; corroboration runs **advisory** (logged) | nothing beyond telemetry |
| **R3** | `sharedConfirmed` | `frameConfidence` ≥ c₂ for ≥ t_stable, both phones agree within tolerance, fresh for this `localEpoch`/`mapEpoch` | either phone's accepted surfaces may void a hit via `T`; victim-pose anchoring may **veto** in competitive tier (§9) | small non-blocking indicator |
| **Arena** | `savedArena` | host-selected saved map, existing `trackedBody`/measured path | as today | explicit mode |

Placeholders inherited from the briefs, to be measured: c₁/c₂ ≈ 0.4/0.8 [B2]; 0.35 m "aligned" (frozen proxy-sphere radius, not measured) [B3]; σ < 2 m for anchoring (`BODY_ANCHOR_METERS`) [B6]. Promotion requires hysteresis; demotion is immediate on tracking `limited`/`lost`, `localEpoch` change, residual growth, patch staleness or disconnect; a demotion never re-opens an adjudicated hit and never pauses the match.

### 7.6 Retention, decay, dynamics

- Stored patch influence decays with age (placeholder: confidence × e^(−age/20 s), dropped below 0.3 or after 30 s without refresh) [B4]; a patch that is not re-observed stops counting as cover — the only graceful handling of moved furniture and doors given Apple's mesh caveat [Apple 5][B2].
- Player bodies are never room geometry: a cover query blocked by the opponent's own body is a hit, not cover [B2].
- Cover blocks a shot only if the blocking patch has confidence above threshold **and** was observed by the shooter's own phone within the freshness window; peer-only geometry never overrides the shooter's own view below R3 [B2].
- Nothing persists past match retention (24 h) unless the user saves an arena [B6 privacy].

## 8. Shot evidence protocol and deterministic collision ordering

### 8.1 Wire shape [proposal, additive-optional]

```
fire.observation?: BodyObservation                       // unchanged, still required for sighting
fire.surfaceEvidence?: {
  capturedAtMs, localEpoch, source: "plane" | "mesh" | "raycast",
  hits: [{ distanceM (0.05..100), normal: Vec3, patchRef: {patchId, version} | null,
           classification, uncertaintyMeters (0..1) }]  (0..4, nearest-first)
}
```

- Mirrors `ARSession.raycast` semantics (nearest-first, empty when none) [Apple 6]; ≤ ~700 B, so a full `fire` stays well under the 16 KiB `messageBytes` cap [repo][B4].
- Because validators are exact-key, the Worker must accept the optional key **before** any phone sends it (§12.2). Feature-gated by `rules.surfaces: "off" | "local" | "fused"` frozen at `combat:prepare` like `rules.geometry` [B4][B6].
- Body gates unchanged (age ≤ 1 s, confidence ≥ 0.8, uncertainty ≤ 0.1 m, ≥ 1 collider). Surface gate: `uncertaintyMeters ≤ 0.15`, age ≤ 250 ms (a wall does not move, but the ray is only valid at capture) [B4]; a patch whose anchor updated within the last ~1–2 s is ignored as possibly moving [B5 speculation].
- Client `poseSequence` continues to bind the shot to a stored `normal`-tracking pose within 0.5 m and ≈15° of phone forward [repo].

### 8.2 Ordering — extends today's `resolveFlights` without changing its structure [repo][B4]

Candidate tuple gains `kind ∈ {surface, shield, body}`; collect all candidates, then sort:

```
atMs → projectileId → distance → kindRank (surface 0 < shield 1 < body 2) → targetId → zone → surfaceId
```

with one rule that makes surface evidence conservative: **a surface candidate wins only if `distance_surface < distance_body − (u_surface + u_body)`**; ties within combined uncertainty fall through to shield/body, so a wall can never steal a hit it cannot prove [B4]. Shield-before-body at equal distance is preserved as the sub-case of today's comparator.

- Sighting mode: `resolveSighting` gains the same rule using only the shooter's own surface hits and own colliders in camera space — no fused frame needed (R1).
- Simulated-projectile modes (`trackedBody`, `phoneProxy`, future world-aware): surfaces come from the accepted snapshot in `F`, frozen for the tick; a projectile crossing a convex polygon ± thickness is a candidate (R3 only).
- Outcome vocabulary: new terminal reason `surfaceHit` (and optionally `surfaceOccluded` when a body hit was voided). `BulletLedger` accepts any reason that remains the last event per projectile [repo]; iOS replay already has a `default:` branch for unknown terminal reasons [repo]. **The shot is accepted and resolved, never refused, for surface reasons** — refusal reasons (`noSighting`, `ambiguousTarget`, `invalidInput`, `futureInput`) stay reserved for invalid *body* evidence. This resolves B5's "refuse `occluded`" versus B7's "fall back rather than refuse": both phones see an explicit, distinct reason, and the R0 floor is never narrowed.

### 8.3 Trajectory

Keep the existing `pose` command as the trajectory source (≤ 100 ms age, ~20 Hz); under sighting the DO currently discards pose observations — it should instead retain a bounded ring per player for hypothesis input and evidence (placeholder 60 s ≈ 600 samples ≈ 25 KB) [B3]. B4's batched `trajectory` command is an optimization, not required for slice 1–3, and is deferred (§16).

### 8.4 Patch and hypothesis commands [proposal]

`surfacePatch {localEpoch, patchId, version, op: upsert|remove(anchor gone, not geometry deletion), source, anchorId, alignment, classification, center, normal, polygon (3..24), thicknessM, capturedAtMs, confidence, prevPatchHash}` and `transformHypothesis {fromLocalEpoch, toFrame, rotation, translation, residualMeters, residualDegrees, inlierCount, method, capturedAtMs}` ride the existing `CommandEnvelope`, inheriting the 16 KiB bound, 60 cmd/s bucket, idempotency, sequence and epoch checks; they are validated, stored and acknowledged but are **not** simulation commands and do not enter `SimulationCheckpoint` until accepted [B4]. Rate placeholders (≤ 4 patches/s and ≤ 256 live patches per phone [B4]; ≤ 1 patch message/s at ≤ 50 patches [B2]; ≤ 2 MiB live set per player [B3]) disagree by design — all are budgets sized against the same repo limits, to be replaced by measurement (§15 row B2). The binding constraint is the 60 cmd/s bucket, not bytes [B4].

## 9. Authority, security, privacy — what the server knows versus what clients claim

**Server facts** (the only authenticated inputs): ticket claims and connection identity; the DO's own receive clock; sequence/idempotency fingerprints; committed simulation state and event history; (competitive tier) App Attest assertions [repo][B6].

**Client claims** (well-formed ≠ true): pose, `tracking`, `capturedAtMs`, colliders, `associationConfidence`, `uncertaintyMeters`, surface hits, patches, hypotheses, `worldMappingStatus`, feature quality. Structural validation proves shape only; the `≥ 0.8 / ≤ 0.1 m` gates filter honest noise, not adversaries [B6].

Boundaries adopted from B6 as design rules:

1. Shooter evidence may award a hit; **victim evidence may veto it**. The victim's authenticated pose stream is the only witness the shooter does not control; extend `anchoredToPhone` from shared-frame mode to sighting mode behind a σ gate — advisory in friend play, enforcing in competitive tier once σ < `BODY_ANCHOR_METERS`.
2. **Room evidence may only reduce a claimant's outcomes.** Cover blocks or voids; it never scores. Patches may add or refine geometry they observed; they may never carry deletions; unobserved space is *unknown*, never *free*; conflicts between phones resolve against the party who benefits (omission → occluded; insertion → free), which is symmetric and never penalizes honest players relative to R0.
3. **Opaque `CollaborationData` never reaches a verdict** — relay, cap, rate-limit only.
4. **Client-declared confidence is a quality hint for honest fallback, never a trust input.** Trust is earned by corroboration only.
5. **Attestation authenticates the app instance, never the observation.** App Attest at ticket mint (Convex already throttles 1/s/player) with the key id bound into ticket claims; assertions on `fire` and patch commands in competitive tier only; friend tier must work without it (simulator, unavailable devices). A1 (client rewrite) becomes expensive; A2 (sensor substitution), A4 (collusion) and A5 (physical cheating) remain — two colluding phones defeat every cross-phone check, and this synthesis proposes no remedy.
6. **Exact accounting lives in the DO**; Cloudflare's rate-limiting binding is a per-colo, eventually consistent pre-filter [Cloudflare 28]. Add per-match byte budgets and patch cadence separate from the 60 cmd/s command bucket; patch hash chain (`prevPatchHash`) against re-insertion of old patches.
7. **The ledger stores verdicts and provenance, never sensor payloads**: resolved `T` and σ at verdict time, corroboration outcome, tier, attestation key id, hashes of observation and surface evidence. Tamper-evident against clients, not against the operator — stated as acceptable. Raw frames/depth never leave the phone by default; a report pins the ledger, not sensor data.
8. **Privacy**: trajectories and room geometry are location-like data about a private space; colliders are biometric-adjacent and describe the *opponent*. Disclose collection [Apple 16]; prefer derived geometry; never persist patches past match retention unless the user saves an arena; keep the spectator projection free of camera/map/body data as today [repo].
9. **Trust tier is a match rule** chosen at `combat:prepare` and carried in the ticket; the client cannot downgrade it mid-match.

## 10. Device capability policy

| Capability | Non-LiDAR iPhone | LiDAR iPhone | Policy |
|---|---|---|---|
| VIO pose, tracking state, internal world map | yes | yes | baseline; required for R0 |
| Plane anchors + classification (where `isClassificationSupported`) | yes (on `ARBodyTrackingConfiguration` too [Apple 4]) | yes | R1 source on **every** device; enable on the live configuration behind a flag; measure cost (§15 B1) |
| Scene depth / smoothed depth | no | yes via `supportsFrameSemantics` probe [Apple 10] | additive: depth-confidence gate on LiDAR patches; never a prerequisite |
| Scene reconstruction mesh + `ARMeshClassification` (incl. `door`) | no | yes via `supportsSceneReconstruction`, world tracking only [Apple 5][7] | local query surface only; collapse classified faces to planar patches; switchable off at runtime for thermal reasons [B1 practitioner] |
| ARKit collaboration | world tracking only, not toggleable mid-session [Apple 8] | same | optional hypothesis source only when the session is already world-tracking; never required |
| Nearby Interaction | where hardware supports | same | optional hypothesis source |
| Body tracking (`ARBodyAnchor`) | where supported; Vision fallback otherwise [repo] | same | unchanged |

Rules: probe at runtime and log the result with every acceptance row (Apple publishes no consolidated device list; B1 asserts LiDAR only for the 16 Pro/17 Pro models whose support-page sections it fetched — older Pro models are not asserted). A mixed pair is the normal case: the DO must accept plane patches from one phone and plane+mesh-derived patches from the other and must never privilege the LiDAR phone as "truth" [B1][B6]. Doorways: `door`/`window` classes are documented for meshes and for plane classification [Apple 7][9] but device behaviour is unverified (§15 C5); on non-LiDAR phones a door frame may present as `wall` or `none`. Thermal/frame-rate cost of planes + body pose (+ mesh) over a 10-minute match is unmeasured and is a first-class constraint [B1][B2][B7].

## 11. Fallback policy — fail-open / fail-closed

| Situation | Behaviour | Mode | Basis |
|---|---|---|---|
| Both ready, both connected, clock synced, local camera session running | **Start.** Never wait for tracking `normal`, `worldMappingStatus`, planes, collaboration merge, relocalization, `frameReady`, or any R-level | fail-open (map) | [repo] sighting `coverage()` = all connected; [B7] |
| Ticket invalid / epoch mismatch / idempotency conflict | reject (409/401, fresh snapshot) | fail-closed | [repo] |
| `fire` with invalid/stale body evidence | `noSighting` / `ambiguousTarget` refusal | fail-closed | [repo] unchanged |
| `fire` with valid body evidence, no/stale/uncertain surface evidence | resolve body/shield only; surface ignored | fail-open (cover) | §8 |
| Surface strictly closer than body by > combined uncertainty | `surfaceHit`/`surfaceOccluded` terminal; shot accepted | conservative void | §8.2 |
| Shooter tracking `limited`/`lost` | that phone's fire refused (`pose.tracking !== "normal"`), patch emission stops, its patches decay; opponent unaffected; match not paused | fail-closed per phone | [repo] L185; [B1] G1/G2; [B7] |
| Transform residual grows / `localEpoch` changes / patch staleness | immediate demotion R3→R2→R1; `fusionStatus` event; adjudicated hits stand | fail-open (verdict rules revert to lower rung) | §7.5 |
| Victim-pose anchoring disagrees with shooter colliders | friend tier: log + "disputed" marker; competitive tier with σ < 2 m: `poseMismatch` veto | advisory / fail-closed by tier | §9 |
| Patch malformed, oversized, outside frustum history, carries deletion, breaks hash chain | reject with typed refusal; no combat effect | fail-closed (patch), no effect on play | §9 |
| Opponent disconnects | existing pause/reconnecting; resume with same epochs; no spatial re-setup | existing | [repo] |
| DO restart / deploy / host move | `authorityEpoch + 1`, pause, projectiles cancelled, tentative hypotheses dropped; tier restored from checkpoint only if fresh, else R0 | fail-safe | [repo][Cloudflare 21] |
| Unknown command kind from newer client | rejected by strict validator → server-side introduction must precede client emission | fail-closed | [repo] |
| Saved arena fails to relocalize | offer "Play Quick Duel instead"; never a dead end | fail-open | [B7] |
| Roster > 2 | not silently `phoneProxy`; explicit mode or blocked join with explanation | product rule | [B7]; ADR 0013 cap |

## 12. Release architecture

### 12.1 Drift found [repo][B5]

G1 no shared iOS↔protocol combat fixture (iOS uses inline fixtures; `contracts/fixtures` unreferenced under `ios/`/`shared/`); G2 four independent protocol-version literals (`PROTOCOL_VERSION`, `/health.protocol`, iOS `Envelope.v`, ticket `v`) that fail at runtime on phones, not in CI; G3 promotion gate has no combat-Worker input (2026-09-22 401 ticket-key mismatch is Staging-tier evidence of this class); G4 Worker deploy acceptance fields `ticketKeyParity`, `authenticatedWebSocket`, `projectionReceipt`, `physicalCalibration` stay `not-tested`; G5 no active-match guidance although deploys reset live rooms; G6 no rollback runbook, and rollback is refused across DO class-lifecycle changes. Absence: no staging Worker or Convex deployment exists.

### 12.2 Compatibility policy [proposal]

1. Protocol changes are **additive-optional first**: Worker validator accepts new optional keys/kinds → producers start sending → keys become required only after the oldest field build has expired (TestFlight builds live 90 days [Apple 29]) or a deliberate `minProtocol` bump.
2. Deployment order for protocol-affecting releases: **Worker (guarded) → Convex (Deploy) → iOS (TestFlight)**, enforced by the promotion gate.
3. Because Worker/DO versions can mix during rollout [Cloudflare 23], new message kinds (`surfacePatch`, `transformHypothesis`, `fusionStatus`, `surfaceSnapshot`) must be ignorable by older objects; carry a `mapProto` marker in the ticket or first message like `rules.geometry` today [B3].
4. DO class-lifecycle changes (rename/delete/new class, `exports` migration) are the one non-rollbackable operation: ADR + scheduled window with no active rooms + `wrangler deploy`, never `versions upload` [Cloudflare 24][25]. Extending `CombatRoom` with tables through `schema_migrations` needs none of this.
5. `SimulationCheckpoint.version` 1→2 when accepted surfaces enter; v1 restores as R0.

### 12.3 Gate extensions, no new secret, operator controls preserved [B5]

- **Release manifest** (Integration-owned root config): `releaseSha, protocolVersion, rulesSchemaHash, doClass, doMigrationTag, iosMin/MaxProtocol, convexMinProtocol, workerVersionTag`; Worker exposes it plus the `version_metadata` binding id in `/health` and the first snapshot [Cloudflare 30]; Convex records the Worker identity it last observed and the version tag on each projection; iOS embeds it and includes it plus authority-epoch history in `MatchReport` (closes the report gap).
- **CI**: `contracts/fixtures/combat.v1.json` round-tripped by protocol tests, Worker tests, Convex tests **and** an XCTest; a `verify-repo.sh` check that the four version literals equal the manifest.
- **Guarded deploy `--verify`**: automate the 2026-09-22 probe — mint a real ticket from the deployed Convex on a synthetic match, open an authenticated WebSocket, wait for `snapshot`, `leave`, confirm a `publishProjection` receipt — turning the three acceptance fields into `passed`/`failed`. Secrets stay where they are.
- **Promotion gate**: `combatWorkerVerifiedForSha` fail-closed reason key `combatNotVerifiedForSha`; operator override stays an explicit input.
- **Deploy**: after Convex deploy, call Worker `/health` and fail on protocol range mismatch; record Worker version in `release-evidence`.
- **Active-match acknowledgement** `VKZ_ACTIVE_MATCH_DISRUPTION_ACKNOWLEDGED=true` for `--deploy`; prefer `versions upload` + `versions deploy` when no migration is included.
- **Rollback runbook**: preconditions, the fact that Convex and iOS are not rolled back, re-run of the probe, `combat-worker-rollback` evidence.
- **Staging** (absence today): `vkz-combat-staging` via wrangler `env` and a Convex dev deployment fed by the same script with `--target staging` and their own secret pair.

Guards to preserve unchanged: exact-SHA + green CI/Deploy precondition, OAuth identity check with API-token inference refused, two ≥ 32-byte distinct secrets via stdin/0600 file, `secrets.required`, sanitized evidence, no automatic permission widening (the `deployment:env:view` blocker in `live-combat-deployment.md` stays unresolved by this work).

## 13. Rejected alternatives

| Alternative | Why rejected | Source |
|---|---|---|
| Any scan/align/relocalize/map-link step before Start, or `frameReady` as a gate | contradicts ADR 0013 and the product goal; 2026-09-17 and 2026-09-22 trials show the ritual fails in the target free-roaming setting | [repo] ADR 0013, build-log; B5, B7 |
| Continuous `ARWorldMap` streaming as the shared map | whole-map, opaque, blocking capture/load, up to 8 MiB, relocalization can never complete | [Apple 3][11]; B1, B2, B3 |
| ARKit collaboration as the *required* alignment channel | needs world tracking (live sighting uses body tracking), cannot be toggled mid-session, merge needs overlap, no published rate or time-to-merge, current stall unexplained | [Apple 8]; B7, B2, repo build-log |
| Raw mesh (`ARMeshAnchor`) on the wire or in the DO | ~20 KB/m², touches the 2 MiB row bound, dominates single-threaded CPU, LiDAR-only, not real-time for change | [Cloudflare 17]; [Apple 5]; B2 |
| Custom TSDF pipeline | duplicates ARKit's own fusion; battery/CPU | B2 |
| BVH/SDF or dense occupancy inside the DO | query indices belong where queries run; DO CPU is the tick's | B2, B3 |
| Dense fusion / ICP / bundle adjustment inside the DO | single-threaded, shared 128 MiB, no per-object memory metric, CPU stolen from the 50 ms tick | [Cloudflare 17][18]; B2, B3 |
| Second Durable Object class for fusion (for now) | class-lifecycle cost, cross-object consistency; not justified before measurement | [Cloudflare 24]; B3 (B7 keeps it open — §16) |
| Moving geometry to Convex | Convex has no spatial tables and is the projection sink, not the authority | [repo]; B3 |
| Surface evidence that *awards* hits, or refusing a shot because walls are missing | violates "room evidence only reduces outcomes"; would let a cheater fabricate cover or deny honest shots | B4, B6 |
| Trusting client confidence / `tracking` / `uncertaintyMeters` as security inputs | unverifiable scalars | B6 |
| Cloudflare rate-limiting binding as the accounting system | per-colo, eventually consistent, "not an accurate accounting system" | [Cloudflare 28]; B6 |
| Uploading raw camera frames or depth for disputes | turns the product into a video-collection service; privacy | B6 |
| App Attest as a truth oracle or as a friend-play requirement | authenticates the speaker, not the statement; unavailable on some devices/simulator | [Apple 14][15]; B6 |
| Writing an ADR from research alone | AGENTS.md and every brief require named-device evidence first | all briefs |

## 14. Stacked implementation slices (dependency order)

Each slice is independently shippable, leaves R0 intact, and declares its write set before editing. Slices 3+ must not start before slice 0 evidence exists; slice 5+ must not start before rows D1–D2 in §15 produce data.

| # | Slice | Depends on | Write set / owner (AGENTS.md) | Acceptance (§15) |
|---|---|---|---|---|
| 0 | **Baseline evidence**: run the current sighting build on a mixed pair; record in `docs/build-log.md` | — | Integration (docs only) | A1–A4, E1 |
| 1 | **Release drift closure**: manifest, `combat.v1` fixture consumed by iOS, version-literal check, `--verify` probe, `combatWorkerVerifiedForSha`, active-match ack, rollback runbook, staging target | — | Integration (root config, contracts, `scripts/release`, workflows); Backend for any `convex/**` touch; Worker owner to be declared (§16) | F1–F4 |
| 2 | **Product model + terminology**: request `sighting` explicitly, one start action, remove ritual copy under sighting, roster > 2 explicit, internal `calibrating` rename deferred | 1 (for any protocol/phase rename) | iOS Features/Lobby owner to be declared; Backend for `selectCombatGeometry`/copy in Convex | A1, A5–A7 |
| 3 | **Local surfaces on device (dark)**: enable `planeDetection` on the live configuration behind a flag, consume `ARPlaneAnchor`, local raycast/occlusion query, capability probes logged, telemetry only | 0 | iOS targeting (`ios/**/Targeting/**`) | B1, B3, C-rows at R0 |
| 4 | **Per-shot surface evidence (R1)**: `fire.surfaceEvidence`, `surfaceHit`/`surfaceOccluded`, `rules.surfaces`, ordering rule, `SimulationCheckpoint` v2, Worker validator first, then iOS emission | 1, 3 | Integration (protocol/simulation as shared contracts); Worker owner; iOS targeting/realtime for emission | C1–C6 |
| 5 | **Bounded retention in the DO (stored, not trusted)**: `surfacePatch` command, trajectory ring under sighting, SQLite tables + caps + admission gates + hash chain, `mapEpoch`, `fusionStatus` telemetry, ledger fields | 1, 4 | Worker owner; Integration for protocol | B2, B4, D1 telemetry |
| 6 | **Transform hypotheses and R2/R3**: `transformHypothesis`, DO acceptance with hysteresis, on-device estimator from mutual sightings (+ NI, + collaboration where world-tracking), advisory `anchoredToPhone` in sighting, paged `surfaceSnapshot`, `rules.surfaces:"fused"` | 5, and D1–D2 data | iOS targeting; Worker; Integration | D1–D4 |
| 7 | **Saved arena as R3 seed**: `method:"savedArena"` hypothesis from the existing map path; Convex arena metadata table | 6 | Backend (`convex/**`), iOS targeting | existing arena rows + D4 |
| 8 | **Competitive tier (future)**: trust-tier match rule, App Attest at ticket mint, assertions on fire/patch, enforcing anchoring, pinned ledger on report | 6 | Backend; Worker; iOS | E2–E3 |

## 15. Physical acceptance plan (mandatory before claiming success)

Rules: name device models and iOS versions; log `supportsSceneReconstruction`/`supportsFrameSemantics` results, Worker version tag, release SHA, and the sanitized diagnostic export; record in `docs/build-log.md` per its template; a Code/Simulator/Staging result never closes a Physical row; any observed contradiction of a Code-tier assumption becomes a scenario fixture under `shared/simulation/scenarios/`. Pairs: **P1** LiDAR+LiDAR, **P2** LiDAR+non-LiDAR, **P3** non-LiDAR+non-LiDAR. No target time is claimed for any row; where a brief guessed one it is marked.

**A — Zero-step baseline (current code, R0)**

| Id | Scenario | Pairs | Pass (record observed values) | Tier | Gates slice |
|---|---|---|---|---|---|
| A1 | Second `setReady` → first accepted `fire` with no scan/align UI | P1 P2 P3 | time recorded (B5 guessed < 10 s — speculation) | Physical | 0, 2 |
| A2 | Sighting hit at 3, 5, 8 m, 10 shots each, fully visible victim | all | `bodyHit` rate; `noSighting`/`ambiguousTarget` counts; the range at which 0.8 confidence fails | Physical | 0 |
| A3 | Tracking loss: cover camera 3 s / blank wall mid-match | all | that phone's fire refused; opponent unaffected; match not paused; recovery without restart; time recorded | Physical | 0 |
| A4 | Reconnect: airplane mode 5 s, then 20 s (past 15 s silence close) | all | 5 s: `resume` same epochs; 20 s: 1001 close, new ticket, pause/unpause per `coverage()`; no duplicate shots | Physical + Staging | 0 |
| A5 | No Quick Duel screen/card/a11y label contains "align", "arena scan", "share arena", "linking", "relocaliz", "calibrat" | all | copy audit on device | Physical | 2 |
| A6 | Third joiner cannot silently convert a Quick Duel into a ritual match | all | blocked or explicit mode | Physical | 2 |
| A7 | Saved arena failing relocalization offers Quick Duel | P2 | no dead end | Physical | 2, 7 |

**B — Mapping cost and yield**

| Id | Scenario | Pairs | Pass | Tier | Gates slice |
|---|---|---|---|---|---|
| B1 | 5 min in the target play area, body tracking + Vision + `planeDetection` on, no networking: `ARPlaneAnchor` add/update counts, boundary vertex counts, time-to-first-floor/wall, frame rate, thermal state; CSV attached to BIO-36 | P1 P2 P3 | data recorded; frame-rate/thermal delta vs planes-off | Physical | 3→4 |
| B2 | Patch byte rate and cmd/s against the 16 KiB / 60 cmd/s bounds during 10 min of two-phone roaming | P2 P3 | measured budget; combat command latency unaffected (Worker metrics) | Physical + Staging | 5 |
| B3 | Raycast hit accuracy at 3–15 m against a known wall | all | fraction within 0.15 m (decides whether the surface gate can ever fire) | Physical | 4 |
| B4 | LiDAR: mesh block count, update cadence, bytes per anchor in a residential room; person-segmentation coexistence with body detection | P1 | data recorded | Physical | 5 (optional path) |

**C — Cover and occlusion (R1; run first at R0 to document the gap)**

| Id | Scenario | Pairs | Pass | Tier |
|---|---|---|---|---|
| C1 | Wall-before-body: victim fully behind wall; fire at last-seen point within 1 s and after 1 s | all | R0: shots within 1 s may hit (gap documented), after → `noSighting`; R1: `surfaceHit` within 1 s | Physical |
| C2 | Body-before-wall: victim emerges; fire as skeleton appears | all | time to first acceptable observation; no false `surfaceHit` | Physical |
| C3 | Partial occlusion behind furniture (head+shoulder; limbs only) | all | zone matches visible zone; limb-only never lands `torso` | Physical |
| C4 | Moving surfaces: third person walks through; door swings shut | P1 P2 | no persistent cover after it leaves; recently updated anchors ignored | Physical |
| C5 | Doorway at 4–6 m, then frame partially occludes torso | P1 P2 P3 | hit accepted through opening; `door` never treated as wall on LiDAR; non-LiDAR classification recorded (unverified) | Physical |
| C6 | Victim stands against a wall | all | body/surface ambiguity rate with the combined-uncertainty rule | Physical |

**D — Alignment and shared model (R2/R3; data collection, no target claimed)**

| Id | Scenario | Pairs | Pass | Tier |
|---|---|---|---|---|
| D1 | 3 min honest play, both roam two rooms; offline estimate yaw+translation and σ from accepted sightings + victim poses vs number of sightings | P1 P2 P3 | σ(t) curve recorded (B6 hoped σ < 2 m within 1 min — speculation) | Physical |
| D2 | Anchoring false-positive rate: how many honest sighting hits `anchoredToPhone` at 2 m would refuse once σ is under threshold | P2 P3 | rate recorded (B6 target < 2 % — speculation) | Physical |
| D3 | No-convergence fallback: phones start in different rooms, never see common features (2026-09-17 shape) | P2 P3 | playable at R0/R1 throughout; no blocking UI; R2/R3 never claimed | Physical |
| D4 | Collaboration data size/cadence and time-to-`ARParticipantAnchor` on a world-tracking pair without side-by-side ritual; collab bytes vs 256 KB/s budget | P3 (world tracking) | data recorded; decides whether source 5 in §7.3 is usable | Physical |

**E — Security and privacy**

| Id | Scenario | Pairs | Pass | Tier |
|---|---|---|---|---|
| E1 | In-game report after C1 and A4 | all | issue created (or 503 recorded); body carries release/protocol/Worker version + epoch history; no secrets/identifiers | Physical + Staging |
| E2 | Scripted fake patches (omission, insertion, oversized, replay) against a recorded honest stream in the simulation harness | — | conflicts resolve against beneficiary; honest verdicts unchanged | Code |
| E3 | App Attest assertion latency for a `fire` on device | P2 | latency recorded; decide fire-time vs pre-issued assertion | Physical |

**F — Release**

| Id | Scenario | Pass | Tier |
|---|---|---|---|
| F1 | Deliberate `COMBAT_TICKET_SECRET` mismatch on the staging pair | 401 at admission; probe reports `ticketKeyParity: failed`; nothing else deploys | Staging |
| F2 | Guarded Worker deploy mid-match | both phones observe pause + epoch bump, resume without re-alignment; acknowledgement recorded | Physical + Staging |
| F3 | Worker rollback one version mid-lobby and mid-match | tickets still admit within compatibility range; pause/epoch bump; `combat-worker-rollback` evidence; refused across lifecycle change | Physical + Staging |
| F4 | Promotion gate with missing Worker evidence | `combatNotVerifiedForSha`, fail-closed | Code |

## 16. Open decisions

1. Write ownership for `services/combat-worker`, `packages/combat-*`, `ios/**/Features/**` and `ios/**/Services/**` — not in the AGENTS.md table; must be declared before slices 1, 4, 5.
2. One host tap versus automatic countdown once both are ready (B7).
3. Fusion inside `CombatRoom` (recommended) versus a sibling per-match object if B2/§15 measurement shows tick contention (B7 keeps it open; B3 recommends single class).
4. Whether to keep body tracking with planes enabled, switch to world tracking with Vision-only pose (unlocks mesh + collaboration), or make it device-dependent — the gating measurement for anything beyond R1 (B2 rec. 7; B1 row 3).
5. Batched `trajectory` command (B4) versus retaining the existing `pose` stream (B3) — deferred until B2 measures budget.
6. Exact patch cadence/size caps (the briefs' 4/s·2 KiB, 1/s·50×100 B and 2 MiB/player are all placeholders).
7. c₁/c₂, σ threshold, t_stable, residual bounds — placeholders until D1–D2.
8. Which features may ever depend on R3 (occlusion, cover, ricochet, surface-placed slow field) and the fallback-vs-refuse rule for each (this synthesis: fall back, never refuse).
9. 3–4 player product: explicit mode, Arena Mode only, or wait for sighting identity disambiguation (ADR 0013 deferral).
10. Internal rename of `calibrating` (touches protocol, Convex, projections).
11. Competitive tier scope and whether App Attest is ever required.
12. Whether a Convex arena/map metadata table is wanted when saved arenas become an R3 seed.

## 17. Confidence gaps (what cannot be known without devices)

- No physical-device evidence exists for ADR 0013 sighting play at all; every "zero-step already works" statement is Code-tier only.
- Plane-anchor yield, update rate, polygon sizes and thermal/frame-rate cost while body tracking + Vision run on the oldest supported iPhone — no Apple figure; B1/B2's "already detects planes" assumption was wrong at source, so no brief's derivation has even indirect device grounding.
- Whether two phones' plane sets overlap enough (especially outdoors and across rooms) to align without a ritual; rectangular-room aliasing.
- Time-to-merge, byte rate and cross-OS behaviour of `ARSession.CollaborationData` without side-by-side; the 2026-09-22 stall is unexplained beyond a working hypothesis.
- Monocular body-range error (`uncertaintyMeters` is a hard-coded 0.08 today) at 2–8 m, which bounds how fast mutual-sighting alignment converges and whether the fixed constant is honest.
- Whether raycast surface hits at 3–15 m are within 0.15 m often enough for the surface gate to fire; body/surface ambiguity against walls.
- Whether client-declared confidence correlates with anything; whether `rawFeaturePoints.count` predicts tracking loss.
- `ARPlaneAnchor.Classification` behaviour for doors/windows on non-LiDAR phones.
- Fusion/hypothesis-scoring CPU inside a DO under a live 20 Hz tick; DO reset duration on deploy.
- Every byte, rate, count, residual and confidence number in §6–§11 is a proposal sized against repository limits; none is measured. Cloudflare and Apple limits are living documents and must be re-read before any ADR freezes them.
- Collusion between two phones defeats every cross-phone check described here; no remedy is proposed.

## 18. Sources

Apple (accessed 2026-09-26 by the input briefs; URLs as cited there):

1. Managing Session Life Cycle and Tracking Quality — https://developer.apple.com/documentation/arkit/managing-session-life-cycle-and-tracking-quality
2. `ARCamera.TrackingState` — https://developer.apple.com/documentation/arkit/arcamera/trackingstate-swift.enum
3. `ARFrame.worldMappingStatus` — https://developer.apple.com/documentation/arkit/arframe/worldmappingstatus-swift.property
4. `ARBodyTrackingConfiguration` (supports `planeDetection`, `initialWorldMap`) — https://developer.apple.com/documentation/arkit/arbodytrackingconfiguration
5. `ARWorldTrackingConfiguration.sceneReconstruction` / `supportsSceneReconstruction(_:)` — https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/scenereconstruction ; https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/supportsscenereconstruction(_:)
6. `ARPlaneAnchor` / `ARPlaneGeometry` / `ARSession.raycast(_:)` / `ARRaycastQuery` — https://developer.apple.com/documentation/arkit/arplaneanchor ; https://developer.apple.com/documentation/arkit/arplanegeometry ; https://developer.apple.com/documentation/arkit/arsession/raycast(_:) ; https://developer.apple.com/documentation/arkit/arraycastquery
7. `ARMeshAnchor` / `ARMeshClassification` — https://developer.apple.com/documentation/arkit/armeshanchor ; https://developer.apple.com/documentation/arkit/armeshclassification
8. Creating a collaborative session; `ARSession.CollaborationData` — https://developer.apple.com/documentation/arkit/creating-a-collaborative-session ; https://developer.apple.com/documentation/arkit/arsession/collaborationdata
9. `ARPlaneAnchor.Classification` — https://developer.apple.com/documentation/arkit/arplaneanchor/classification-swift.enum
10. `ARFrame.sceneDepth` / `smoothedSceneDepth` / `supportsFrameSemantics` — https://developer.apple.com/documentation/arkit/arframe/scenedepth
11. `ARWorldMap` / `getCurrentWorldMap(completionHandler:)` — https://developer.apple.com/documentation/arkit/arworldmap ; https://developer.apple.com/documentation/arkit/arsession/getcurrentworldmap(completionhandler:)
12. `ARParticipantAnchor` (via source 8 and `shared-arena-frame-options.md`)
13. `VNDetectHumanBodyPoseRequest` / `VNDetectedPoint.confidence` — https://developer.apple.com/documentation/vision/vndetecthumanbodyposerequest ; https://developer.apple.com/documentation/vision/vndetectedpoint/confidence
14. Establishing your app's integrity (App Attest) — https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity
15. Validating apps that connect to your server — https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server
16. App privacy details on the App Store — https://developer.apple.com/app-store/app-privacy-details/
29. TestFlight overview (90-day builds) — https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/

Cloudflare (accessed 2026-09-26 by the input briefs):

17. Durable Objects limits — https://developers.cloudflare.com/durable-objects/platform/limits/
18. Workers limits (128 MB per isolate; CPU time) — https://developers.cloudflare.com/workers/platform/limits/
19. Durable Objects WebSockets / Hibernation — https://developers.cloudflare.com/durable-objects/best-practices/websockets/
20. Durable Object Storage API; Access Durable Objects Storage — https://developers.cloudflare.com/durable-objects/api/storage-api/ ; https://developers.cloudflare.com/durable-objects/best-practices/access-durable-objects-storage/
21. Lifecycle of a Durable Object — https://developers.cloudflare.com/durable-objects/concepts/durable-object-lifecycle/
22. Durable Objects Alarms — https://developers.cloudflare.com/durable-objects/api/alarms/
23. Gradual deployments with Durable Objects — https://developers.cloudflare.com/workers/versions-and-deployments/gradual-deployments/with-durable-objects/
24. Rollbacks — https://developers.cloudflare.com/workers/configuration/versions-and-deployments/rollbacks/
25. Versions & Deployments; Gradual deployments — https://developers.cloudflare.com/workers/configuration/versions-and-deployments/ ; https://developers.cloudflare.com/workers/configuration/versions-and-deployments/gradual-deployments/
26. Secrets (`secrets.required`, `--secrets-file`) — https://developers.cloudflare.com/workers/configuration/secrets/
28. Rate Limiting binding — https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/
30. Version metadata binding — https://developers.cloudflare.com/workers/runtime-apis/bindings/version-metadata/

Convex:

27. Environment Variables — https://docs.convex.dev/production/environment-variables

Academic / practitioner (as marked in the briefs; none relied on for a repository or platform fact):

- Slocum et al., *"That Doesn't Go There": Attacks on Shared State in Multi-User AR*, USENIX Security 2024 — https://www.usenix.org/conference/usenixsecurity24/presentation/slocum
- Tian et al., *Kimera-Multi*, IEEE T-RO 2022 — https://arxiv.org/abs/2106.14386
- Campos et al., *ORB-SLAM3*, IEEE T-RO 2021 — https://arxiv.org/abs/2007.11898
- Gambetta, *Fast-Paced Multiplayer (Part IV): Lag Compensation* — https://www.gabrielgambetta.com/lag-compensation.html (practitioner)

Repository (read at `0750e9b`): `AGENTS.md`; `docs/decisions/0010-*`, `0011-*`, `0013-quick-play-sighting-hits.md`; `docs/research/{shared-arena-frame-options,room-scanning,live-combat-deployment}.md`; `docs/build-log.md` (2026-09-17, 2026-09-22 entries); `packages/combat-protocol/src/{index,validation}.ts`; `packages/combat-simulation/src/{index,history,flight,state}.ts`; `services/combat-worker/{wrangler.jsonc,src/room.ts,src/store.ts,src/maps.ts,src/connection.ts,src/projection-delivery.ts}`; `convex/functions/{combat,matches,schema,shots}.ts`; `ios/VictoriaKillZone/VictoriaKillZone/Targeting/TargetingSession.swift`, `Targeting/MapLab/MapLabARDriver.swift`, `Features/Realtime/RealtimeArenaController.swift`, `Features/Lobby/LobbyStore.swift`; `.github/workflows/deploy.yml`; `scripts/release/{combat-deploy,deployment-gate,promotion-gate}.mjs`.

Input briefs: B1–B7 and their `.provenance.md` sidecars (uncommitted BIO-36 spike outputs dated 2026-09-26), listed in §2 and in the companion provenance file.
