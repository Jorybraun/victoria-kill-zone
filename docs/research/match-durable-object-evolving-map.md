# Match-scoped Durable Object for authoritative evolving map state and combat (BIO-36)

Status: Research complete — 2026-09-26. Read-only spike for [BIO-36](https://linear.app/biossphere/issue/BIO-36/spike-engineer-zero-step-ar-room-understanding-and-authoritative). Builds on — does not repeat — [shared-arena-frame-options.md](shared-arena-frame-options.md) (alignment methods, drift budget), [live-combat-deployment.md](live-combat-deployment.md) (operator deploy), [ADR 0011](../decisions/0011-quick-play-continuous-collaboration.md), and [ADR 0013](../decisions/0013-quick-play-sighting-hits.md).
Method: one repository-verification pass (every "current fact" below cites a file and line range in this checkout at commit `0750e9b`), one Cloudflare primary-documentation pass (Durable Objects limits, storage, lifecycle, WebSockets, alarms, errors, migrations, data location, metrics), one Apple primary-documentation pass (ARKit anchors, meshes, world maps, depth, Vision 3D pose), then a design synthesis. Sections labelled **Evidence** cite sources; **Inference** is design reasoning from that evidence; **Speculation** is explicitly unproven; **Absence** means no source was found. Nothing here is physical-device evidence; this document ran no devices.

## 1. The question

Two phones become ready and combat starts at once — no scan, alignment, relocalization, map-link or shared-frame ritual. Each phone keeps mapping while play runs. A match-scoped Cloudflare Durable Object (DO) is authoritative for combat. Should that DO also ingest per-phone trajectories and bounded map patches, retain per-player local maps, estimate and store inter-phone transforms, publish a confidence-scored fused room model, and snapshot/recover all of it — and if so, how, within Cloudflare's documented limits, while combat stays playable before any map convergence? What stays in Convex, what stays on the phones?

## 2. What the repository does today (verified, not assumed)

### 2.1 iOS: ARKit + Vision, plane detection present, no mesh, no wall evidence

- **Evidence.** Three `ARWorldTrackingConfiguration` sites. The baseline Quick Play session sets only `worldAlignment = .gravity` (`ios/VictoriaKillZone/VictoriaKillZone/Targeting/TargetingSession.swift:1009-1012`). `beginFrameMapping` enables `planeDetection = [.horizontal, .vertical]` and `isCollaborationEnabled` when the mode is collaborative (`TargetingSession.swift:1429-1442`); `installFrameMap` sets `initialWorldMap` plus the same plane detection (`TargetingSession.swift:1673-1681`); `MapLabARDriver.swift:136-138` does the same for the map lab. `SharedArenaSession.swift:117-120` enables collaboration without plane detection.
- **Evidence.** `sceneReconstruction` and `ARMeshAnchor` are not referenced anywhere under `ios/` (grep, this checkout). No `ARPlaneAnchor` type is referenced; the only plane use is one `ARRaycastQuery(... allowing: .existingPlaneGeometry ...)` used to check that Vision-rectangle corners lie on one plane for the measured-mode reference capture (`TargetingSession.swift:1625-1631`).
- **Evidence.** Body evidence comes from Vision 2D pose: `VNDetectHumanBodyPoseRequest` (`TargetingSession.swift:808`, `:1101-1123`), consumed into head/torso regions (`:1126+`). `VNDetectHumanBodyPose3DRequest` is not used.
- **Conclusion (confirmed).** The claim "iOS uses ARKit/Vision and already has local plane-detection paths" is true, with the caveat that plane detection is enabled only in the mapping/install/lab paths, not in the baseline Quick Play session, and no plane or mesh geometry is retained or transmitted.

### 2.2 `sighting` fire carries body evidence only

- **Evidence.** `CombatCommand` fire = `{shotId, poseSequence, origin, direction, observation?: BodyObservation | null}` (`packages/combat-protocol/src/index.ts:65`). `BodyObservation` = `{targetPlayerId, capturedAtMs, associationConfidence, uncertaintyMeters, colliders: BodyCollider[]}` with sphere/capsule colliders zoned head|torso|limbs (`index.ts:12-31`). `geometry` ∈ `trackedBody | phoneProxy | sighting` (`index.ts:47`).
- **Evidence.** iOS builds the sighting observation from the camera ray and the associated skeleton (`Features/Realtime/RealtimeArenaController.swift:377-404`); the wire encoder emits `observation` only when present (`Services/Realtime/CombatWire.swift:97,119-121`).
- **Evidence.** The simulation's sighting branch requires exactly one opponent (`ambiguousTarget`), a valid observation (`noSighting`), `associationConfidence ≥ 0.8`, `uncertaintyMeters ≤ 0.1`, `capturedAtMs` within 1 000 ms, then sweeps the fire ray against the observation's own colliders (`packages/combat-simulation/src/index.ts:279-300`, `flight.ts:139-158`, `state.ts:47-57`, `history.ts:8`).
- **Conclusion (confirmed).** No plane, mesh, raycast-hit, depth or occlusion datum is transmitted or adjudicated. Cover is implicit (no observation → no hit), as ADR 0013 states. "Sighting fire carries body evidence, not wall/surface evidence" is true.

### 2.3 Convex: lobby, prepare, tickets, projection sink

- **Evidence.** Schema tables: `matches` (with `combatMode`, `combatGeometry`, `combatFrameEpoch`, `combatAuthorityEpoch`, `combatRulesJson`, `combatProjectionSequence`, `combatProjectionDigest`, `combatPhase`), `players`, `combatShots`, `shots`, `events` (`convex/functions/schema.ts:50-199`). There is **no arena, map, patch or transform table**.
- **Evidence.** `combat.prepare` (host-only; requires `combatMode == "durableObject"`, all players connected within 15 s and ready) sets epochs to 1 and selects geometry (`sighting` only when roster ≤ 2) (`convex/functions/combat.ts:31-64`). `combat.ticket` issues a 120 s HS256 `CombatTicketClaims` carrying roster, epochs and rules and returns the worker `connect` URL (`combat.ts:67-96`). `combat.publishProjection` is the only worker→Convex write path: HMAC-verified, idempotent by `combatProjectionSequence`, writes `combatShots`, patches player state, finishes the match (`combat.ts:99-165`). The worker posts it via `POST {CONVEX_URL}/api/mutation` (`services/combat-worker/src/projection-delivery.ts:50-54`).
- **Conclusion (confirmed).** "Convex handles lobby/match preparation and projects match state" is true. Convex does not run the simulation and stores no room geometry.

### 2.4 Durable Object: `CombatRoom`, SQLite-backed, 20 Hz, epochs, hibernation

- **Evidence.** One class, `CombatRoom extends DurableObject<Env>` (`services/combat-worker/src/room.ts:28`), addressed by `env.COMBAT_ROOMS.getByName(claims.matchId)` (`src/index.ts:24`) and re-checked against `ctx.id.name` (`room.ts:83`). Declared with `migrations: [{tag: "v1", new_sqlite_classes: ["CombatRoom"]}]`, `compatibility_date` `2026-09-05`, `nodejs_compat`, head-sampled observability 0.1 (`services/combat-worker/wrangler.jsonc:5-10`). No `limits`, queues, KV or R2 bindings.
- **Evidence.** SQLite tables: `schema_migrations`, `room` (singleton checkpoint), `members`, `commands` (idempotency ledger), `events`, `shared_maps`, `map_chunks` (`src/store.ts:38-71`), `match_reports` (`src/report.ts:58`), a projection outbox (`src/projection-store.ts`). Commits run inside `transactionSync` and `await storage.sync()` before broadcast (`room.ts:404-405`; `store.ts:39`).
- **Evidence.** `LIMITS.tickMs = 50` (20 Hz), `players: 4`, `poseAgeMs: 100`, `rewindMs: 250`, `mapBytes: 8 MiB`, `ticketLifetimeSeconds: 120` (`packages/combat-protocol/src/index.ts:2-7`). Snapshot every 5 ticks; ≤16 events per message (`room.ts:23,377`). One alarm rearmed every 30 s for maintenance only — heartbeat timeouts, projection flush, 24 h idle retention (`room.ts:21-22,262-286`); the tick itself is a timer, not an alarm (`cadence.ts`).
- **Evidence.** Reconnect/recovery: tickets carry `authorityEpoch`/`frameEpoch`; mismatch → 409 on admit or `epochMismatch` + snapshot (`room.ts:134,303-305,354`). On restart the checkpoint is restored with `authorityEpoch + 1` and hibernated sockets are closed 1012 (`room.ts:57-58,73`). `resume` replays bounded history (`room.ts:453-466`); duplicate connections close 4001 (`:150`); commands are idempotent via fingerprint and per-player `clientSequence` (`:293-322`). Sockets use `ctx.acceptWebSocket(ws, [playerId])` (`:153`) with `webSocketMessage/Close/Error` handlers — the Hibernation API.
- **Evidence.** The DO already relays opaque ARKit collaboration blobs: `{type: "collab", data}` forwarded verbatim, unordered, never to sender, token-bucketed at 512 KiB (`room.ts:218-227`, `connection.ts:67-82`), plus `niToken` relay with replay to late joiners (`room.ts:230-237`). It also serves a host-uploaded frame map (`GET/PUT /v1/matches/{id}/frames/{epoch}/map`, ≤8 MiB, 128 KiB chunks, SHA-256 ETag, 15 s deadline — `src/maps.ts`).
- **Conclusion (confirmed).** "A Cloudflare Durable Object runs the real-time combat simulation" is true, and the DO already holds two map-adjacent capabilities (opaque collab relay; chunked frame-map store) that a fused-map design would extend rather than invent.

### 2.5 Deploy: CI never deploys the worker; a guarded operator script does

- **Evidence.** `.github/workflows/deploy.yml` deploys Convex and the spectator only (`:171-187`); no workflow under `.github/workflows/` references Wrangler or Cloudflare (grep). `docs/research/live-combat-deployment.md:3-5` says so explicitly.
- **Evidence.** `scripts/release/combat-deploy.mjs` requires a 40-hex candidate SHA equal to current `main` with green CI and Deploy runs on that SHA, Wrangler OAuth login with workers-write scope (API tokens rejected), exact origin shapes, an operator attestation env var, secrets by stdin or mode-0600 file, a dry-run bundle, then a `/health` check before writing evidence (`combat-deploy.mjs:26-59,93,123-130,170-176`).
- **Conclusion (confirmed).** "Normal Deploy does not deploy the combat worker; a guarded operator script does" is true.

### 2.6 Absences in the repository

- **Absence.** No code, ADR, doc or design file mentions "fused map", "map patch", "room model" or non-projectile "trajectory". No per-phone trajectory is stored server-side; poses flow to the simulation and are dropped from history under sighting (`combat-simulation/src/index.ts:158-160`).
- **Absence.** No test exercises map fusion, transform estimation or DO storage growth beyond `maps.test.ts` and `store-performance.test.ts` (`services/combat-worker/tests/`, 18 test files).
- **Absence.** No device-evidence record for ADR 0013's mandatory list exists in this checkout; ADR 0013 itself lists device evidence as outstanding.

## 3. Cloudflare Durable Object constraints (official documentation)

| Constraint | Value | Source |
|---|---|---|
| Concurrency | each object is single-threaded; ~1 000 req/s soft limit per object, overload returns an `.overloaded` error | [1], [8] |
| Object count / classes | unlimited objects; 500 classes (Paid), 100 (Free) | [1] |
| CPU per request / WebSocket message / alarm | 30 s default, raisable to 5 min via `limits.cpu_ms` | [1] |
| Memory | 128 MB per V8 isolate, shared by every object co-located in that isolate; metrics report isolate memory, not per-object | [1], [9], [10] |
| SQLite storage per object | 10 GB (Paid), 1 GB (Free); 2 MB max row/string/BLOB; KV key+value 2 MB | [1] |
| WebSocket message | 32 MiB max received; Hibernation API up to 32 768 connections per object (CPU/memory bind first) | [1], [5] |
| Storage semantics | private to the object, strongly consistent, transactional; input/output gates hold outbound messages until writes commit; a failed write discards outbound messages and restarts the object | [2], [3] |
| PITR | SQLite-backed objects can restore SQL + KV to any bookmark in the previous 30 days (`getCurrentBookmark`, `getBookmarkForTime`, `onNextSessionRestoreBookmark` + `ctx.abort()`); not available in local dev | [3] |
| Lifecycle | in-memory state lives only while resident; hibernation ~10 s idle (hibernatable sockets stay connected, memory reset); eviction ~70–140 s idle for non-hibernatable objects; shutdown on deploy/runtime update/host move; **no shutdown hook** — persist incrementally; sockets are closed on shutdown and clients must reconnect | [4] |
| Hibernation blockers | timers, in-flight awaited fetch, non-hibernatable WebSockets, unfinished events, active outbound connections | [4] |
| Per-socket state across hibernation | `serializeAttachment`/`deserializeAttachment`; tags ≤10 per socket, ≤256 chars | [5] |
| Alarms | one alarm per object; at-least-once; auto-retry on uncaught error, exponential backoff, ≤6 retries; multiple schedules must be multiplexed | [6] |
| Errors | `.retryable` → retry idempotent ops with backoff; `.overloaded` → do not retry | [8] |
| Identity / placement | `idFromName`/`getByName` deterministic; location hint best-effort and only at first creation; objects do not move after creation | [7] |
| Code updates | eventually consistent global rollout; a new Worker may call an old-version object for seconds–minutes; only one version of a given object runs at a time; API changes must be forward- and backward-compatible; lifecycle-changing versions cannot be gradually deployed or rolled back past | [11], [12] |
| Class lifecycle | declarative `exports` or legacy `migrations` (mutually exclusive); deleting a class deletes its data; renames need a three-deploy sequence | [13] |
| Intended use | stateful coordination, strong consistency, per-entity storage, persistent connections, scheduled work; multiplayer games named explicitly | [14] |

**Inference.** The repository's `CombatRoom` already sits inside these constraints (SQLite class, Hibernation API, transactional commits, epoch-based reconnect). The open question is how much *map* state can be added before the 128 MB shared-isolate memory, the 30 s per-message CPU budget, and the 20 Hz tick budget are threatened. Cloudflare publishes no per-object memory number [Absence — 1, 9], so the memory bound must be enforced by the application, not discovered from metrics.

## 4. Apple constraints on what a phone can produce (official documentation)

- `ARWorldMap` is a serialized, opaque snapshot of ARKit's mapping state (anchors, raw feature points, centre, extent); it is archived with `NSKeyedArchiver`, can be sent over a network and used as `initialWorldMap` [15]. It is a whole-map artifact, not an incremental patch.
- `ARPlaneAnchor` is produced whenever `planeDetection` is on and gives position, extent, alignment and a boundary polygon [16]. Available on every ARKit device.
- `ARMeshAnchor` and `sceneReconstruction` give a continuously refined polygon mesh with optional `ARMeshClassification` (wall, floor, ceiling, door, window, seat, table) — **LiDAR devices only**; Apple states mesh refinement is not intended to reflect in real time [17], [18], [19].
- `ARFrame.sceneDepth` requires LiDAR and the `.sceneDepth` frame semantic [20]. `ARFrame.rawFeaturePoints` (an `ARPointCloud`) is available on all devices but is intermediate debugging data, not a stable map [21].
- `VNDetectHumanBodyPose3DRequest` yields camera-relative 3D joints and can use depth when available [22]. The repository uses the 2D request only (§2.1).
- Continuous `isCollaborationEnabled` sessions emit `ARCollaborationData` that peers merge to share anchors and mapping [23] — this is what the DO already relays opaquely (§2.4). Apple documents no byte rate for it [Absence — repeated from shared-arena-frame-options.md].
- **Inference.** A "bounded map patch" that works on the supported-device matrix in [room-scanning.md](room-scanning.md) (non-LiDAR iPhone 14 through Pro models) can only be plane-derived: `ARPlaneAnchor` polygons and their updates, expressed in the phone's own world frame. Mesh/depth patches are an optional LiDAR-only enrichment.

## 5. Architecture recommendation

### 5.1 Split of responsibilities (Inference from §2–§4)

| Concern | Phone | Match DO (`CombatRoom`) | Convex |
|---|---|---|---|
| Tracking, plane detection, body observation, local drift handling | **owns** | — | — |
| Trajectory (own camera pose stream) | produces, downsamples | ingests bounded ring buffer per player; uses for combat rewind/resume and as alignment input | — |
| Map patches (plane polygons; mesh on LiDAR) | produces deltas in own frame, versioned | ingests bounded per-player patch sets; retains per-player local map; evicts by age/size | — |
| Inter-phone transform hypotheses | may propose (e.g. NI bearing, collaboration-anchor match, mutual sighting) | **owns** the accepted transform + confidence per pair, serialized with combat ticks | — |
| Fused room model | consumes published snapshot for rendering/occlusion hints | **owns**; publishes confidence-scored snapshot + deltas | — |
| Combat verdicts | asserts sighting observation | **owns**, unchanged from ADR 0013 | — |
| Lobby, readiness, prepare, tickets | UI | — | **owns** (`combat.prepare`, `combat.ticket`) |
| Durable match/scoreboard projection | — | emits outbox | **owns** (`combat.publishProjection`) |
| Saved arenas (optional high-fidelity) | captures `ARWorldMap` | existing `/frames/{epoch}/map` store | metadata only (**Absence**: no table today — would need one) |

### 5.2 Ingest contract (Inference; sizes are design proposals — Speculation until measured)

- **Trajectory:** `{playerId, seq, tMs, pose: 7 floats, trackingState}` at ≤10 Hz — the pose path already exists at 20 Hz for combat and is dropped from history under sighting (§2.2); keep a fixed ring per player (proposal: 60 s ≈ 600 samples ≈ 25 KB per player). Purpose: rewind (existing), transform estimation input, and post-match evidence.
- **Map patch:** `{playerId, patchId, frameSeq, kind: plane|mesh, anchorId, transform, polygon|meshChunk, classification?, confidence, tMs}`, one message per anchor add/update/remove, capped per message (proposal: ≤64 KiB) and per player (proposal: ≤2 MiB live set; ≤256 anchors). Keep the existing 512 KiB collab token bucket shape (`connection.ts:67-82`) as the admission model — proven pattern in this codebase. All sizes sit far under Cloudflare's 32 MiB message and 2 MB row limits [1] when chunked as `maps.ts` already does (128 KiB).
- **Transform hypothesis:** `{fromPlayer, toPlayer, T: 4×4 or 7-DoF, covariance or scalar confidence, method, evidenceIds, tMs}`. Sources: ADR 0013's named identity candidate (NI bearing), collaboration anchor correspondence (ADR 0011), mutual sighting (Option D in shared-arena-frame-options.md — Speculation there and here).
- **Never** stream `ARWorldMap` continuously: it is whole-map, opaque and up to the 8 MiB the repo already caps; keep it for the saved-arena path [15], §2.4.

### 5.3 Retention and fusion inside the DO (Inference)

- Store patches and trajectories in SQLite tables alongside the existing ones (`store.ts`), written inside the same `transactionSync` commit as the tick so input/output gates preserve the "committed before broadcast" invariant [2], `room.ts:404-405`.
- Keep an in-memory index only as a cache rebuilt from SQLite on wake — hibernation wipes memory but keeps sockets [4], [5]; the object already does this for the checkpoint (`room.ts:57-58`).
- Fusion = maintain, per pair, the best current transform with confidence ∈ [0,1] and a `fusedEpoch` counter; a fused snapshot is the union of per-player plane sets re-expressed in a nominated reference player's frame **only when** the pair confidence ≥ a threshold, else published as unaligned per-player layers. Confidence tiers (proposal): `none` (no transform), `coarse` (bearing-only, > 1 m), `aligned` (< 0.35 m — the frozen proxy-sphere radius), `saved-arena` (relocalized to a stored map).
- Heavy geometry math must not run inside the 50 ms tick; run it in the alarm-multiplexed maintenance path or, if it needs seconds, in a separate non-tick event. The 30 s CPU limit is per event [1]; fusion over ≤512 anchors is well inside it — but a single object is single-threaded [1], so any fusion CPU is stolen from combat latency. Bound it (proposal: ≤5 ms per tick slice, or fuse at ≤1 Hz).
- Eviction: drop patches older than N seconds without refresh, cap per-player set, cap total row count; ADR 0011's continuous collaboration means the phones keep re-emitting live anchors anyway.

### 5.4 Playability before convergence (Inference from ADR 0013 + §5.3)

Combat is already playable with zero shared frame under `sighting` (§2.2). The fused map therefore **never gates fire**. Its confidence tier only gates *additional* behaviours: `aligned` unlocks fused-model occlusion hints and `phoneProxy` fallback for 3–4 players; `coarse`/`none` keep pure sighting. Publish the tier in the existing snapshot so both phones can show it. Fallback policy: any transform-confidence drop returns to the lower tier immediately; hits already adjudicated are not re-opened (matches existing "client-asserted hits accepted for Phase 1" in ADR 0013).

### 5.5 Snapshot, recovery, reconnect (Evidence + Inference)

- Every accepted patch/transform/trajectory sample is durable at commit; no end-of-life flush is possible [4]. Checkpoint the fused snapshot every K ticks like the combat snapshot (`room.ts:377`).
- On restart: reload checkpoint, bump `authorityEpoch` (existing), rebuild in-memory index from SQLite, and re-publish the fused snapshot as the first message after `resume`. Add a `mapEpoch` alongside `frameEpoch`/`authorityEpoch` so a client with stale fused state resyncs deterministically rather than diffing.
- Reconnect keeps today's ticket/epoch flow (§2.4). Because sockets are Hibernation-API sockets, a short idle does not lose clients [5]; a deploy or host move does, and the client must reconnect and `resume` [4].
- PITR is an operator recovery tool (30 days, bookmarks) [3], not a runtime mechanism.

### 5.6 Migration and versioning (Evidence + Inference)

- Keep a single class; add tables via the existing `schema_migrations` table (`store.ts`) so old rows are readable by new code. Do not rename or delete `CombatRoom` [13].
- New message types (`mapPatch`, `trajectory`, `transformHypothesis`, `fusedSnapshot`, `fusedDelta`) must be additive and ignorable by older clients/objects because rollouts are eventually consistent and Worker/DO versions can mix [11], [12]. Carry a `mapProto` version string in the ticket or first message, the same way `rules.geometry` is carried today.
- The repo currently uses the legacy `migrations` array (§2.4); moving to `exports` is optional and one-way [13] — not required for this work.

### 5.7 Bounding memory, storage, CPU (Inference)

- Enforce caps in the application: rows per table, bytes per player, anchors per player, ring length; reject with a typed refusal rather than growing. Cloudflare will not tell you per-object memory [1], [9]; 128 MB is shared with co-located objects [1].
- Storage: with the proposed caps a match stays in the low tens of MB, far under 10 GB (Paid) or 1 GB (Free) [1]; still apply the existing 24 h retention delete (`room.ts:21`) to the new tables.
- CPU: keep per-message work O(patch), fusion out of the tick, and honour `.overloaded` (no retry) and `.retryable` (idempotent retry) semantics [8].

### 5.8 Observability (Evidence + Inference)

- Existing: head-sampled Workers observability at 0.1, `/health` with `projection.configured` (`wrangler.jsonc`, `combat-deploy.mjs`), GitHub-issue reports (`report.ts`), Convex projection digests. Cloudflare exposes DO request/storage/WebSocket metrics and isolate memory via GraphQL analytics [9], [10].
- Add: per-match counters (patches accepted/rejected by reason, bytes retained per player, fused tier transitions with timestamps, fusion CPU ms per pass, alarm retries), emitted in the existing report payload and in the projection so Convex can persist a per-match map-health summary. Include `mapEpoch`, tier, and transform confidence in the `match_reports` evidence so device-evidence runs (ADR 0013's list) have a server-side record.

## 6. What this document cannot know without device experiments (Absence)

- Actual `ARPlaneAnchor` update rate, polygon sizes and churn on the supported-device matrix while two players move — sets the real patch byte rate.
- Whether any transform source (NI bearing, collaboration anchors, mutual sighting) reaches the `aligned` tier (< 0.35 m) outdoors within a match; shared-arena-frame-options.md already flags this as unmeasured.
- `ARCollaborationData` byte rates (no Apple figure).
- Fusion CPU cost inside the DO under a live 20 Hz tick — only `store-performance.test.ts` and the load configs exist; none exercise geometry.
- Whether Vision 3D pose or mesh classification improves anything — neither is used today.

## 7. Recommendation summary

Extend the existing match-scoped `CombatRoom` — do not add a second DO class or move geometry to Convex. Phones own tracking and produce bounded, versioned plane patches plus a ≤10 Hz trajectory in their own frame; the DO ingests them under the existing token-bucket admission, persists them transactionally in new SQLite tables, retains a capped per-player local map, owns pairwise transform hypotheses with explicit confidence tiers, and publishes a confidence-scored fused snapshot on a `mapEpoch`. Fusion runs outside the 50 ms tick and is bounded. Combat stays exactly as ADR 0013 has it: sighting hits never wait for the map; the fused tier only unlocks extra behaviour. Convex keeps lobby/prepare/tickets/projection and gains, at most, a saved-arena metadata table. Recovery uses the existing checkpoint + epoch flow with incremental persistence (no shutdown hook exists), reconnect uses existing tickets, versioning is additive with a `mapProto` marker because Worker/DO versions can mix during rollout, and deployment stays operator-only. Every byte and CPU budget above is a proposal to be measured, not a fact.

## Sources

Cloudflare (official, accessed 2026-09-26):
1. Durable Objects — Limits. https://developers.cloudflare.com/durable-objects/platform/limits/
2. Durable Objects — Storage API (input/output gates, consistency). https://developers.cloudflare.com/durable-objects/api/storage-api/
3. Durable Objects — SQLite-backed storage API incl. PITR (`getCurrentBookmark`, `getBookmarkForTime`, `onNextSessionRestoreBookmark`). https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/
4. Durable Objects — Lifecycle (hibernation, eviction, shutdown, no shutdown hook). https://developers.cloudflare.com/durable-objects/concepts/durable-object-lifecycle/
5. Durable Objects — WebSockets and Hibernation API (`acceptWebSocket`, attachments, tags, 32 768 connections). https://developers.cloudflare.com/durable-objects/best-practices/websockets/
6. Durable Objects — Alarms (single alarm, at-least-once, retries). https://developers.cloudflare.com/durable-objects/api/alarms/
7. Durable Objects — Data location / location hints; Namespace API (`idFromName`, `getByName`). https://developers.cloudflare.com/durable-objects/reference/data-location/ ; https://developers.cloudflare.com/durable-objects/api/namespace/
8. Durable Objects — Error handling (`.retryable`, `.overloaded`). https://developers.cloudflare.com/durable-objects/best-practices/error-handling/
9. Durable Objects — Metrics and analytics (isolate memory, not per-object). https://developers.cloudflare.com/durable-objects/observability/metrics-and-analytics/
10. Workers — Limits (128 MB memory per isolate). https://developers.cloudflare.com/workers/platform/limits/
11. Durable Objects — Known issues: code updates are eventually consistent. https://developers.cloudflare.com/durable-objects/platform/known-issues/
12. Workers — Gradual deployments with Durable Objects. https://developers.cloudflare.com/workers/versions-and-deployments/gradual-deployments/with-durable-objects/
13. Durable Objects — Class exports / migrations (rename, delete, `exports` vs `migrations`). https://developers.cloudflare.com/durable-objects/reference/durable-objects-migrations/
14. Durable Objects — Rules of Durable Objects (intended use cases incl. multiplayer games). https://developers.cloudflare.com/durable-objects/best-practices/rules-of-durable-objects/

Apple (official, accessed 2026-09-26):
15. ARWorldMap. https://developer.apple.com/documentation/arkit/arworldmap
16. ARPlaneAnchor. https://developer.apple.com/documentation/arkit/arplaneanchor
17. ARMeshAnchor. https://developer.apple.com/documentation/arkit/armeshanchor
18. ARWorldTrackingConfiguration.sceneReconstruction. https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/scenereconstruction
19. ARMeshClassification. https://developer.apple.com/documentation/arkit/armeshclassification
20. ARFrame.sceneDepth. https://developer.apple.com/documentation/arkit/arframe/scenedepth
21. ARPointCloud / ARFrame.rawFeaturePoints. https://developer.apple.com/documentation/arkit/arpointcloud
22. VNDetectHumanBodyPose3DRequest. https://developer.apple.com/documentation/vision/vndetecthumanbodypose3drequest
23. ARWorldTrackingConfiguration.isCollaborationEnabled / ARCollaborationData. https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/iscollaborationenabled

Repository (this checkout, commit `0750e9b`, file:line cited inline in §2): `ios/VictoriaKillZone/**`, `packages/combat-protocol/src/index.ts`, `packages/combat-simulation/src/{index,flight,state,history}.ts`, `convex/functions/{schema,combat}.ts`, `services/combat-worker/{wrangler.jsonc,src/*.ts,tests/}`, `scripts/release/combat-deploy.mjs`, `.github/workflows/*.yml`, `docs/decisions/{0004,0008,0010,0011,0013}-*.md`, `docs/research/{room-scanning,live-combat-deployment,shared-arena-frame-options}.md`.

No practitioner sources were used in this brief.
