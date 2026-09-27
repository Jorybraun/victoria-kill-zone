# Physical acceptance matrix for 2–4 phone Quick Duel with mixed UWB / LiDAR (BIO-37)

Status: research brief, not a decision. Tracks [BIO-37](https://linear.app/biossphere/issue/BIO-37). Read-only: no code, branch, commit, PR, deployment, ADR or device trial was produced. Nothing in this document is physical-device evidence. Companion provenance: [device-validation-multiplayer.provenance.md](device-validation-multiplayer.provenance.md).

Builds on — does not repeat — [zero-step-architecture-synthesis.md](zero-step-architecture-synthesis.md) (BIO-36) and its seven briefs. The synthesis §15 already defines rows A1–A7, B, C, D, E, F for a **two-phone** pair set P1–P3 (LiDAR mix only) and the BIO-36 brief B5 §8 defines M1–M15 for the same pair set. This brief extends both to **2, 3 and 4 phones with a UWB axis**, adds the identity metrics that only exist once there is more than one opponent, and audits what >2-player fixtures exist. Where a row here duplicates a synthesis row it says so and defers.

Product decisions taken as given (owner, BIO-37 assignment): the Saved Arena / shared-frame concept (ADR 0010/0011, `SharedArena`, `DuelFrame`) is being removed; Quick Duel (ADR 0013 sighting) is the only play mode; start is never gated by a setup step; the target is 2–4 players with zero setup. Consequences for this brief: every row is written for `sighting` geometry only; no row assumes a shared frame, `frameReady`, relocalization or ARWorldMap; the Saved Arena rows in the synthesis (A7, slice 7, D4-collaboration) are treated as withdrawn.

Labels used throughout:

- **[repo]** — read from this repository at `main` `3d89b7f` (2026-09-27, clean tree); paths and line numbers are to that commit.
- **[Apple]** — official Apple documentation, numbered in §12.
- **[synthesis]** / **[B5]** / **[ADR 0013]** — the BIO-36 synthesis, its brief B5, or ADR 0013, used without re-derivation.
- **[inference]** — follows from the above but was not observed.
- **[proposal]** — a design choice made here; every number attached to a proposal is a placeholder until a physical row measures it.
- **[speculation]** — plausible, unverified, flagged.
- **Absence** — looked for and not found; stated as an absence, never converted into a claim.
- **Tiers** (AGENTS.md, `docs/testing-strategy.md`): **Code** (unit/contract tests, `pnpm verify`), **Simulator** (Xcode simulator, `pnpm verify:ios`), **Staging** (deployed Convex + `vkz-combat-staging` Worker, real tickets, no phones), **Physical** (named iPhone models + iOS versions, observed result). Only Physical closes a Physical row.

## 1. The question

What must be observed, on which phones, in which scenarios, with which metrics, and recorded where, before anyone may claim that a Quick Duel with 2, 3 or 4 players — on any mix of LiDAR / non-LiDAR and UWB / no-UWB iPhones running iOS 17+ — attributes hits to the right opponent, starts without setup, and stays playable for a match? And: which of that can already be exercised in code, simulator or staging today, and what is missing?

## 2. Repository facts the matrix depends on (verified)

| # | Fact | Evidence [repo] |
|---|---|---|
| R1 | `sighting` is structurally 2-player at every tier. Convex `QUICK_DUEL_MAX_PLAYERS = 2`; `prepare` fails `QUICK_DUEL_FULL` for a sighting roster > 2; `matches.create` forces `maxPlayers: 2` when geometry is `sighting`; the third joiner is refused. `selectCombatGeometry` upgrades a stored `phoneProxy` to `sighting` only when the frozen roster is ≤ 2. | `convex/functions/combat.ts` L27, L35–37, L57, L65; `convex/functions/matches.ts` L99, L149–150 |
| R2 | The simulation refuses any sighting `fire` on a roster with ≠ 1 opponent as `ambiguousTarget`, before looking at the observation. | `packages/combat-simulation/src/index.ts` L283 |
| R3 | The client chooses `targetPlayerId` by roster elimination only: exactly one connected non-local player, else `nil` (no shot). Freshness window 0.1 s; confidence ≥ 0.8. No distance, bearing or per-body reasoning. | `ios/…/Features/Realtime/RealtimeBodyAssociation.swift` L55–63 (`remote.count == 1` at L61) |
| R4 | Vision runs a single 2D `VNDetectHumanBodyPoseRequest`; when several bodies are detected the candidates are reduced to **one** by `.max(by: score)` where score mixes joint confidence and crosshair proximity. No per-person tracking, no `VNDetectHumanBodyPose3DRequest`, no identity. | `ios/…/Targeting/TargetingSession.swift` L809, L1169–1174, L1253–1254 |
| R5 | `uncertaintyMeters` is a hard-coded `0.08` on the fire path; the Worker refuses `> 0.1` as `noSighting`. | `RealtimeArenaController.swift` L423; `index.ts` L288–289 |
| R6 | Nearby Interaction code exists (`NearbySessionManager`, one `NISession` per peer, gates on `supportsPreciseDistanceMeasurement`, uses `supportsCameraAssistance`) but is only constructed on the collaborative-frame path; under sighting it never runs. | `ios/…/Targeting/NearbyInteraction/NearbySessionManager.swift` L56, L106, L117; `RealtimeArenaController.swift` L384–385 |
| R7 | Capability probes exist: `DeviceCapabilityReport` records model, iOS version, body-tracking support, plane classification, `supportsSceneReconstruction(.mesh)` and `supportsFrameSemantics(.sceneDepth)`. Absence: no UWB capability field in the report. | `ios/…/Targeting/LocalSurfaces/DeviceCapabilityProbe.swift` |
| R8 | Thermal state and fps are sampled — but only in the local-surfaces telemetry CSV (`elapsed_ms,frames,fps,plane_count,…,thermal_state`), not in the duel loop or in `MatchReport`. | `TargetingSession.swift` L1065; `LocalSurfaceTelemetry.swift` L38, L128–132 |
| R9 | `MatchReport` carries `device{model, ios, build}`, transcript (≤ 4,000 chars), diagnostic log, client release manifest, server release identity (first and current) and `authorityEpochs`; the Worker turns it into a GitHub issue (quota 12/match, 4/player) that `devin-report.yml` triages. | `ios/…/Services/Realtime/MatchReportClient.swift` L5–18; `services/combat-worker/src/report.ts`; `.github/workflows/devin-report.yml` |
| R10 | Per-shot server evidence is the Worker's `BulletLedger` (SQLite `bullets` / `bullet_events`). `verdict-ledger.v1` is a Convex contract from the host-adjudication era (`shots:recordVerdict`) with backend tests and **no client caller**; it is not on the Quick Duel path. | `services/combat-worker/src/bullet-ledger.ts`; `docs/interface-contracts.md` L656; `convex/tests/record-verdict.test.ts` |
| R11 | Release gates since #128–#132: `release-manifest.json` + `scripts/ci/check-release-manifest.mjs` (CI); `contracts/fixtures/combat.v1.json` round-tripped by protocol, Worker, Convex and XCTest; Worker `/health` exposes the manifest and Deploy runs `check-worker-health.mjs`; `combat-deploy.mjs --verify` runs a real admission probe against a **2-player sighting fixture room** and writes `combat-worker-admission-probe` evidence; the TestFlight promotion gate refuses `combatNotVerifiedForSha` unless `VKZ_COMBAT_WORKER_VERIFIED_SHA` equals the candidate SHA (manual `combat_worker_override`); staging target `vkz-combat-staging`; rollback runbook. | `scripts/release/combat-deploy.mjs` L155, L442–466; `scripts/release/promotion-gate.mjs` L24, L113–116; `docs/runbooks/*.md` |
| R12 | No post-ADR-0013 physical entry exists in `docs/build-log.md`; the latest entries are 2026-09-22 (401 ticket mismatch; "Linking play area" stall). ADR 0013's six-item evidence list is entirely uncollected. | `docs/build-log.md`; ADR 0013 "Evidence to collect" |

**Consequence [inference]:** a 3- or 4-player Quick Duel cannot be *created* today (R1), cannot *fire* today (R2), and the client would not even *emit* a shot (R3). Every 3–4 player Physical row in §6 therefore presupposes an identity rule that does not yet exist (§3). The matrix is written so that it does not depend on *which* rule ships; §3 names the candidates ADR 0013 §8 already lists, and marks which rows discriminate between them.

## 3. What a 3–4 player sighting needs that a 2-player one does not

With one opponent the observed body *is* the opponent (ADR 0013 §5). With two or three opponents the fire command must carry a `targetPlayerId` that the Worker can trust more than "the only other roster member". ADR 0013 §8 names two candidates; a third follows from the existing pose stream. None is implemented (R1–R3). This brief does not choose; it defines what the matrix must be able to tell apart.

| Id | Candidate identity rule (all **[ADR 0013 §8]** or **[inference]**, none implemented) | Zero-setup? | Device dependency | What the matrix must measure to accept or reject it |
|---|---|---|---|---|
| I0 | **Refuse on ambiguity**: if the shooter's frame contains ≥ 2 bodies, refuse (`ambiguousTarget`); if exactly one, attribute to… whom? With 2+ opponents "the only body" is still not identifiable without another signal. Usable only as a *guard* on top of I1/I2, or with a rule such as "the one opponent who reports itself in my field of view" [speculation]. | Yes | none | S1/S2 refusal rate (how often play is blocked because two bodies are visible); misattribution when exactly one body is visible but it is the wrong opponent (S5, S6) |
| I1 | **NI bearing at fire time**: one `NISession` per peer (R6; 3 sessions at the 4-player cap), attribute the sighted body to the peer whose `direction` vector is closest to the reticle ray. Apple: `direction` is `nil` out of the narrow line-of-sight cone or when people/walls block the UWB path; Camera Assistance widens the cone on supporting devices [Apple 4][5][6]. | Yes (permission prompt only) | **all phones need UWB** for full coverage; a no-UWB phone gets no direction from anyone and no one gets direction to it | direction availability rate while aiming (S1–S4); bearing separation vs opponent angular separation (S1 side-by-side is the hard case); behaviour on mixed U0/U1 rosters (§5) |
| I2 | **Pose / mutual-sighting exchange**: each phone streams its own camera pose and body-observation ranges; the Worker (or client) attributes by consistency of "who could be where" across phones over time. Depends on monocular body range (`uncertaintyMeters` is a constant 0.08 today, R5) and on the D1 convergence data the synthesis §15 asks for and which does not exist. | Yes | none | needs D1/D2 σ data first; matrix rows tag `identityMethod` so the same S-rows re-run once I2 exists |

**Requirement for the matrix [proposal]:** every shot record in a trial names `identityMethod ∈ {rosterElimination, refuseAmbiguous, niBearing, poseExchange}` and the raw inputs that method used (visible-body count, NI direction/distance per peer or `nil`, pose age), so a single trial can be re-scored offline against a different rule. Without this, each candidate would need its own trial campaign.

## 4. Device classes and capability probes

Apple publishes runtime probes, not model lists, for the capabilities that matter here; the matrix therefore classifies phones by probe result, recorded at session start, and names the model/iOS version only for the build-log (AGENTS.md; `docs/delivery-pipeline.md` L142).

| Axis | Class | Probe [Apple] | Notes |
|---|---|---|---|
| Depth | **L+** LiDAR | `ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)` — Apple: "requires a device with a LiDAR Scanner" [Apple 7]; `supportsFrameSemantics(.sceneDepth)` (already in `DeviceCapabilityReport`, R7) | Under sighting the depth axis affects **nothing in the verdict** today (no mesh, no depth consumer, R4; synthesis §3). It stays in the matrix because (a) thermal/frame-rate cost may differ, (b) `VNDetectHumanBodyPose3DRequest` "uses AVDepthData information to improve the accuracy" if the system allows it [Apple 3] — a future I2 input, (c) the owner asked for it. |
| Depth | **L−** non-LiDAR | probes above return `false` | |
| Ranging | **U0** no UWB | `NISession.deviceCapabilities.supportsPreciseDistanceMeasurement == false` [Apple 4][5] | iPhone SE models and pre-iPhone 11 [Apple 8: "iPhone 11 or later"]; `design/slices/010-quick-play-setup.md` copy says "iPhone 11 or later (not SE)" [repo] |
| Ranging | **U1** UWB, direction in narrow cone | `supportsPreciseDistanceMeasurement && supportsDirectionMeasurement` | direction `nil` outside the cone or when blocked by "people, vehicles, or walls" [Apple 6] — bodies are exactly the obstacles in a duel [inference] |
| Ranging | **U1c** U1 + Camera Assistance | `supportsCameraAssistance` (iOS 16+) [Apple 6] | widens direction availability; needs an `ARSession` handed to NI (`setARSession`) — the live sighting session runs `ARBodyTrackingConfiguration`; whether Camera Assistance accepts it is **unverified** (absence in Apple docs) |
| Ranging | **U2** extended distance | `supportsExtendedDistanceMeasurement` [Apple 5] | Apple documents the probe, not a chip name; the "U2 = iPhone 15+" mapping used in slice 010 is repository copy, not an Apple statement [repo]. Marked **[inference]**. |

**Gap [repo]:** `DeviceCapabilityReport` has no UWB fields and is not attached to `MatchReport`. §8 item E1 asks for both.

## 5. Phone-count and mix design

Full factorial is 2 depth × 4 ranging classes per phone, for 2–4 phones — hundreds of rosters. The matrix uses a **pairwise (all-pairs) reduction [proposal]**: every ordered *pair of classes* that can occur between a shooter and a victim appears at least once at each roster size, because every hit is a shooter→victim relation and identity signals (NI) are pairwise. Homogeneous rosters are kept as controls.

| Roster id | Size | Composition (depth / ranging) | Why it is in the matrix |
|---|---|---|---|
| **P1–P3** | 2 | L+/L+, L+/L−, L−/L− (ranging ignored) | synthesis §15 pairs; baseline rows A1–A4 re-used unchanged |
| **Q1** | 2 | U1/U1 | the only roster where NI bearing can be measured symmetrically as a *pure* signal (no combat dependency): calibrates I1 before 3-player rows |
| **Q2** | 2 | U1/U0 | proves the no-UWB fallback in the simplest setting |
| **T1** | 3 | all U1 (any depth) | first roster where identity is needed; I1 fully available |
| **T2** | 3 | U1, U1, U0 | mixed: two peers have bearing to each other, none to the third |
| **T3** | 3 | all U0 | identity must come from I0/I2 only |
| **T4** | 3 | L+, L−, L− with any ranging | depth control for thermal/fps; combine with T1 or T2 to save phones |
| **F1** | 4 | all U1 | Phase 1 cap; 3 `NISession`s per phone (R6) |
| **F2** | 4 | U1, U1, U0, U0 | the realistic friend-group mix |
| **F3** | 4 | any mix including at least one L+ and one L− | thermal/fps at cap |

Rosters T4/F3 can be satisfied by choosing the phones for T1/T2/F1/F2 appropriately; the minimum distinct hardware is **four phones: one L+U1, one L−U1, one L−U0, plus one more U1 of either depth**, which covers every row [inference]. If a U2/U1c phone is available it replaces one U1 and rows S1/S3 are repeated once with it.

## 6. Scenario × metric matrix

Rules inherited from synthesis §15: name device models and iOS versions; record probe results, `releaseSha`, `workerVersionTag`, Convex deployment; record in `docs/build-log.md` per its template; a Code/Simulator/Staging result never closes a Physical row; every observed contradiction of a Code-tier assumption becomes a fixture (§9). **No target value is claimed for any row**; where one is written it is marked speculation.

Ground truth: every trial shot needs a truth label (intended target, whether the reticle was on that body, who else was in frame). §8 defines the referee protocol and the trial-mode capture that makes this cheap; without it, identity precision/recall cannot be computed.

Range bands for all rows: 3 m, 5 m, 8 m (synthesis A2). Ten shots per shooter per band per row unless stated [proposal].

### 6.1 Baseline and start (all roster sizes)

| Id | Scenario | Rosters | Metrics | Tier | Relation to prior rows |
|---|---|---|---|---|---|
| S0 | Second/third/fourth `setReady` → first accepted `fire`, no setup UI | P1–P3, T1, F1 | **TTFS** (time-to-first-shot), per phone; permission prompts counted (camera; NI if I1) | Physical | = synthesis A1 extended to 3–4; for 3–4 blocked until R1/R2 change |
| S0b | Third joiner on a 2-player room | any 3 | today: `QUICK_DUEL_FULL` and the copy "Quick Duel is 2 players; use a Saved Arena for 3–4" — **that copy must go with Saved Arena removal** | Physical (copy audit), Code | = synthesis A6 |
| S0c | Tracking loss / reconnect | as synthesis | as synthesis | Physical + Staging | = A3, A4; not repeated |

### 6.2 Identity scenarios (the new content)

Each row is run at roster sizes 2 (control: identity trivially correct or `nil`), 3 and 4. Victims are marked V1..V3; the referee calls the intended target before each shot.

| Id | Scenario | What it stresses | Metrics (per shooter, per band, per identity method) | Tier |
|---|---|---|---|---|
| S1 | **Two opponents side by side**, shoulder-to-shoulder to ~1 m apart, both fully visible, shooter aims at V1 | Vision returns 2 bodies; `.max(by: score)` picks one by crosshair proximity (R4); NI bearings are separated by the same small angle | identity precision/recall, misattribution rate, refusal rate (`ambiguousTarget`), NI direction availability, bearing separation vs angular separation | Physical |
| S2 | **Crossing**: V1 and V2 walk across the shooter's view in opposite directions, crossing at centre; shooter tracks V1 and fires before, at and after the crossing | body-index swap at occlusion; freshness window (0.1 s client / 1 s Worker) | misattribution rate before/at/after crossing; hits landing on V2 after the swap; `noSighting` counts | Physical |
| S3 | **Partial occlusion** of V1 by furniture (head+shoulder; limbs only), V2 fully visible elsewhere in frame | score prefers the fully visible wrong body [inference from R4] | misattribution; zone correctness (limb-only never `torso`, = synthesis C3) | Physical |
| S4 | **Similar clothing**: V1 and V2 in matching outfits, 2 m apart, then swapping positions while the shooter blinks the camera (covers lens 1 s) | any appearance-based tracker [none exists today] would fail; tests whether the identity method depends on appearance at all | misattribution after swap; whether I1 (NI) is unaffected | Physical |
| S5 | **One behind another**: V2 directly behind V1 along the shooter's ray, V2 partially visible above/beside V1 | single body reported or two overlapping colliders; UWB line of sight to V2 blocked by V1's body ("people … walls" [Apple 6]) | misattribution to V2 (or to V1 when aiming at V2); NI direction `nil` rate for the occluded peer | Physical |
| S6 | **Out-of-view opponent**: V2 stands behind the shooter or outside the camera FOV while shooter fires at V1; then shooter fires at *empty space* with V2 behind them | roster elimination cannot exclude V2; NI bearing can | misattribution to out-of-view V2; false hits on empty space (must be 0 — = ADR 0013 evidence item 3) | Physical |
| S7 | **Bystander**: non-player walks between shooter and V1 (ADR 0013 evidence item 5) | any body is a candidate; with 3–4 players a bystander can be attributed to *any* opponent | bystander-attribution rate per identity method | Physical |
| S8 | **Full cap churn**: 4 players, 3 min free play, kills/respawns, phones handed between hands | end-to-end; = ADR 0013 item 6 at cap | K/D convergence across all 4 phones vs referee tally; disconnects; stalls; `authorityEpoch` bumps | Physical + Staging |

### 6.3 Performance and thermal (every roster; repeated at cap)

| Id | Scenario | Metrics | Tier |
|---|---|---|---|
| H1 | 5 min match at roster size 2, 3, 4 with identity method on | camera fps (`ARSession` frame cadence) and Vision request completion rate; `ProcessInfo.thermalState` transitions `nominal → fair → serious → critical` [Apple 9][10] with timestamps; battery % delta; per-device class | Physical |
| H2 | H1 with 3 `NISession`s running (I1) vs off | fps/thermal delta attributable to NI; Apple publishes no NI power figure (absence) | Physical |
| H3 | Xcode Device Conditions thermal state forced to `serious` then `critical` during H1 [Apple 11] | whether the app degrades (Vision cadence, tracer rendering) and whether shots are still accepted; "device does not actually get physically warmer" so this is a *handling* test, not a thermal measurement [Apple 11] | Physical (device attached to Xcode) |

### 6.4 Metric definitions [proposal]

- **Identity precision** = shots the Worker attributed to player X that the referee labelled X ÷ all shots attributed to X. **Identity recall** = shots labelled X that were attributed to X ÷ all shots labelled X (a refusal counts against recall, not precision). Report per (roster size, identity method, range band, scenario).
- **Misattribution rate** = shots attributed to a player other than the labelled target ÷ shots accepted (refusals excluded). This is the fairness number; a refusal is annoying, a misattribution is unfair [inference].
- **Refusal rate** = `ambiguousTarget` + `noSighting` ÷ shots fired, with `noSighting` sub-coded by Worker reason (stale, confidence, uncertainty, empty colliders — `index.ts` L285–290).
- **TTFS** = wall-clock from the last player's `setReady` (Convex `prepare` timestamp) to the first `bodyHit`-or-`missExpired` event for each shooter (Worker event `atMs`); reported as per-phone values, not a mean, because permission prompts are per phone.
- **Frame rate** = ARKit frames delivered per second and Vision requests completed per second, sampled every 1 s; **thermal** = `thermalState` value per sample plus transition timestamps. Both already exist in `LocalSurfaceTelemetry` (R8) and need lifting into the duel loop (§8 E2).
- **Bearing separation** (I1 only) = angle between the NI `direction` vectors of two peers at the moment of a shot; reported against the referee-measured angular separation of the two victims (tape measure + distance, as ADR 0006's setup spec [repo]).

## 7. Tier map: what can be exercised where

| Row | Code | Simulator | Staging | Physical |
|---|---|---|---|---|
| S0 / S0b (roster caps, `QUICK_DUEL_FULL`, `ambiguousTarget`) | **exists**: `sighting.test.ts` L80 (3-player refusal), `combat-admission.test.ts` L77 (prepare refused), `LobbyStateMachineTests` matrix | lobby copy visible | `combat-deploy --verify` probe creates a 2-player sighting room only (R11) | required |
| S1–S7 identity | **missing** (see §9): no fixture where a sighting `fire` on a ≥ 3 roster resolves at all | Vision multi-body cannot be driven in the simulator without camera; a **recorded-frame replay** of the trial video through `TargetingSession` is possible in principle (Code/Simulator) but no harness exists (absence) | Worker-side attribution logic (once I1/I2 exists) can be exercised with synthetic `fire` + synthetic NI/pose inputs against the staging Worker | required for all rows |
| S8 churn | `load-scenario-lifecycle.test.ts` and `benchmarks/four-player.load.ts` run 4 clients — under `DEFAULT_RULES` (`trackedBody`, all `frameReady`), **not sighting** | — | the same load scenario pointed at `vkz-combat-staging` with `geometry:"sighting"` would be a new Staging row | required |
| H1–H3 | — | thermal Device Conditions work only on physical devices attached to Xcode [Apple 11] | — | required |

## 8. Evidence capture

### 8.1 What exists [repo]

- `MatchReport` → GitHub issue (R9): device model/iOS/build, release manifest, server release identity, epochs, transcript, diagnostic log. This is the only per-match evidence channel a player can trigger from the phone; it is opt-in and quota-limited (12/match).
- Worker `BulletLedger` (R10): every shot's terminal outcome, durable per match, 24 h retention.
- `LocalSurfaceTelemetry` CSV (R8): fps, plane counts, thermal — but only on the local-surfaces path, not in Quick Duel.
- `DeviceCapabilityReport` (R7): depth probes, no UWB.
- `docs/build-log.md` template (L47–61): the human ledger; `docs/testing-strategy.md` Tier 2 asks for "in-app match report JSON + screen recordings" and forbids UDIDs.
- `combat-worker-admission-probe` evidence record and `release-evidence` (R11): prove *which* Worker/Convex/iOS identity a trial ran against.

### 8.2 What is missing, and the proposed capture [proposal]

| Id | Gap | Proposal |
|---|---|---|
| E1 | No UWB capability in any report; no probe result in `MatchReport` | add `NISession.deviceCapabilities` booleans to `DeviceCapabilityReport` and attach the report to `MatchReport.device` |
| E2 | fps/thermal not sampled in the duel loop | run the existing 1 Hz sampler under sighting and include a bounded ring (last 300 s) in `MatchReport`; Apple's thermal notification (`thermalStateDidChangeNotification`) for transition timestamps [Apple 9] |
| E3 | No per-shot ground truth | **trial mode** (debug build flag, never shipped): before each shot the shooter taps the intended victim's tile; the tap, the visible-body count, each body's bounding box + score, NI direction/distance per peer (or `nil`), pose age, and the emitted `targetPlayerId` are appended to a local shot log with `shotId`. Ground truth stays on device and is exported with the setup log; the Worker's `BulletLedger` supplies the accepted attribution keyed by the same `shotId`. Precision/recall is computed offline by joining the two. |
| E4 | No referee record | paper/spreadsheet template per row: phones (model, iOS, class), positions (tape-measured distances and angular separation), referee's called target per shot, observed outcome on each HUD; photographed and attached to the build-log entry (no faces if bystanders are present — privacy, `docs/testing-strategy.md` sanitization rule) |
| E5 | Bullet ledger not exportable per match | a signed operator route or `wrangler` script to dump `bullets`/`bullet_events` for a match id within the 24 h retention window; today the only server-side per-shot view is the projection to Convex |
| E6 | Screen recordings unindexed | one recording per phone per row, named `<row>-<roster>-<phone class>-<releaseSha7>.mov`, referenced from the build-log entry |
| E7 | Verdict ledger | `verdict-ledger.v1` (R10) is a host-adjudication artefact with no Quick Duel role; either retire it with the Saved Arena removal or re-point the name at the bullet ledger export — open decision (§11) |

### 8.3 Build-log entry shape for a matrix row [proposal]

One build-log entry per (row, roster) using the existing template, with **Observed on physical devices** holding the metric table (precision/recall/misattribution/refusal per band), **Environment/artifact** holding `releaseSha`, `workerVersionTag`, Convex deployment, probe results per phone, identity method, and **Mocked or unproven** naming every roster class not covered. Attach: trial-mode shot logs, bullet ledger export, referee sheet, recordings. The `MatchReport` issue numbers link the automated channel to the entry.

## 9. Audit: >2-player fixtures and simulation cases today

| Location | Players | Geometry | What it asserts | Verdict for this matrix |
|---|---|---|---|---|
| `contracts/fixtures/combat.v1.json` | 2 (`p-host`, `p-guest`) | sighting | envelope/snapshot shapes; 21 refusal reasons incl. `ambiguousTarget`, `noSighting` | **no ≥ 3 roster fixture**; adding one is a contract change consumed by 4 test suites (R11) |
| `packages/combat-simulation/tests/sighting.test.ts` L80–83 | 3 | sighting | fire is refused `ambiguousTarget` | the only ≥ 3 sighting case; asserts the *ceiling*, not a resolution |
| `packages/combat-protocol/tests/validation.test.ts` L98–100 | 4/5 | none | roster bound 2–4 | bound only |
| `services/combat-worker/tests/ledger.test.ts`, `runtime.test.ts` L41, `report.test.ts` L236 | up to 4 | `DEFAULT_RULES` (trackedBody) | ledger accounting, 4-member admission, report quota | reusable roster builders; geometry wrong for Quick Duel |
| `services/combat-worker/tests/load-scenario-lifecycle.test.ts`, `benchmarks/four-player.load.ts` | 4 | trackedBody, all `frameReady` | load/lifecycle | would need `geometry:"sighting"` and observation-carrying fires |
| `shared/simulation/scenarios/four_player_crossfire.json`, `simultaneous_lethal_same_tick.json` (3), `degraded_tracking_stale_pose_late_shot.json` (3) | 3–4 | Swift phone-proxy engine, shared frame | crossfire ordering, simultaneous lethal, stale pose | **Saved-Arena-era engine**; scheduled for removal with the shared-frame concept; not reusable for sighting |
| `ios/…/RealtimeArenaTests.swift` L105 (`…AcrossFourPlayers`), L210–218 | 4 | `associate()` (phoneProxy) / `associateSighting` | phoneProxy picks `p2` by hand distance; **`associateSighting` returns `nil` on a 4-player roster** | the second is the client ceiling test; the first goes with phoneProxy |
| `ios/…/NearbyRendezvousTests.swift`, `NearbyTargetingRendezvousTests.swift` (`threeDeviceScene`) | 3–4 peers | NI transform solving (ADR 0012) | multi-peer NI bookkeeping | the only multi-peer NI tests; the *bearing-to-identity* use (I1) is untested |
| `convex/tests/combat-admission.test.ts` L70–77 | 3 | sighting | `maxPlayers` forced to 2; prepare refused | ceiling |

**Missing (absences, verified by search):** any sighting fixture or test in which a `fire` on a ≥ 3 roster is *accepted*; any contract fixture with roster > 2; any four-player sighting load run; any XCTest for a successful 3–4 player sighting association; any test where Vision reports two bodies and the chosen body is asserted (the `.max(by: score)` reduction at `TargetingSession.swift` L1173 has no test with two candidates — absence); any Staging row exercising a ≥ 3 sighting room (the `--verify` probe room is 2-player).

**Fixtures to add before Physical rows S1–S7 can be scored [proposal, Code tier]:** (F-a) `combat.v1.json` variant with 3 and 4 players under sighting once the cap moves; (F-b) simulation cases: 3-player sighting fire *with* an identity input resolves `bodyHit` on the named target; same fire with conflicting identity input → `ambiguousTarget`; out-of-view target (I1 `direction: nil`) → refusal; (F-c) `TargetingSession` two-body reduction test from recorded frames (S1 layout) asserting which body wins and that the score is exported for E3; (F-d) four-client load scenario under sighting. Each physical contradiction found in §6 becomes a fixture here (synthesis §15 rule).

## 10. How the release gates (#128–#132) apply

The gates prove *identity of the tested build*, not device behaviour. Their role in the matrix:

| Gate | What it guarantees for a trial | What it does not | Tier |
|---|---|---|---|
| CI `pnpm verify` + `check-release-manifest.mjs` + `combat.v1.json` round-trip (#128) | the four version literals agree; iOS, Worker, Convex and protocol parse the same fixture | nothing about ≥ 3 rosters until F-a exists | Code |
| Deploy + `check-worker-health.mjs` (#131) | the production Worker reports a manifest compatible with the deployed Convex | no staging equivalent runs automatically (absence) | Staging (prod) |
| `combat-deploy.mjs --verify` (#130) | a real ticket admits to the deployed Worker on a 2-player sighting room; evidence record written | a 3–4 player room is never probed; the probe room's `maxPlayers: 2` would itself fail once the cap changes and must be updated with it | Staging |
| Promotion gate `combatNotVerifiedForSha` (#131) | the TestFlight build that testers install was cut from a SHA whose Worker probe passed; override is explicit | does not require any build-log physical entry; a Physical row can only be *reported against* the promoted SHA, never enforced by the gate | Code (gate) |
| Staging target `vkz-combat-staging` (#130, #132) | S8 churn and Worker-side identity logic can be exercised without touching production rooms; deploys reset live DOs (synthesis §12) so trials must not run on production during a deploy window | absence: no staging Convex deployment is provisioned yet (runbook describes it) | Staging |
| Rollback runbook (#132) | if a trial build misbehaves, the Worker can be rolled back within compatibility range; Convex and iOS are not rolled back | — | operator |
| TestFlight (Mac Outpost) | trial phones install the promoted build; builds expire after 90 days [Apple 12]; each phone's build number is in `MatchReport.device.build` | — | Physical distribution |

**Sequencing rule [proposal]:** a Physical row is valid only if its `releaseSha` equals a SHA that passed `combatNotVerifiedForSha` (or carries the manual override in the build-log entry) and the trial's `MatchReport` shows `serverRelease == firstServerRelease` (no mid-trial Worker deploy). Rows run against staging record the staging probe evidence instead.

## 11. Open decisions

1. Which identity rule (I0/I1/I2, or a combination) is attempted first; the matrix is neutral but I1 rows are only meaningful on ≥ U1 rosters, and a U0 phone in the roster means at least one pair has no NI signal in either direction.
2. Whether `sighting` keeps a 2-player cap with a *separate* mode name for 3–4, or lifts the cap in place (`QUICK_DUEL_MAX_PLAYERS`, `matches.create`, `prepare`, `associateSighting`, `index.ts` L283 all change together; the `--verify` probe room and `combat.v1.json` follow).
3. Whether the depth axis stays in the matrix once Saved Arena code is gone (it affects no verdict today; keep only for H-rows and as a `VNDetectHumanBodyPose3DRequest` option).
4. Whether `verdict-ledger.v1` is retired or re-pointed (E7).
5. Whether trial mode (E3) is a debug flag in the shipped app or a separate scheme; the E3 shot log contains no secrets or identifiers, but it does contain body bounding boxes.
6. Who owns `services/combat-worker`, `packages/combat-*`, `ios/**/Features/**` for the fixture additions in §9 — unresolved since synthesis §16.1.
7. Whether Camera Assistance can be fed the `ARBodyTrackingConfiguration` session (Apple documents `setARSession(_:)` without listing accepted configurations — absence).

## 12. Sources

Apple (accessed 2026-09-27):

1. VNDetectHumanBodyPoseRequest — https://developer.apple.com/documentation/vision/vndetecthumanbodyposerequest
2. Detecting Human Body Poses in Images ("returns a unique observation for each detected human body pose"; up to 19 points; ignore confidence 0) — https://developer.apple.com/documentation/vision/detecting-human-body-poses-in-images
3. VNDetectHumanBodyPose3DRequest ("If the system allows it, the request uses AVDepthData information to improve the accuracy") — https://developer.apple.com/documentation/vision/vndetecthumanbodypose3drequest
4. NISession ("One session represents an interaction between the user and a single nearby object. To interact with multiple nearby objects, create a separate session for each.") — https://developer.apple.com/documentation/nearbyinteraction/nisession
5. NIDeviceCapability (`supportsPreciseDistanceMeasurement`, `supportsDirectionMeasurement`, `supportsCameraAssistance`, `supportsExtendedDistanceMeasurement`) — https://developer.apple.com/documentation/nearbyinteraction/nidevicecapability
6. Initiating and maintaining a session (direction only within a narrow cone; `nil` out of range / out of line of sight; obstacles "such as people, vehicles, or walls"; Camera Assistance in iOS 16) — https://developer.apple.com/documentation/nearbyinteraction/initiating-and-maintaining-a-session
7. `supportsSceneReconstruction(_:)` ("requires a device with a LiDAR Scanner") — https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/supportsscenereconstruction(_:)
8. Nearby Interaction framework overview ("UWB chip, such as iPhone 11 or later") — https://developer.apple.com/documentation/nearbyinteraction
9. `ProcessInfo.thermalState` — https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.property
10. `ProcessInfo.ThermalState` (nominal / fair / serious / critical) — https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum
11. WWDC19 412 "Debugging in Xcode 11" — thermal state Device Condition ("fair, serious, or critical"; "the device does not actually get physically warmer") — https://developer.apple.com/videos/play/wwdc2019/412/ ; WWDC19 422 "Designing for Adverse Network and Temperature Conditions" — https://developer.apple.com/videos/play/wwdc2019/422/
12. TestFlight overview (builds testable for 90 days; up to 100 internal / 10,000 external testers) — https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview
13. ARBodyTrackingConfiguration; `ARFrame.detectedBody` (`ARBody2D?`, a single optional body) — https://developer.apple.com/documentation/arkit/arbodytrackingconfiguration ; https://developer.apple.com/documentation/arkit/arframe/detectedbody

Repository (`main` `3d89b7f`):

14. `docs/decisions/0013-quick-play-sighting-hits.md` — §5 cap, §8 identity candidates, "Evidence to collect"
15. `docs/research/zero-step-architecture-synthesis.md` §15 (rows A–F), §16, §17; `zero-step-room-understanding-and-authoritative-combat.md` §8 (M1–M15)
16. `convex/functions/combat.ts`, `convex/functions/matches.ts`; `packages/combat-simulation/src/index.ts`, `flight.ts`, `history.ts`; `packages/combat-protocol/src/index.ts`, `validation.ts`
17. `ios/VictoriaKillZone/VictoriaKillZone/Features/Realtime/RealtimeBodyAssociation.swift`, `RealtimeArenaController.swift`; `Targeting/TargetingSession.swift`; `Targeting/NearbyInteraction/NearbySessionManager.swift`; `Targeting/LocalSurfaces/DeviceCapabilityProbe.swift`, `LocalSurfaceTelemetry.swift`; `Services/Realtime/MatchReportClient.swift`
18. `services/combat-worker/src/report.ts`, `bullet-ledger.ts`; tests listed in §9
19. `scripts/release/combat-deploy.mjs`, `promotion-gate.mjs`, `check-worker-health.mjs`; `scripts/ci/check-release-manifest.mjs`; `release-manifest.json`; `contracts/fixtures/combat.v1.json`; `docs/runbooks/combat-worker-rollback.md`, `combat-staging-target.md`; `docs/delivery-pipeline.md`; `docs/testing-strategy.md`; `docs/build-log.md`
20. `design/slices/010-quick-play-setup.md` (device copy "iPhone 11 or later (not SE)"; U1/U2 acceptance phones) — repository copy, used only as such
