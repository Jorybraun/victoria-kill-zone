# Zero-step AR room understanding and authoritative combat: release architecture and physical test matrix (BIO-36)

Status: Research complete — 2026-09-26. Read-only spike for [BIO-36](https://linear.app/biossphere/issue/BIO-36/spike-engineer-zero-step-ar-room-understanding-and-authoritative). Builds on — does not repeat — [shared-arena-frame-options.md](shared-arena-frame-options.md) (frame alignment error budget), [live-combat-deployment.md](live-combat-deployment.md) (guarded Worker deployment), and [docs/decisions/0013-quick-play-sighting-hits.md](../decisions/0013-quick-play-sighting-hits.md) (accepted sighting geometry, no shared frame, no PLAY gate). No code, branch, PR, deployment or device trial was produced by this spike.

Method: one repository audit pass (workflows, release scripts, Worker, protocol, simulation, Convex, iOS targeting/realtime paths, build log, Outpost and testing docs), one primary-source pass (Apple ARKit/Vision/TestFlight documentation, Cloudflare Workers/Durable Objects documentation, Convex documentation), one synthesis pass. Every repository claim cites a path (and line where stable); every platform claim carries a numbered source. Sections marked **Proposal** or **Speculation** are design, not evidence. Physical-device behaviour is never claimed here: the repository contains no completed two-phone combat match on record (§4.6), and this spike ran on no device.

## 1. The question

BIO-36 asks for an architecture in which two-player combat starts the moment both players are ready — no scan, alignment, relocalization, map-linking or shared-frame ritual — while each phone keeps mapping during play, a match-scoped Cloudflare Durable Object stays authoritative for combat, trajectory and bounded map patches may be streamed and fused opportunistically into an evolving shared room model, combat stays playable before any convergence with explicit confidence and fallback policies, and saved arenas remain an optional higher-fidelity mode. Two engineering deliverables are needed before any of that is built: (a) a release architecture that keeps iOS, Convex, the shared protocol and the Durable Object Worker from drifting, without weakening secret and operator controls; and (b) a physical two-phone test matrix that says what must be observed on devices before any of the new behaviour may be claimed.

## 2. Evidence tiers used in this document

The repository already distinguishes evidence classes ([AGENTS.md](../../AGENTS.md) "A compile or simulator run is not physical-device evidence"; [docs/delivery-pipeline.md](../delivery-pipeline.md); [docs/testing-strategy.md](../testing-strategy.md) Tier 0/1/2). This brief uses four labels throughout:

| Tier | Meaning here | Produced by today |
|---|---|---|
| **Code** | A property provable by reading source or running `pnpm verify` (unit tests, fixture round-trips, replay checks, deploy self-tests) | CI `verify` job on `ubuntu-latest` ([.github/workflows/ci.yml](../../.github/workflows/ci.yml)); `scripts/ci/verify.sh` |
| **Simulator** | Xcode simulator builds/tests, two-simulator convergence matches, `SIMULATOR`-labelled latency numbers | CI `verify-ios` job on `macos-26`; Outpost Tier 1 ([docs/testing-strategy.md](../testing-strategy.md)) |
| **Staging** | Behaviour observed against deployed cloud services (Convex deployment, `vkz-combat` Worker) without phones, e.g. the synthetic admission probes recorded in the build log | Operator-run probes only; **no dedicated staging Worker or staging Convex deployment exists in the repository** (absence: `services/combat-worker/wrangler.jsonc` defines no `env` block; no workflow or script references a staging Worker name) |
| **Physical** | Named iPhone models running the app, with observed result recorded per [docs/build-log.md](../build-log.md) template | Manual trials; recorded 2026-09-17 and 2026-09-22 entries only (§4.6) |

Every row of the §8 matrix names the tier it can be closed at. Nothing in tiers Code/Simulator/Staging closes a Physical row.

## 3. Repository facts verified (not assumed)

The task listed five "current repository facts to verify". Each is confirmed below, with the nuance that matters for the design.

### 3.1 iOS uses ARKit/Vision and has local plane-detection paths — confirmed, with a boundary

- `TargetingSession.swift` owns the `ARSession`; it builds `ARBodyTrackingConfiguration` or `ARWorldTrackingConfiguration` with `worldAlignment = .gravity` for live targeting (`ios/VictoriaKillZone/VictoriaKillZone/Targeting/TargetingSession.swift` ≈L1002–1011) and runs `VNDetectHumanBodyPoseRequest` (≈L808) on frames.
- **Plane detection is enabled only in frame-mapping paths**, not in the plain targeting configuration: `planeDetection = [.horizontal, .vertical]` appears at `TargetingSession.swift` L1431 (`beginFrameMapping`), L1666/L1676 (`installFrameMap`, with `initialWorldMap`), and `Targeting/MapLab/MapLabARDriver.swift` L137. Reference-capture raycasts require `.existingPlaneGeometry` (≈L1625–1628). So "local plane-detection paths" exist, but the normal Quick Play combat session under ADR 0013 does not currently run with plane detection on. (Code evidence.)
- **No LiDAR / scene-reconstruction / depth code exists**: zero occurrences of `supportsSceneReconstruction`, `ARMeshAnchor`, `sceneReconstruction`, or `sceneDepth` under `ios/`. The 2026-09-07 build-log entry records "no LiDAR dependency in initial mapping" as a deliberate choice. (Code evidence; absence.)
- World-map capture (`getCurrentWorldMap`, `NSKeyedArchiver` up to `DuelFrameMap.maximumBytes`) and `ARSession.CollaborationData` exchange (opaque `collab` relay, 4 MiB archive cap, 192 KB chunking in `Services/Realtime/CollabChunking.swift`) exist for the ADR 0010/0011 frame paths. They are the only "map streaming" the app does today; none of it is a bounded plane/mesh patch format.

### 3.2 Sighting fire carries body evidence, not wall/surface evidence — confirmed

- `CombatCommand.fire` is `{shotId, poseSequence, origin, direction, observation?}` (`packages/combat-protocol/src/index.ts` ≈L61–69); `BodyObservation` is `{targetPlayerId, capturedAtMs, associationConfidence, uncertaintyMeters, colliders}` (≈L25–31). The exact-key validator (`src/validation.ts` `command()` ≈L45–64, `observation()` ≈L27–33) rejects any additional key, so a wall/plane field cannot be smuggled in today.
- iOS builds the observation from the associated Vision skeleton only (`Features/Realtime/RealtimeArenaController.swift` ≈L388–394, fixed `uncertaintyMeters: 0.08`) and encodes `observation` only when non-nil (`Services/Realtime/CombatWire.swift` L97, ≈L116–121).
- Authority: `CombatSimulation` refuses with `noSighting` unless `now − capturedAtMs ≤ COVER_OBSERVATION_MS` (1 000 ms, `packages/combat-simulation/src/history.ts` L8), `associationConfidence ≥ 0.8`, `uncertaintyMeters ≤ 0.1`, colliders non-empty (`src/index.ts` L288–289); `ambiguousTarget` unless exactly one opponent; `resolveSighting` (`src/flight.ts` ≈L142–158) sweeps the ray against the observation's own colliders in shooter-camera space — no shared frame, no rewind. Cover is therefore modelled purely as *absence of a body observation*, exactly as ADR 0013 states. (Code evidence.)

### 3.3 Convex handles lobby/match preparation and projects match state — confirmed

- `convex/functions/combat.ts`: `combat:prepare` (host-only, requires `combatMode === "durableObject"`, all players connected+ready, 2–4 players; freezes `combatRulesJson`, epochs 1/1); `combat:ticket` mints HS256 tickets (`iss:"vkz-lobby"`, `aud:"vkz-combat"`, 120 s TTL, roster-scoped) and returns `${COMBAT_WORKER_URL}/v1/matches/${id}/connect`; `selectCombatGeometry` keeps `sighting` only for roster ≤ 2 and downgrades to `phoneProxy` otherwise.
- `combat:publishProjection` verifies the `vkz-projection-v1` HMAC (`COMBAT_PROJECTION_SECRET`), enforces monotone `throughEventSequence`, and patches `matches`/`players`/`combatShots`. Legacy `shots.ts` paths fail with `COMBAT_AUTHORITY_REQUIRED` once `combatMode` is set (`convex/functions/shots.ts` L114, L189, L277), so `debugFire` is preserved for non-DO matches per AGENTS.md.
- The Convex schema has **no saved-map or room-model table**; maps live in the Durable Object and on-device stores. (Code evidence; absence.)

### 3.4 A Cloudflare Durable Object runs the real-time simulation — confirmed

- `services/combat-worker/wrangler.jsonc`: Worker `vkz-combat`, binding `COMBAT_ROOMS` → class `CombatRoom`, migration `v1 new_sqlite_classes`, `compatibility_date 2026-09-05`, `secrets.required = [COMBAT_TICKET_SECRET, COMBAT_PROJECTION_SECRET]`, `vars.CONVEX_URL = ""`.
- `src/room.ts`: 50 ms `TickCadence`, stall > 250 ms → authority epoch +1, pause, cancel projectiles, clear readiness; per-tick fork → `advance` → SQL commit → `storage.sync()` → broadcast; idempotent `admitCommand` with epoch and contiguous `clientSequence` checks; 15 s input silence → close 1001; 24 h idle → `deleteAll()`. Maps are stored in DO SQLite (`shared_maps`/`map_chunks`, 128 KiB chunks) at `/v1/matches/{id}/frames/{frameEpoch}/map` — not R2/KV. `/health` returns `{service:"vkz-combat", protocol:1, projection:{configured}}` (`src/index.ts` L11). (Code evidence.)

### 3.5 Normal Deploy does not deploy the Worker; a guarded operator script does — confirmed

- [.github/workflows/deploy.yml](../../.github/workflows/deploy.yml) revalidates the exact `main` SHA, deploys Convex (`CONVEX_DEPLOY_KEY`), builds and deploys the spectator to Pages, and writes sanitized `release-evidence-<sha>`. `scripts/release/deployment-gate.mjs` checks exactly those job/step names. Neither mentions `services/combat-worker`.
- `scripts/release/combat-deploy.mjs` is the **only** deploy path for the Worker: `--preflight`/`--deploy`, clean checkout at `VKZ_CANDIDATE_SHA` that must equal current `main` and have green CI *and* Deploy evidence, Cloudflare OAuth identity with `workers:write` verified (API-token inference deliberately refused), two ≥ 32-byte distinct secrets read from stdin/private file into a mode-0600 temp file passed via `--secrets-file`, `CONVEX_URL` passed as `--var`, `VKZ_CONVEX_CONFIGURATION_CONFIRMED=true` operator attestation, then a `/health` shape check and a sanitized evidence JSON whose acceptance fields are all `"not-tested"` (`ticketKeyParity`, `authenticatedWebSocket`, `projectionReceipt`, `physicalCalibration`). No automatic rollback. (Code evidence.)

## 4. Release-path audit: where drift can enter today

### 4.1 CI (`pnpm verify`, `pnpm verify:ios`)

`scripts/ci/verify.sh` runs `verify-repo.sh` (required files, `archive /` ignored, `git diff --check`, Convex module-path check, secret-pattern scan) then recursive `lint`/`typecheck`/`test`, `combat-replay/generate.mjs --check`, three release self-tests, recursive `build`. Because `pnpm-workspace.yaml` includes `services/*` and `packages/*`, **the Worker, protocol and simulation are all unit-tested on every PR** (Code tier). `verify-ios.sh` runs `check-xcode-sources.py`, `swift test` for `shared/simulation`, `CombatTransport` and the iOS package, then unsigned Debug/Release simulator builds (Simulator tier).

Drift gap G1 — **contract fixtures are not consumed by iOS.** `contracts/README.md` states iOS consumes `contracts/fixtures/*.json` "through production decoder seams", but no file under `ios/` or `shared/` references `contracts/fixtures`; `ConvexGameSessionWireTests.swift` uses inline fixtures, and `convex/tests/geofence.test.ts` is the only direct consumer found. The combat wire (`CombatWire.swift`, envelope `v = 1`) has no shared fixture at all: iOS and `packages/combat-protocol` can diverge on the `fire`/`observation` shape and CI stays green on both sides. (Code evidence; absence.)

Drift gap G2 — **no cross-target protocol version assertion.** `PROTOCOL_VERSION = 1` (`packages/combat-protocol/src/index.ts` L1), `/health.protocol: 1` (Worker), `Envelope.v = 1` (iOS) and `CombatTicketClaims.v: 1` (Convex) are four independent literals. `parseClientMessage` rejects `e.v !== 1`, so a mismatch would fail loudly *at runtime on phones*, not in CI. (Code evidence.)

### 4.2 Deploy (Convex + spectator)

Deploy is SHA-exact and evidence-producing, but it publishes Convex functions that mint tickets whose `rules`/`geometry` and claim shape the *currently deployed* Worker must accept. Nothing records which Worker version was live when a Convex revision deployed. (Code evidence; absence.)

### 4.3 TestFlight / Mac Outpost

[.github/workflows/testflight.yml](../../.github/workflows/testflight.yml) gates on `promotion-gate.mjs` (`ciNotVerifiedForSha` / `deployNotVerifiedForSha` / `staleSha`), then `promote-testflight.mjs` on the self-hosted `vkz-outpost` runner archives, uploads via App Store Connect API key (`VKZ_ASC_KEY_ID`/`VKZ_ASC_ISSUER_ID` + `.p8` under `~/.appstoreconnect/private_keys/`), reconciles SHA/version/build, and writes `testflight-evidence` with `physicalDeviceEvidence: "not-claimed"`. Apple's TestFlight documentation confirms builds are testable for 90 days and internal testers are limited to 100 App Store Connect users [12].

Drift gap G3 — **a TestFlight build can ship against a Worker it has never been tested with.** The promotion gate has no combat-worker input; a build compiled from SHA *S* may reach testers while the Worker is still at an older SHA (build log 2026-09-22: Worker versions 3–5 uploaded on 09-17 while Convex had moved, producing 401 ticket-key mismatch — Staging-tier evidence of exactly this class).

### 4.4 Guarded combat-worker deployment

Strengths to preserve: exact-SHA + green-CI + green-Deploy precondition; operator attestation; two independent secrets never on the command line; OAuth identity verification; sanitized evidence; `secrets.required` in `wrangler.jsonc`, which Cloudflare documents as making `wrangler deploy`/`versions upload` fail when a required secret is not configured [8].

Drift gap G4 — **the deployment's acceptance fields stay `not-tested`.** `/health` proves shape and `projection.configured`, not ticket-key parity, authenticated admission, or projection receipt ([live-combat-deployment.md](live-combat-deployment.md) says so explicitly). The 2026-09-22 401 probe shows parity failures are real.

Drift gap G5 — **deploying the Worker resets every live `CombatRoom`.** Cloudflare: "There are normal operations like code deployments that trigger Durable Objects to restart and lose their in-memory state" [9]. The room's `restore` path handles this by incrementing the authority epoch and pausing gameplay (`packages/combat-simulation/src/index.ts` `restore`), so a mid-match deploy is *safe* but *visible* (pause, projectiles cancelled). No operator guidance about active matches exists in `combat-deploy.mjs`. (Code + primary-doc evidence; absence of guidance.)

Drift gap G6 — **rollback is manual and bounded.** Cloudflare `wrangler rollback` creates a new deployment from a prior version but refuses if a Durable Object class lifecycle change occurred between the versions, and "resources connected to your Worker will not be changed during a rollback" [6]. Versions uploaded with `wrangler versions upload` cannot carry DO migrations [7]. No rollback runbook exists in the repo. (Primary-doc evidence; absence.)

### 4.5 Ticket and report paths

- Ticket: Convex mints → phone presents `Authorization: Bearer` → Worker `verifyBearerTicket` (HS256, `alg`/`typ` exact, secret ≥ 32 bytes) → `validateTicketClaims` (`iss`/`aud`, `exp − iat ≤ 120`, exactly one host) → `matchId` must equal route. Client-side failure classes are surfaced as 401/403/409/410 (build log 2026-09-22).
- Report: `ReportProblemView` → `MatchReportClient` POST `…/report` `{device, transcript, log}` → Worker `MatchReportHandler` → GitHub issue via `GITHUB_ISSUES_TOKEN` (optional; absent → 503), quota 12/match, 4/player, 30 s interval in DO SQLite; untrusted transcript fenced. A maintainer applies the `devin-report` label to trigger [.github/workflows/devin-report.yml](../../.github/workflows/devin-report.yml), which treats issue text as untrusted input. The report body carries `DuelFrameDiagnosticEvent`s from the frame provider and Nearby rendezvous — **no Worker version, protocol version, or authority-epoch history is included**, so a report cannot today say which Worker/protocol pair the phone was talking to. (Code evidence; absence.)

### 4.6 Secrets and evidence logs

Secret names in use (names only): CI/Deploy `CONVEX_DEPLOY_KEY`, `DEVIN_API_KEY`, `GITHUB_TOKEN`; Outpost `VKZ_ASC_KEY_ID`, `VKZ_ASC_ISSUER_ID`, `VKZ_SLACK_WEBHOOK_URL`; Worker `COMBAT_TICKET_SECRET`, `COMBAT_PROJECTION_SECRET`, `GITHUB_ISSUES_TOKEN`, var `CONVEX_URL`; Convex `COMBAT_TICKET_SECRET`, `COMBAT_PROJECTION_SECRET`, `COMBAT_WORKER_URL`; operator `CLOUDFLARE_ACCOUNT_ID`. No `.env*` files are committed. `redact.mjs` sanitizes all evidence text. The known open blocker in [live-combat-deployment.md](live-combat-deployment.md) (a deployment key lacking `deployment:env:view`) must not be resolved by widening permissions automatically.

Evidence on record ([docs/build-log.md](../build-log.md)): 2026-09-17 physical observation (iPhone 14 + iPhone 16, iOS versions not recorded) — joiner in a different room could not relocalize to the host's one-shot map; 2026-09-22 Staging probe — 401 ticket-key mismatch, then after the secret fix a two-phone run that upgraded to 101 but stalled at "Linking play area" on collab payload drops. **No completed two-phone combat match, and no ADR 0013 sighting trial, is recorded anywhere.** ADR 0013 itself states it contains no physical-device evidence. (Absence.)

## 5. Platform facts from primary documentation

Apple (ARKit/Vision):

- Plane detection produces `ARPlaneAnchor`s with alignment, geometry, extent and optional classification (wall/floor/etc. via `ARPlaneAnchor.Classification`, availability gated by `isClassificationSupported`) on world-tracking sessions [1]. Apple does not state a LiDAR requirement for plane detection; it does state one for scene reconstruction [2]. Inference: plane-level wall evidence is available on both LiDAR and non-LiDAR phones; mesh-level evidence only on LiDAR phones.
- `sceneReconstruction` produces `ARMeshAnchor`s and plane detection "can improve and smooth the mesh"; `supportsSceneReconstruction` "requires a device with a LiDAR Scanner" [2][3]. `ARMeshAnchor` updates reflect refinement, "not intended" for real-time change tracking [3]. `ARMeshClassification` includes `wall`, `floor`, `ceiling`, `door`, `window`, `seat`, `table`, `none` [4] — i.e. doorways are a first-class mesh class on LiDAR devices only.
- `sceneDepth` requires the `sceneDepth` frame semantic and is populated from the LiDAR scanner [5].
- `ARRaycastQuery` intersects planes or meshes (`.estimatedPlane`) and is the documented way to find surface positions [1a].
- Tracking: sessions start `notAvailable` → `limited(.initializing)` → `normal`; while `limited`, "plane detection does not add or update plane anchors" and hit-testing returns nothing; `insufficientFeatures`/`excessiveMotion`/`relocalizing` are the documented causes; relocalization can remain `relocalizing` indefinitely and the app must offer `resetTracking` [10]. This is the primary-source basis for the tracking-loss and doorway rows in §8.
- `ARWorldMap` / `getCurrentWorldMap` is the sanctioned shared-frame and persistence mechanism; Apple advises checking `worldMappingStatus` before saving and warns reliability "strongly depends on the real-world environment" [11][10]. This is what saved arenas already use (§3.1).
- `VNDetectHumanBodyPoseRequest` yields `VNHumanBodyPoseObservation` joints with per-point confidence [13] — the existing body evidence path.

Cloudflare (Workers / Durable Objects):

- Deployments restart Durable Objects and clear in-memory state; durable state must go through the Storage API [9]. SQLite-backed objects are recommended, have 10 GB per object, 2 MB per row/value, 100 KB max SQL statement, 32 MiB max received WebSocket message, ~1 000 req/s soft limit per object, single-threaded [14].
- Versions vs deployments: `wrangler deploy` uploads and immediately serves; `wrangler versions upload` + `versions deploy` separate them; versions uploaded that way cannot include DO migrations/class-lifecycle changes [7]. Version ID/tag/timestamp are readable in-Worker via the `version_metadata` binding [15].
- Gradual deployments with Durable Objects: only one version of a given object runs at a time; each object is assigned a version for the deployment and is reset once when reassigned; Cloudflare says DO↔Worker API changes should be forwards- and backwards-compatible regardless [16].
- Rollback: creates a new deployment from a prior version (last 100), does not touch bound resources, refused across DO class-lifecycle changes [6].
- Secrets: `secrets.required` fails deploy when a listed secret is absent; `--secrets-file` accepts JSON/dotenv up to 100 secrets; `wrangler secret put` itself creates and deploys a new version [8].
- WebSocket hibernation keeps clients connected while the object is evicted and re-runs the constructor on wake [17]. The repo's room uses a 50 ms tick loop, so hibernation is largely moot during play; it matters for idle rooms and reconnect.

Convex: environment variables are per-deployment and may be declared in `convex.config.ts` for deploy-time validation; they are set via dashboard or `npx convex env …` [18]. Relevant because `COMBAT_TICKET_SECRET` parity is a per-deployment property that no repository gate checks (G4).

## 6. Proposal — zero-step room understanding without a shared-frame ritual

Everything in this section is **Proposal** (design derived from §3–§5), not evidence. Its purpose is to make the release architecture (§7) and test matrix (§8) concrete.

### 6.1 Principle: body evidence stays the hit primitive; surface evidence only *refuses* hits

ADR 0013's sighting geometry already achieves "combat starts immediately": no `frameReady`, no map, no alignment. The zero-step goal is therefore met for two players today at Code tier, pending Physical evidence. Room understanding should be layered *on top* as a cover model that can only make the game *more* conservative (refuse a hit the body evidence alone would allow), never less. This keeps the authority's trust boundary identical: the shooter still cannot fabricate a hit it did not observe.

### 6.2 Confidence tiers and fallback policy

| Tier | Inputs available to the room | Hit rule | Cover rule | Entry / exit |
|---|---|---|---|---|
| **C0 — sighting only** (today) | body observation | ADR 0013 (`≤1 s`, `≥0.8`, `≤0.1 m`) | absence of body | default at `start`; never blocks play |
| **C1 — local-surface-informed** | C0 + shooter's own `ARPlaneAnchor` (all phones) or `ARMeshAnchor` (LiDAR) evidence in *shooter-camera space* | as C0 | fire refused (`occluded`) if a shooter-local surface with classification `wall`/`door`/`none` intersects the ray *before* the observed body at ≥ configured confidence | per-shot: present iff shooter attached a surface patch to the `fire` command; no negotiation |
| **C2 — fused shared room** | C1 + opportunistically aligned patches from both phones with an alignment residual under budget | as C0 | cover from *either* phone's surfaces, transformed via the room's current alignment | room-side; degrades to C1 immediately when residual or freshness fails |
| **C3 — saved arena** | `initialWorldMap` relocalization, `trackedBody`/measured mode | existing | existing | optional mode selected in lobby; never required |

Fallback is monotone: any missing/stale/uncertain input drops the *cover* tier for that shot to the next lower tier; the hit primitive never changes. This is the "explicit confidence and fallback" BIO-36 asks for and mirrors the existing freshness/confidence gates.

### 6.3 Data the phones would stream (bounded)

- **Trajectory**: already streamed as `pose` commands (100 ms max age, 50 ms tick).
- **Surface patch in `fire`** (C1): an optional `surfaces` array on `fire` — a small set of shooter-camera-space planar quads or triangle patches (bounded, e.g. ≤ 8 patches / ≤ 2 KiB, inside the existing 16 KiB non-collab message cap) with `classification`, `confidence`, `capturedAtMs`. Additive optional key → protocol version stays 1 only if the validator learns the key on the Worker *before* any phone sends it (§7.2 ordering).
- **Room patches** (C2): periodic, opportunistic `patch` client messages carrying planes/mesh chunks in the *sender's* local frame plus that frame's `frameEpoch`/authority epoch; bounded by the existing collab budget (256 KB/s encoded, 386 KB message cap). Fusion happens in the room (SQLite ledger keyed by sender + patch id) using the alignment estimate that the existing collaboration/NI rendezvous path already produces when it succeeds. **Speculation**: whether ARKit collaboration data or the room's own plane matching converges faster indoors is unknown; no Apple source publishes convergence times (§9).
- Saved arenas keep using the `/frames/{epoch}/map` route unchanged.

### 6.4 What this does *not* solve (stated as limits)

- 3–4 players remain on `phoneProxy` (ADR 0013 cap); C1/C2 as designed only refine two-player sighting.
- LiDAR asymmetry: a non-LiDAR shooter contributes plane patches only; doors are then indistinguishable from walls unless `ARPlaneAnchor.classification` reports them (Apple documents a `door` class for meshes [4]; plane classification values are listed under `ARPlaneAnchor.Classification` [1] — the spike did not verify a `door` plane class, so treat doorways on non-LiDAR phones as **unverified**).
- Moving surfaces: Apple says mesh updates are refinement, not real-time change tracking [3]; a person-sized moving object should therefore not be trusted as cover — C1 must ignore surfaces whose anchor was updated within a short window (**Speculation**: ~1–2 s) and matrix row M7 tests exactly this.

## 7. Proposal — release architecture that prevents drift and preserves controls

### 7.1 One release identity across four targets

Introduce a committed **release manifest** (Integration-owned, root configuration) that every target embeds and reports:

```
releaseSha, protocolVersion, rulesSchemaHash, doClass="CombatRoom", doMigrationTag="v1",
iosMinProtocol/iosMaxProtocol, convexMinProtocol, workerVersionTag (filled by combat-deploy)
```

- Worker: expose `releaseSha`, `protocolVersion`, and the Cloudflare `version_metadata` id/tag [15] in `/health` and in the first `snapshot` server message. Cost: one binding in `wrangler.jsonc`, no secret.
- Convex: `combat:ticket` records the Worker `/health` identity it last observed (operator-confirmed, or probed by a scheduled action) in `matches`; `publishProjection` stores the Worker version tag that produced the projection.
- iOS: embeds `releaseSha` and protocol range in the build (`Info.plist`), sends them in `resume`/hello, and includes them plus authority-epoch history in `MatchReport` (closes the §4.5 gap).
- Spectator: displays the projection's Worker version tag.

### 7.2 Compatibility policy and deployment order

Cloudflare's own guidance is that DO↔Worker changes be forwards/backwards compatible [16]; extend it to all four targets:

1. Protocol changes are **additive-optional first** (Worker validator accepts new optional keys), then producers (iOS/Convex) start sending, then keys become required only after the oldest TestFlight build in the field has expired (90 days [12]) or a `minProtocol` bump is deliberately shipped.
2. Deployment order for a protocol-affecting release: **Worker (guarded) → Convex (Deploy) → iOS (TestFlight)**. The promotion gate enforces the order (7.3).
3. DO migrations (`exports`/`migrations` changes) are the one non-rollbackable operation [6][7]; they require an ADR, a scheduled window with no active rooms, and `wrangler deploy` (not `versions upload`).

### 7.3 Gate extensions (Code/Staging tier, secrets untouched)

- **CI (G1, G2)**: add `contracts/fixtures/combat.v1.json` (envelope, every `CombatCommand` variant incl. `fire` with and without `observation`, `ServerMessage` variants, ticket claims, projection) and make `packages/combat-protocol` tests, Worker tests, Convex tests **and** an XCTest in `ios/` all round-trip it; add a `verify-repo.sh` check that the four version literals equal `protocolVersion` in the manifest. Fails the PR, needs no secret.
- **Guarded deploy (G4)**: extend `combat-deploy.mjs --verify` with a Staging probe that mints a real ticket from the *deployed* Convex (`combat:prepare`/`combat:ticket` on a synthetic match), opens an authenticated WebSocket, waits for `snapshot`, sends `leave`, and confirms a `publishProjection` receipt — turning `ticketKeyParity`, `authenticatedWebSocket`, `projectionReceipt` from `"not-tested"` into `"passed"`/`"failed"` in the evidence JSON. Secrets stay where they are (Convex env, Worker secrets); the probe only needs a Convex client URL and the ticket it is issued. This is exactly the 2026-09-22 probe, automated.
- **Promotion gate (G3)**: add `combatWorkerVerifiedForSha` — the sanitized `combat-worker-*` evidence artifact for the candidate SHA (or for the newest Worker SHA that the manifest declares compatible) with the three acceptance fields `passed`. Missing → `combatNotVerifiedForSha`, fail-closed, matching existing reason-key style. Operator override stays an explicit workflow input, never a default.
- **Deploy (G2)**: after Convex deploy, call the Worker `/health` and fail if `protocolVersion` is outside the Convex build's supported range; record the Worker version in `release-evidence`.

### 7.4 Operator controls preserved or strengthened

- No new secret. `secrets.required` remains the deploy-time guard [8]; operator continues to supply both secrets via stdin/private file; OAuth identity check unchanged.
- **Active-match awareness (G5)**: `combat-deploy.mjs --preflight` warns (and `--deploy` requires `VKZ_ACTIVE_MATCH_DISRUPTION_ACKNOWLEDGED=true`) because deployment resets live rooms [9]. Consider `wrangler versions upload` + `versions deploy` so the upload is separable from the cut-over [7] — allowed only when no DO migration is included.
- **Rollback runbook (G6)**: document `wrangler rollback <version-id>` preconditions [6], the fact that Convex and iOS are *not* rolled back by it, and the required follow-up: re-run the §7.3 Staging probe and write a `combat-worker-rollback` evidence JSON. The manifest's compatibility range tells the operator whether the prior Worker version can still serve the current Convex/iOS pair; if not, Convex must be redeployed at the matching SHA first.
- Reports stay untrusted input; the added version fields are strings validated by the Worker before issue creation.

### 7.5 Staging (absence today)

There is no staging Worker or Convex deployment (§2). **Proposal**: a second Worker name (`vkz-combat-staging`) via a wrangler `env`, and a Convex dev deployment, both fed by the same guarded script with a `--target staging` flag and their *own* secret pair. Until this exists, "Staging" evidence remains operator probes against production, as in the build log.

## 8. Physical two-phone test matrix

Rules: name device models and iOS versions; sanitize; record in `docs/build-log.md`; simulator/Code results never close a row. "Pass" criteria reference existing constants so they are testable against current code first (C0 baseline), then re-run once C1/C2 land. Device pairs: **P1** LiDAR+LiDAR (e.g. two Pro models), **P2** LiDAR+non-LiDAR, **P3** non-LiDAR+non-LiDAR. Apple's LiDAR device list was not fetched by this spike; confirm `supportsSceneReconstruction` at runtime and log it, rather than trusting model names.

| ID | Scenario | Pairs | Procedure (both phones ready → `combat:prepare` → immediate play) | Pass (record observed values) | Closes at tier |
|---|---|---|---|---|---|
| M1 | Zero-step start | P1 P2 P3 | Time from second `setReady` to first accepted `fire` | No scan/alignment UI shown; first shot accepted; time recorded (**Speculation** target < 10 s) | Physical |
| M2 | Baseline sighting hit | all | Shooter aims at fully visible victim at 3, 5, 8 m; 10 shots each | `bodyHit` rate and `noSighting`/`ambiguousTarget` counts logged; ≥ 0.8 confidence achieved at each range or the failing range recorded | Physical |
| M3 | Wall-before-body | all | Victim steps fully behind a wall; shooter fires at last-seen point within 1 s, then after 1 s | C0: shots within 1 s may still hit (documents the cover gap); after `COVER_OBSERVATION_MS` → `noSighting`. C1 (when built): `occluded` refusal within 1 s | Physical |
| M4 | Body-before-wall | all | Victim steps *out* from behind a wall into view; shooter fires as soon as skeleton appears | Time from emergence to first acceptable observation; no false `occluded` refusal under C1 | Physical |
| M5 | Doorway | P1 P2 P3 | Victim visible through an open doorway at 4–6 m; then door frame partially occludes torso | Hit accepted through the opening; under C1 a `door`-classified surface must **not** be treated as wall on LiDAR phones; on non-LiDAR record whether plane classification labels the door (unverified, §6.4) | Physical |
| M6 | Partial occlusion | all | Only head+one shoulder, then only limbs, visible behind furniture | Hit zone reported matches the visible zone; limb-only observation either refuses or lands `limbs`, never `torso` | Physical |
| M7 | Moving surfaces | P1 P2 | A third person walks between shooter and victim; a door swings closed | C0: behaviour recorded. C1: moving body/door must not become persistent cover after it leaves (`ARMeshAnchor` refinement caveat [3]) | Physical |
| M8 | Tracking loss | all | Shooter covers camera 3 s / points at blank wall (`insufficientFeatures` [10]) mid-shot | Input locked while `limited`; `pose.tracking != normal` refuses pose-observations (code L185); recovery to `normal` without app restart; time recorded | Physical |
| M9 | Reconnect | all | Toggle airplane mode 5 s on one phone; then 20 s (past the 15 s silence close) | 5 s: `resume` re-admits with same epochs; 20 s: close 1001 observed, new ticket minted, room paused/unpaused per `coverage()`; no duplicate shots after replay | Physical + Staging |
| M10 | Map convergence (C2) | P1 P2 P3 | Play for 3 min while both phones roam two rooms; log room alignment residual/time | Residual and time-to-C2 recorded per pair; **no target claimed** — first data point. Also records collab bytes vs 256 KB/s budget | Physical |
| M11 | No-convergence fallback | P2 P3 | Phones start in different rooms and never see common features (2026-09-17 failure shape) | Combat playable at C0/C1 throughout; no "Linking play area" style blocking UI; C2 never claimed by the room | Physical |
| M12 | Reports | all | Submit an in-game report after M3 and after M9 | GitHub issue created (or 503 recorded if `GITHUB_ISSUES_TOKEN` absent); body contains release/protocol/Worker version and epoch history (after §7.1) and no secrets/identifiers | Physical + Staging |
| M13 | Rollback | all | Operator rolls Worker back one version mid-lobby, then mid-match | Mid-lobby: tickets still admit (compatibility range honoured). Mid-match: room pause + epoch bump observed on both phones, play resumes; `combat-worker-rollback` evidence written; refused if a DO lifecycle change intervened [6] | Physical + Staging |
| M14 | Secret parity | — | Deliberately mismatch `COMBAT_TICKET_SECRET` on a staging pair | 401 within admission; §7.3 probe reports `ticketKeyParity: failed`; nothing else deploys | Staging |
| M15 | Mid-match Worker deploy | all | Guarded deploy while a match runs | Both phones observe pause/epoch bump [9], resume without re-alignment; operator acknowledgement recorded | Physical + Staging |

Per-row evidence must state: device models, iOS versions, `supportsSceneReconstruction` result, Worker version tag, release SHA, and the sanitized diagnostic export. Any row where the observed result contradicts a Code-tier assumption in §3 becomes a scenario fixture under `shared/simulation/scenarios/` per [docs/testing-strategy.md](../testing-strategy.md).

## 9. Absences and open questions (stated as absences)

- No physical-device evidence for ADR 0013 sighting hits exists in the repository (§4.6).
- No staging Worker/Convex environment exists (§2, §7.5).
- No Apple primary source publishes plane-detection or mesh convergence times, `CollaborationData` byte rates, or indoor relocalization success rates; the prior brief recorded the same absences [shared-arena-frame-options.md §6.4].
- No Apple source fetched here lists LiDAR-equipped models; runtime `supportsSceneReconstruction` must be logged instead.
- Whether `ARPlaneAnchor.Classification` includes a `door` value was not verified (only `ARMeshClassification.door` was [4]).
- Cloudflare does not document how long a Durable Object reset takes on deployment; the room's 250 ms stall threshold will therefore trip on every deploy (inference from [9] + `cadence.ts`), which §7.4 treats as expected.
- The Convex `deployment:env:view` permission blocker from [live-combat-deployment.md](live-combat-deployment.md) is unchanged; nothing here assumes it resolved.

## 10. Recommendations

1. **Do not add a scan/alignment step**; ADR 0013 already delivers zero-step two-player start at Code tier. Run matrix rows M1–M2, M8–M9, M12 first on P2 (mixed) to obtain the first Physical evidence for sighting, then record it in the build log.
2. **Close release drift before adding room understanding**: manifest + shared `combat.v1` fixture consumed by iOS (G1/G2), automated admission/projection probe in `combat-deploy.mjs` (G4), `combatWorkerVerifiedForSha` in the promotion gate (G3), active-match acknowledgement and rollback runbook (G5/G6). None of these require a new secret or weaken operator control.
3. **Add C1 (shooter-local surface refusal) as an additive-optional `fire.surfaces` key**, Worker validator first, then iOS; matrix rows M3–M7 are its acceptance evidence.
4. **Treat C2 (fused shared room) as an experiment behind a rules flag** until M10/M11 produce residual and convergence data on at least P2 and P3; keep C0/C1 the guaranteed play path.
5. **Keep saved arenas (C3) unchanged** and optional.
6. **Write an ADR only after** M1–M9 evidence exists; this brief deliberately proposes none.

## Sources

Apple primary documentation (accessed 2026-09-26):

1. Apple, `ARPlaneAnchor` — https://developer.apple.com/documentation/arkit/arplaneanchor
   1a. Apple, `ARRaycastQuery` — https://developer.apple.com/documentation/arkit/arraycastquery
2. Apple, `ARWorldTrackingConfiguration.sceneReconstruction` and `supportsSceneReconstruction(_:)` — https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/scenereconstruction ; https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/supportsscenereconstruction(_:)
3. Apple, `ARMeshAnchor` — https://developer.apple.com/documentation/arkit/armeshanchor
4. Apple, `ARMeshClassification` — https://developer.apple.com/documentation/arkit/armeshclassification
5. Apple, `ARFrame.sceneDepth` — https://developer.apple.com/documentation/arkit/arframe/scenedepth
10. Apple, "Managing Session Life Cycle and Tracking Quality" and `ARCamera.TrackingState` — https://developer.apple.com/documentation/arkit/managing-session-life-cycle-and-tracking-quality ; https://developer.apple.com/documentation/arkit/arcamera/trackingstate-swift.enum
11. Apple, `ARSession.getCurrentWorldMap(completionHandler:)` — https://developer.apple.com/documentation/arkit/arsession/getcurrentworldmap(completionhandler:)
12. Apple, App Store Connect Help, "TestFlight overview" — https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/
13. Apple, `VNDetectHumanBodyPoseRequest` — https://developer.apple.com/documentation/vision/vndetecthumanbodyposerequest

Cloudflare primary documentation (accessed 2026-09-26):

6. Cloudflare, Workers "Rollbacks" — https://developers.cloudflare.com/workers/configuration/versions-and-deployments/rollbacks/
7. Cloudflare, Workers "Versions & Deployments" and "Gradual deployments" — https://developers.cloudflare.com/workers/configuration/versions-and-deployments/ ; https://developers.cloudflare.com/workers/configuration/versions-and-deployments/gradual-deployments/
8. Cloudflare, Workers "Secrets" — https://developers.cloudflare.com/workers/configuration/secrets/
9. Cloudflare, Durable Objects "Access Durable Objects Storage" — https://developers.cloudflare.com/durable-objects/best-practices/access-durable-objects-storage/
14. Cloudflare, Durable Objects "Limits" — https://developers.cloudflare.com/durable-objects/platform/limits/
15. Cloudflare, Workers "Version metadata binding" — https://developers.cloudflare.com/workers/runtime-apis/bindings/version-metadata/
16. Cloudflare, "Gradual deployments with Durable Objects" — https://developers.cloudflare.com/workers/versions-and-deployments/gradual-deployments/with-durable-objects/ (content confirmed via search snippet; page also linked from source 7)
17. Cloudflare, Durable Objects "Use WebSockets" — https://developers.cloudflare.com/durable-objects/best-practices/websockets/

Convex primary documentation (accessed 2026-09-26):

18. Convex, "Environment Variables" — https://docs.convex.dev/production/environment-variables

Repository sources (this checkout at `main` 0750e9b): `AGENTS.md`; `docs/delivery-pipeline.md`; `docs/testing-strategy.md`; `docs/outpost-operations.md`; `docs/playbooks/kil-ticket-loop.md`; `docs/roadmap.md`; `docs/build-log.md`; `docs/decisions/0013-quick-play-sighting-hits.md`; `docs/research/live-combat-deployment.md`; `docs/research/shared-arena-frame-options.md`; `.github/workflows/{ci,deploy,testflight,devin-report}.yml`; `scripts/ci/{verify.sh,verify-repo.sh,verify-ios.sh}`; `scripts/release/{promotion-gate,deployment-gate,combat-deploy,promote-testflight,write-evidence,redact}.mjs`; `packages/combat-protocol/src/{index,validation}.ts`; `packages/combat-simulation/src/{index,history,flight}.ts`; `services/combat-worker/{wrangler.jsonc,README.md,src/*}`; `convex/functions/{combat,matches,shots}.ts`; `contracts/README.md`, `contracts/fixtures/*.json`; `ios/VictoriaKillZone/VictoriaKillZone/Targeting/TargetingSession.swift`, `Targeting/MapLab/MapLabARDriver.swift`, `Features/Realtime/RealtimeArenaController.swift`, `Services/Realtime/{CombatWire,CollabChunking,CombatMapClient,MatchReportClient}.swift`. No practitioner (non-official) sources were used in this brief.
