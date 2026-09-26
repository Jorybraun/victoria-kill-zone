# Zero-step AR room understanding with an authoritative Durable Object

Status: research brief, not a decision. Tracks BIO-36. No code was changed and
nothing here is physical-device evidence. Companion provenance:
[zero-step-room-understanding.provenance.md](zero-step-room-understanding.provenance.md).

Method: read-only audit of the combat protocol, validation, simulation and
Durable Object (DO) worker at `main` commit `0750e9b` (2026-09-26); primary
Apple and Cloudflare documentation for the platform facts the design leans on;
derivation of candidate message shapes and policies from the audited limits.
Every claim is tagged **[repo]** (read from this repository), **[source N]**
(external, numbered in §10), **[inference]** (follows from the above but was
not observed), or **[speculation]** (plausible, unverified). Absences are
stated as absences.

## 1. Frozen product constraints

- Two-player combat starts as soon as both players are ready; no scan, align,
  relocalize, map-link or shared-frame ritual may gate start or fire.
- Each phone keeps mapping while play is active and may stream trajectory and
  bounded map evidence; the DO fuses that opportunistically.
- The match-scoped DO stays authoritative for every combat verdict.
- Play must be correct-enough before any shared-map convergence, with explicit
  confidence and fallback policy.
- Saved arenas remain an optional high-fidelity mode.

## 2. Verification of the supplied repository facts

| Supplied fact | Verdict | Evidence |
|---|---|---|
| iOS uses ARKit/Vision and already has local plane-detection paths | **Partly confirmed [repo]** | `ARWorldTrackingConfiguration`/`ARBodyTrackingConfiguration` set `planeDetection = [.horizontal, .vertical]` in `ios/.../Targeting/TargetingSession.swift` (lines ~1431, 1666, 1676) and `MapLab/MapLabARDriver.swift:137`; body pose comes from `VNDetectHumanBodyPoseRequest` (`TargetingSession.swift:808`) and `ARBodyTrackingConfiguration`. **Absence:** the `didAdd/didUpdate anchors` delegate only inspects `ARImageAnchor` (`recordDuelReferenceAnchors`); no code reads `ARPlaneAnchor`, `ARMeshAnchor`, or calls `ARSession.raycast`. Plane detection is *enabled* but its output is *unused*. |
| Sighting fire carries body evidence, not wall/surface evidence | **Confirmed [repo]** | `BodyObservation` = target id, capture time, association confidence, uncertainty, ≤32 body colliders (`packages/combat-protocol/src/index.ts`, `validation.ts`). `fire` carries `origin`, `direction`, `poseSequence`, optional single `observation`. `RealtimeArenaController.fireOnce()` fills it from the Vision skeleton with a hard-coded `uncertaintyMeters: 0.08`. No surface field exists anywhere on the wire. |
| Convex handles lobby/match preparation and projects match state | **Confirmed [repo]** | `convex/functions/combat.ts` `prepare` mutation freezes roster, requires all connected/ready, sets `combatPhase:"calibrating"`, `combatFrameEpoch:1`, `combatAuthorityEpoch:1`, `combatProjectionSequence:0`, writes rules with `selectCombatGeometry()` (sighting for ≤2 players). The DO's `ProjectionStore` posts projections back to Convex; the DO never writes combat verdicts to Convex directly. |
| A Cloudflare Durable Object runs the real-time combat simulation | **Confirmed [repo]** | `services/combat-worker/src/room.ts` `CombatRoom extends DurableObject`; 50 ms tick, `ctx.acceptWebSocket` (hibernation API), `blockConcurrencyWhile` on load, `storage.sync()` before broadcast, SQLite `RoomStore`, alarm for idle/projection. |
| Normal Deploy does not deploy the combat worker; a guarded operator script does | **Confirmed [repo]** | `.github/workflows/deploy.yml` contains no `combat`/`wrangler` step; `docs/research/live-combat-deployment.md` and `scripts/release/combat-deploy.mjs` implement the guarded Worker-only bootstrap (exact-SHA, CI evidence, operator attestation, secrets via file/stdin). |

## 3. Audit findings (what exists today) [repo]

### 3.1 Protocol and validation
- `LIMITS`: 4 players, 50 ms tick, 100 ms pose age, 250 ms rewind, 25 ms
  clock uncertainty, 16 384 B client message, 131 072 B server message,
  384 000 B collab budget / 386 000 B collab message, 60 cmd/s, 64 cmd/tick,
  512 command history, 1 024 event history, 128 projectiles, 8 MiB map,
  120 s ticket, 4 096 B NI token.
- Commands: `pose`, `frameReady`, `start`, `fire`, `reload`, `shield`,
  `slowField`, `leave`. Events include `projectileSpawn`, `projectileSegment`,
  `projectileTerminal` with `reason ∈ {bodyHit, shieldBlocked, missExpired,
  cancelled}`, `fireRefused` with `RefusalReason` (incl. `noSighting`,
  `ambiguousTarget`), `phaseChanged`.
- Every `ServerEvent` is stamped `{v:1, matchId, authorityEpoch, frameEpoch,
  eventSequence, tick, matchTimeMs}`.
- Validation is strict-shape (`validObservation`: confidence [0,1],
  uncertainty [0,10] m, 1–32 unique colliders, radius [0.005,1]).
- The `collab` client message is an opaque base64 relay with its own token
  bucket; it is **not** sequenced, not durably stored, not part of the
  simulation. It is the only existing "map-ish" live channel.
- **Absence:** no message for trajectory, surface patch, map delta, transform
  hypothesis or tracking confidence exists beyond `PhonePose.tracking ∈
  {normal, limited, lost}`.

### 3.2 Simulation
- `sighting` geometry: `coverage()` is "all players connected"; pose
  observations are discarded; `fire` must carry one observation of the single
  opponent with confidence ≥ 0.8, uncertainty ≤ 0.1 m, age ≤ ~1 s, else
  `noSighting`. `resolveSighting()` intersects the fire ray with the carried
  colliders in the *shooter's* camera frame and terminates immediately
  (`bodyHit` or `missExpired`). No rewind, no shared frame.
- Other geometries use phone/body histories, 15 m/s plausibility, 250 ms
  rewind, shared-frame colliders.
- `resolveFlights()` ordering is deterministic and mutation-free until all
  candidates are collected: `atMs`, `projectileId`, `distance`, shield before
  body, `targetId`, `zone`; one impact per projectile.
- `SimulationCheckpoint.version: 1` persists snapshot, phones, bodies.
  **Absence:** no surface state in the checkpoint.

### 3.3 Durable Object worker
- Admission by signed ticket; strict parse then serial queue; commands assigned
  to a future tick by `TickCadence.inputTick` from server arrival time; fork →
  `advance` → durable `RoomStore.commit` (checkpoint, events, command results,
  bullet ledger, projection rows) → `storage.sync()` → broadcast → ack.
- Recovery bumps `authorityEpoch`, pauses, and replays from bounded event
  history (`LIMITS.eventHistory`) or falls back to a snapshot (`replayExpired`).
- `BulletLedger` enforces per-match shot and per-projectile segment bounds and
  throws on events after a terminal — so a new terminal reason is
  ledger-compatible only if it remains the *last* event for a projectile.
- Transport budgets (`connection.ts`): 256 unacked events / 256 KiB unacked
  server bytes, 1 MiB unconfirmed collab relay, collab bucket 512 KiB burst /
  256 KiB s⁻¹, NI ≈1 s⁻¹.
- Shared maps (`maps.ts`): one immutable 8 MiB blob per `frameEpoch`, 128 KiB
  chunks, 15 s upload deadline, SHA-256 frame id. **Absence:** no incremental
  delta path.
- iOS replay (`CombatReplaySession.terminalTitle`) already has a `default:`
  branch for unknown terminal reasons — a forward-compatibility hook [repo].

## 4. Platform facts the design relies on

- ARKit reports each detected planar surface as an `ARPlaneAnchor` with
  alignment, `center`, `planeExtent`, an always-convex `ARPlaneGeometry`
  (`vertices`, `boundaryVertices`, `triangleIndices`) and optional
  classification; anchors are refined over time via `didUpdate` [1][2].
- On LiDAR devices `sceneReconstruction` yields `ARMeshAnchor`s that update
  continuously "not intended to reflect in real time", with per-face
  `ARMeshClassification` (wall, floor, ceiling, door, window, table, seat,
  none); plane detection smooths the mesh where planes are found [3][4][5].
- `ARSession.raycast(_:)` returns surface hits sorted nearest-first, empty when
  no detected surface is hit [6]. **Absence:** Apple does not publish a
  per-hit uncertainty or per-plane confidence; only `ARCamera.TrackingState`
  (`normal`/`limited(reason)`/`notAvailable`) [7] and `ARFrame.worldMappingStatus`
  [8] are exposed as quality signals.
- Vision returns body joints as `VNRecognizedPoint` with a normalized image
  position and a confidence value [9]; the repo already thresholds that at 0.8.
- Cloudflare DO (SQLite backend): 10 GB storage per object, 128 KiB per KV
  value, 32 MiB max *received* WebSocket message, 30 s CPU per invocation
  (raisable via `limits.cpu_ms`), 100 KB max SQL statement, 32 SQL function
  args [10]. One alarm per object, at-least-once with retries [11].
  Hibernation API keeps sockets attached while the object is evicted [12].
  The repo already uses `acceptWebSocket` and alarms [repo].

## 5. Design: bounded messages (candidates, not decisions)

All new commands ride the existing `CommandEnvelope`, so they inherit the
16 KiB message bound, the 60 cmd/s bucket, idempotency, sequence and
epoch checks for free [repo]. Every quantity below is a proposal
[inference] sized against those bounds; nothing has been measured on a device.

### 5.1 Coordinate frames
Each phone owns a **local frame** `L_p` (its ARKit world, gravity aligned
[repo]). The DO owns an optional **fused frame** `F`. A transform hypothesis
`T_{F←L_p}` is a candidate rigid transform with uncertainty. Until a hypothesis
for both phones is *accepted*, all evidence is used only in the frame it was
captured in — which is exactly the current sighting model.

### 5.2 `trajectory` (replaces per-tick `pose` payload growth)
```
{kind:"trajectory", frame:"local", localEpoch:int,
 samples: [{seq:int, capturedAtMs, position:Vec3, orientation:Quat,
            tracking:"normal"|"limited"|"lost", reason?: "excessiveMotion"|"insufficientFeatures"|"relocalizing"|"initializing"}] (1..8),
 positionSigmaM: number (0..2)}
```
- ≤ 8 samples, ≤ 20 Hz submit → ≤ 160 poses/s worth of data in ≤ 20
  messages/s; ≈ 1.3 KiB max [inference].
- `localEpoch` increments when the phone resets its ARKit session or
  `trackingState` passes through `notAvailable`; any prior transform
  hypothesis for that epoch is invalidated on the DO.
- Freshness: same 100 ms `poseAgeMs` gate as today for verdicts; samples
  older than 250 ms on arrival are still stored for alignment but never used
  for verdicts [inference].

### 5.3 `surfacePatch` (bounded map delta)
```
{kind:"surfacePatch", frame:"local", localEpoch:int, patchId:string,
 op:"upsert"|"remove", source:"plane"|"mesh",
 anchorId:string, alignment:"horizontal"|"vertical"|"other",
 classification:"wall"|"floor"|"ceiling"|"door"|"window"|"table"|"seat"|"none",
 center:Vec3, normal:Vec3, polygon:[Vec3] (3..24, convex, ≤ 25 m extent),
 thicknessM:number (0..0.5), capturedAtMs, confidence:number 0..1}
```
- Derived from `ARPlaneAnchor` (`center`, normal = local +y, convex
  `boundaryVertices` decimated to ≤ 24) [1][2] or from a mesh anchor's
  classified faces collapsed to a planar polygon [4][5].
- ≤ 24 vertices × 3 × 8 B ≈ 600 B numeric payload; ≤ 2 KiB JSON [inference].
- Rate: ≤ 4 patches/s per phone, ≤ 256 live patches per phone stored on the
  DO (~512 KiB JSON, ≪ 10 GB per-object limit [10]; also under the existing
  8 MiB `mapBytes` budget if reused as the cap).
- `confidence` is *client-declared*; Apple exposes no plane confidence [1]
  (absence). Proposal: derive from observation count and `trackingState`, and
  have the DO treat it as a prior only, downgraded by age (§7).
- Patches are **not** simulation commands: they are validated, stored and
  acknowledged, but do not enter `SimulationCheckpoint`. Only the *accepted*
  fused surfaces snapshot (§5.6) does.

### 5.4 `transformHypothesis`
```
{kind:"transformHypothesis", fromLocalEpoch:int, toFrame:"fused"|{peer:playerId, peerLocalEpoch:int},
 rotation:Quat, translation:Vec3, residualMeters:number, residualDegrees:number,
 inlierCount:int (0..1024), method:"planePairs"|"bodySighting"|"collab"|"savedArena",
 capturedAtMs}
```
- Emitted by either phone (client-side alignment against relayed peer patches
  via the existing `collab` channel) or computed server-side [speculation on
  which is practical; §8].
- The DO **accepts** a hypothesis only if `residualMeters ≤ 0.25`,
  `residualDegrees ≤ 5`, `inlierCount ≥ 3` and two consecutive hypotheses
  agree within those tolerances; these numbers mirror the existing
  `frameReady` residual fields [repo] and are thresholds to tune, not facts.
- Acceptance emits `frameChanged`-class event (`phaseChanged` today) and bumps
  `frameEpoch` [repo semantics preserved]; rejection is silent to peers.

### 5.5 `trackingConfidence`
Folded into `trajectory.samples[].tracking/reason` plus a sparse
```
{kind:"trackingConfidence", localEpoch:int, worldMapping:"notAvailable"|"limited"|"extending"|"mapped",
 featureQuality:number 0..1, capturedAtMs}
```
≤ 2 Hz, ≤ 256 B. `worldMapping` mirrors `ARFrame.worldMappingStatus` [8];
`featureQuality` is client-declared [inference].

### 5.6 Server events
- `surfaceSnapshot {frameEpoch, surfaces:[{surfaceId, ownerId, plane…}] (≤ 64)}`
  sent on acceptance and every N s; ≤ 64 × 2 KiB = 128 KiB, at the current
  `serverMessageBytes` ceiling [repo] — so either cap at 48 surfaces or split
  across pages [inference].
- `fusionStatus {frameEpoch, state:"unfused"|"tentative"|"fused", residualMeters, residualDegrees, ageMs}`
  ≤ 1 Hz.

### 5.7 Per-shot evidence (extends `fire`)
```
fire.observation?: BodyObservation            // unchanged
fire.surfaceEvidence?: {
  capturedAtMs, source:"raycast"|"plane"|"mesh",
  hits:[{distanceM:number (0.05..100), normal:Vec3, surfaceRef:{patchId}|null,
         classification, uncertaintyMeters:number 0..1}] (0..4)  // nearest-first
}
```
- Mirrors `ARSession.raycast` semantics (nearest-first, empty when none) [6].
- Adds ≤ ~700 B to `fire`; total stays well below 16 KiB with 32 colliders
  [inference].
- Body evidence keeps today's gates (≥0.8, ≤0.1 m, ≤~1 s). Surface evidence
  gate: `uncertaintyMeters ≤ 0.15`, age ≤ 250 ms (a wall does not move, but
  the *ray* is only valid at capture) [inference].

## 6. Deterministic collision ordering (surface, shield, body)

Extend the existing candidate tuple with `kind ∈ {surface, shield, body}` and
keep the mutation-free collect-then-sort structure of `resolveFlights()` [repo]:

```
sort by: atMs
      → projectileId (localeCompare)
      → distance
      → kindRank: surface(0) < shield(1) < body(2)
      → targetId → zone → surfaceId
```
- Rationale: at equal time/distance a wall occludes a shield which occludes a
  body — the physical stacking — and it keeps today's shield-before-body rule
  as a sub-case [inference].
- A surface candidate wins only when its `distanceM` is strictly less than the
  body hit distance minus the *sum* of both uncertainties; ties within
  uncertainty fall through to shield/body so wall evidence can never *steal* a
  hit it cannot prove [inference]. This is the key anti-frustration rule.
- Sighting mode: `resolveSighting()` gains the same rule using only the
  shooter's own surface evidence and own colliders (all camera-frame; no fused
  frame needed).
- Simulated-projectile modes: surfaces come from the accepted `surfaceSnapshot`
  in `F`; a projectile crossing a surface polygon (point-in-convex-polygon on
  the plane, ± thickness) is a candidate. Surface set is frozen for the tick.

## 7. Freshness, uncertainty and degradation

| Evidence | Fresh if | Uncertainty | If absent/stale/uncertain |
|---|---|---|---|
| Body (per shot) | age ≤ ~1 s [repo] | `uncertaintyMeters` ≤ 0.1 [repo] | `noSighting` refusal today; keep |
| Surface (per shot) | age ≤ 250 ms | ≤ 0.15 m | Ignore surface; resolve body/shield only (**never** refuse a shot for missing walls) |
| Stored patch | age ≤ 30 s or refreshed | client confidence × exp(−age/20 s) | Drop from fused set below 0.3 |
| Transform hypothesis | accepted within last 10 s and no `localEpoch` change | residual bounds §5.4 | `fusionStatus:"unfused"`; surfaces apply only in the owner's local frame |
| Tracking `limited`/`lost` | — | — | Same as today: no current pose ⇒ action refused (`actionRefusal` [repo]); patches still stored, not trusted |

Degradation ladder (highest first): **fused surfaces + body** → **own local
surfaces + body** (sighting default) → **body only** (today's behavior) →
**refuse fire** (`noSighting`). Every rung is server-side and produces an
explicit event, so the HUD can say why a wall did or did not count. Saved
arenas enter the ladder only as a `method:"savedArena"` hypothesis with
`frameEpoch` from the map upload [repo].

## 8. Replay and epoch compatibility

- New commands/events get new `kind`s under protocol `v:1` **only if** old
  clients ignore unknown kinds. iOS replay does for terminal reasons [repo];
  the TS validators are strict and reject unknown command kinds [repo], so
  server-side introduction must precede client emission (feature-gated by
  rules, e.g. `rules.surfaces:"off"|"local"|"fused"`) [inference].
- Terminal reasons add `surfaceHit` (and optionally `surfaceOccluded` when a
  body hit was voided by a wall). `BulletLedger` accepts any reason as long as
  it is the last event per projectile [repo].
- `SimulationCheckpoint.version` bumps to 2 when accepted surfaces are added;
  recovery of a v1 checkpoint loads with an empty surface set — that is the
  degradation rung "body only", not a failure [inference].
- `frameEpoch` continues to mean "the frame verdicts are expressed in";
  hypothesis acceptance bumps it exactly like a map upload does today.
  `authorityEpoch` semantics are unchanged; on recovery all tentative
  hypotheses are discarded (they are not in the checkpoint) [inference].
- Patch storage lives in a new SQLite table keyed
  `(player_id, local_epoch, patch_id)`, bounded by row count and bytes, and
  committed in the same `transactionSync` as the tick so replay and storage
  never disagree [inference; store pattern is repo].

## 9. Bandwidth and CPU envelope (derived)

Per phone, worst case from §5: trajectory ≤ 26 KiB/s, patches ≤ 8 KiB/s,
confidence ≤ 0.5 KiB/s, fire ≤ 16 KiB per shot at ≤ cooldown rate. Two phones
≈ 70 KiB/s in, well under the collab bucket alone (256 KiB/s) [repo]. The
60 cmd/s bucket is the binding constraint: 20 trajectory + 4 patch + 2
confidence + fire/shield/pose ≈ 30/s leaves headroom [inference]. Server-side
plane-pair alignment on ≤ 256 × 256 patches per tick is far below the 30 s
CPU budget [10] but must be time-sliced to protect the 50 ms cadence
[inference]. **Absence:** no measurement of ARKit plane counts, update rates,
or polygon sizes on a device exists in this repo or in Apple docs.

## 10. What cannot be known without device experiments

1. Whether two phones' plane sets overlap enough outdoors to align at all
   (the shared-arena brief already flags this).
2. Real per-plane refinement rate and polygon vertex counts (drives §5.3).
3. Whether `raycast` surface hits at 3–15 m are within 0.15 m often enough for
   the surface gate to ever fire.
4. Whether client-declared confidence correlates with anything.
5. Body/surface ambiguity when the opponent stands against a wall.

Suggested first experiment: log `ARPlaneAnchor` add/update counts, boundary
vertex counts and `raycast` results on two named devices for 5 minutes in the
target play area, no networking, and attach the CSV to BIO-36.

## 11. Recommendation

Keep ADR 0013 sighting as the floor. Add surface evidence in three gated
stages, each independently shippable and each leaving the floor intact:
(a) per-shot local surface evidence on `fire` with the ordering rule in §6 —
no map, no fusion, no new channel; (b) bounded `surfacePatch`/`trajectory`
commands stored but not yet trusted, with `fusionStatus` telemetry; (c)
transform hypotheses and fused surfaces behind `rules.surfaces:"fused"`. Do
not build (b) or (c) until the device experiment in §10 shows plane overlap.

## 12. Sources

Primary (Apple):
1. ARPlaneAnchor — https://developer.apple.com/documentation/arkit/arplaneanchor
2. ARPlaneGeometry — https://developer.apple.com/documentation/arkit/arplanegeometry
3. sceneReconstruction — https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/scenereconstruction
4. ARMeshAnchor — https://developer.apple.com/documentation/arkit/armeshanchor
5. ARMeshClassification — https://developer.apple.com/documentation/arkit/armeshclassification
6. ARSession.raycast(_:) — https://developer.apple.com/documentation/arkit/arsession/raycast(_:)
7. ARCamera.TrackingState — https://developer.apple.com/documentation/arkit/arcamera/trackingstate-swift.enum
8. ARFrame.WorldMappingStatus — https://developer.apple.com/documentation/arkit/arframe/worldmappingstatus-swift.enum (page body is a stub; enum cases not confirmed from this fetch)
9. VNRecognizedPoint — https://developer.apple.com/documentation/vision/vnrecognizedpoint

Primary (Cloudflare):
10. Durable Objects limits — https://developers.cloudflare.com/durable-objects/platform/limits/
11. Durable Objects alarms — https://developers.cloudflare.com/durable-objects/api/alarms/
12. Durable Objects WebSockets / hibernation — https://developers.cloudflare.com/durable-objects/best-practices/websockets/

Repository (read at `0750e9b`): `packages/combat-protocol/src/{index,validation}.ts`,
`packages/combat-simulation/src/{index,history,flight,state}.ts`,
`services/combat-worker/src/{room,connection,maps,store,bullet-ledger,cadence}.ts`,
`convex/functions/combat.ts`, `ios/.../Targeting/TargetingSession.swift`,
`ios/.../Features/Realtime/{RealtimeArenaController,RealtimeBodyAssociation}.swift`,
`ios/.../Features/Replay/CombatReplaySession.swift`, `.github/workflows/deploy.yml`,
`scripts/release/combat-deploy.mjs`, `docs/research/live-combat-deployment.md`,
`docs/decisions/0013-quick-play-sighting-hits.md`.

No practitioner sources were used.
