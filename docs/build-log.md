# Build log

This is the integration-owned, evidence-based status record. Append observed results; do not paste secrets, signing material, unique device identifiers, or unsanitized logs.

## Current status — 2026-08-22

- **Current gate:** Pipeline bootstrap, before G0 Hardware.
- **Observed working:** Canonical product sources, delivery ownership, CI/deploy workflows, and guarded Outpost operator scripts are present. At 2026-08-22 10:35 PDT, local `pnpm verify` passed (`Repository contract: PASS`; `Workspace verification: PASS`), all CI/Outpost shell scripts passed Bash syntax parsing, both workflow files passed YAML syntax parsing, and `pnpm verify:ios` correctly skipped because the iOS scaffold has not landed. Xcode 26.6 and Devin CLI 3000.5.20 are installed.
- **Physical-device evidence:** None recorded in this repository.
- **Mocked or unproven:** Signed launch on two phones; camera/location permission; per-phone Convex mutation/subscription; spectator subscription; dual mirroring; debug-fire vertical slice.
- **Blockers:** No canonical remote is configured and the stored GitHub CLI login for `Jorybraun` is invalid; Outpost credential rotation/restart is not evidenced; macOS reports zero valid code-signing identities and no two connected phones are evidenced; Convex/demo environment credentials are not evidenced; the automated CI result on the integrated bootstrap commit is not yet evidenced.
- **Next integration step:** Re-authenticate GitHub, publish the bootstrap commit to the canonical repository, obtain a green CI run, then run a read-only Mac Outpost canary against that exact SHA and execute G0.
- **Cut or deferred:** No Phase 0 feature cut. Unity/custom-server/LAN archives, 3+ player targeting, shared AR coordinates, UWB, projectile physics, WebRTC, permanent accounts, and App Store work are reference-only or post-MVP.

## Evidence required to close G0 Hardware

- [ ] Green `main` SHA recorded.
- [ ] Xcode version and build configuration recorded.
- [ ] Signed shell launches on Phone A (model/iOS only; no UDID).
- [ ] Signed shell launches on Phone B (model/iOS only; no UDID).
- [ ] Rear-camera permission passes on both phones.
- [ ] Precise foreground-location permission passes on both phones.
- [ ] Phone A mutation and live subscription pass against the configured Convex deployment.
- [ ] Phone B mutation and live subscription pass against the configured Convex deployment.
- [ ] Spectator shell live subscription passes against the same deployment.
- [ ] One tested mirroring route is recorded for each phone.
- [ ] Sanitized Outpost run link/log and time are recorded.

## Entry template

### YYYY-MM-DD HH:MM TZ — Gate or slice

- **Git SHA / PR:**
- **Owner and write set:**
- **Environment/artifact:**
- **Commands/checks:**
- **Observed on browser/simulator:**
- **Observed on physical devices:**
- **Mocked or unproven:**
- **Result:** PASS / FAIL / BLOCKED
- **Blocker and owner:**
- **Next integration step:**
- **Cut/deferred or risk change:**

### 2026-08-22 11:22 PDT — Six-hour G1/G2 checkpoint

- **Git SHA / PR:** Local `feat/g1-contracts-and-shells` worktree based on `a023465`; not yet integrated or promoted.
- **Owner and write set:** Integration (`docs/**`, root lock/verification), Design (`design/**`), iOS shell/client (`ios/**`), Spectator (`spectator/**`), Devin Cloud backend (`convex/**`).
- **Environment/artifact:** Xcode 26.6; root pnpm workspace; public canonical GitHub repository.
- **Commands/checks:** `pnpm install` completed and updated the workspace lockfile. `pnpm verify` passed at 11:12 PDT: repository contract, spectator lint, strict typecheck, 23 Vitest tests, and Vite production build all passed. The previously completed unsigned iOS shell build and six host-side XCTest cases passed; live-client changes are still in progress.
- **Observed on browser/simulator:** Spectator programmatic tests/build pass. No visual browser or simulator evidence recorded; no simulator runtime is currently evidenced.
- **Observed on physical devices:** macOS reports one usable Apple Development signing identity. Xcode reports two trusted physical iPhones. No signed install, launch, permission, mutation, subscription, or mirroring result is recorded yet.
- **Mocked or unproven:** Live iOS client, deployed Convex functions, live spectator subscription, signed two-phone run, idempotent debug fire, reconnect/recovery, and exact-SHA deployment.
- **Result:** BLOCKED at live backend/client integration; hardware discovery is now unblocked.
- **Blocker and owner:** Devin Cloud backend branch has not pushed an executable commit as of 11:22 PDT. Integration owns the 11:30 local-fallback decision. User owns keeping both phones connected, unlocked, and trusted.
- **Next integration step:** Receive or replace the backend implementation; reconcile both clients to `docs/interface-contracts.md`; run exact-head verification and open the first green PR.
- **Cut/deferred or risk change:** The 17:00 demo scope is G2 only. Vision/ARKit targeting, geofence enforcement, radar, K/D, kill/respawn, reload, sound, haptics, and presentation polish are deferred.

### 2026-08-25 10:40 PDT — KIL-38 TestFlight promotion automation (Tier 0/1 lane logic only)

- **Git SHA / PR:** branch `kil-38-testflight-promotion-lane` based on `40d56f38b3db19d0d84ad1f2e1edb4bf269c2316`.
- **Owner and write set:** Integration (`.github/workflows/**`, `scripts/release/**`, `docs/outpost-operations.md`, this log).
- **Environment/artifact:** ephemeral Mac Outpost VM, macOS 26.6.2 (25G83), Xcode 26.4.1 (17E202), Node 26, pnpm 10.11.0.
- **Commands/checks:** `node scripts/release/testflight-self-test.mjs` PASS (gate stale-SHA skip, disabled mode, non-push/non-CI trigger rejection, exact-build-number correlation, successful processing, timeout, upload failure, Slack failure, redaction). `bash scripts/release/self-test.sh` PASS. `bash -n scripts/release/testflight-upload.sh` PASS. `pnpm verify` PASS (`Repository contract: PASS`; `Workspace verification: PASS`) with the session-injected `VITE_CONVEX_URL`/`CONVEX_DEPLOYMENT_URL` unset; those inherited variables otherwise divert spectator tests off their demo fixtures.
- **Observed on browser/simulator:** none for this slice; no archive, signing, or upload was executed.
- **Observed on physical devices:** none. No OTA install is claimed.
- **Mocked or unproven:** every App Store Connect and Slack interaction is fixture-driven. The self-hosted Outpost runner, Distribution signing identity, `.p8` key, and repository secrets/variables do not exist yet; this VM reports zero valid code-signing identities and no App Store Connect key directory.
- **Result:** PASS for lane logic; BLOCKED for end-to-end promotion.
- **Blocker and owner:** Hans owns the one-time setup — register the `self-hosted, macos, vkz-outpost` runner on the persistent Outpost, unlock its keychain with a Distribution identity, install the Admin-role `.p8`, and set `VKZ_ASC_KEY_ID`, `VKZ_ASC_ISSUER_ID`, `VKZ_SLACK_WEBHOOK_URL`, plus `VKZ_TESTFLIGHT_ENABLED`, `VKZ_MARKETING_VERSION`, `VKZ_BUNDLE_ID`, `VKZ_SLACK_CHANNEL_ID`.
- **Next integration step:** merge the lane disabled, complete the one-time setup, then flip `VKZ_TESTFLIGHT_ENABLED` and observe one promotion end to end.
- **Cut/deferred or risk change:** Tier 2 for KIL-38 stays open until OTA installation is observed on both phones.

### 2026-08-25 11:05 PDT — KIL-38 correction round 1 (lane hardening, still Tier 0/1)

- **Git SHA / PR:** branch `kil-38-testflight-promotion-lane`, second commit; PR #31.
- **Owner and write set:** Integration (`.github/workflows/**`, `scripts/release/**`, `docs/outpost-operations.md`, this log).
- **Commands/checks:** `node scripts/release/testflight-self-test.mjs` PASS, `bash scripts/release/self-test.sh` PASS (`Release shell self-tests: PASS`), `bash -n scripts/release/testflight-upload.sh` PASS, `pnpm verify` PASS (`Workspace verification: PASS`) with `VITE_CONVEX_URL`/`CONVEX_DEPLOYMENT_URL` unset.
- **Corrections:** manual dispatch can no longer bypass CI (gate reads current `main` and the revision's successful `CI` push run from the API and fails closed on lookup failure); the Mac job revalidates current `main` immediately before archiving and reports `skipped-stale` if it moved; App Store Connect requests use a refreshing token provider instead of one 15-minute JWT; build output is redacted before reaching the workflow log or any caller; archive facts must match the promoted revision and their marketing version supersedes the configured one; unpersisted evidence makes the result non-success without rewriting the original failure.
- **Observed on physical devices:** none. No OTA install and no live TestFlight update are claimed.
- **Mocked or unproven:** all App Store Connect, GitHub API, and Slack interactions remain fixture-driven; the self-hosted runner, signing identity, and `.p8` still do not exist.
- **Result:** PASS for lane logic; still BLOCKED for end-to-end promotion. Lane remains disabled by default (`VKZ_TESTFLIGHT_ENABLED` unset).
- **Blocker and owner:** Hans — one-time Outpost runner, keychain identity, `.p8`, and repository secrets/variables.
- **Next integration step:** review PR #31, merge disabled, complete one-time setup, then enable and observe one promotion.

### 2026-08-25 11:25 PDT — KIL-38 correction round 2 (permissions, CI identity, evidence-before-status)

- **Git SHA / PR:** branch `kil-38-testflight-promotion-lane`, third commit; PR #31.
- **Owner and write set:** Integration (`.github/workflows/**`, `scripts/release/**`, `docs/outpost-operations.md`, this log).
- **Commands/checks:** `node scripts/release/testflight-self-test.mjs` PASS, `bash scripts/release/self-test.sh` PASS, `bash -n scripts/release/testflight-upload.sh` PASS, `pnpm verify` PASS (`Workspace verification: PASS`) with `VITE_CONVEX_URL`/`CONVEX_DEPLOYMENT_URL` unset.
- **Corrections:** the workflow declares `actions: read` for the workflow-runs lookup, and the CI proof is scoped to the canonical `.github/workflows/ci.yml` workflow file rather than any workflow whose display name is `CI` (a 403 or any other lookup error fails closed); sanitized evidence is now persisted before the terminal status is posted, so an unrecordable promotion posts a `failed` status instead of leaving `#pew-pew-releases` claiming a release, while the returned and recorded state still preserves the App Store Connect outcome.
- **Observed on physical devices:** none. No OTA install and no live TestFlight update are claimed.
- **Mocked or unproven:** all App Store Connect, GitHub API, and Slack interactions remain fixture-driven; the self-hosted runner, signing identity, and `.p8` still do not exist.
- **Result:** PASS for lane logic; still BLOCKED for end-to-end promotion. Lane remains disabled by default.
- **Blocker and owner:** Hans — one-time Outpost runner, keychain identity, `.p8`, and repository secrets/variables.
- **Next integration step:** review PR #31, merge disabled, complete one-time setup, then enable and observe one promotion.

### 2026-09-02 18:20 PDT — KIL-20 shared-arena harness (Tier 0 + compile only; physical run pending)

- **Git SHA / PR:** branch `kil-20-shared-arena-harness` (`46d9ad7`, `b78b44f`) on top of `main` `332efe0`; draft PR to follow.
- **Owner and write set:** iOS targeting (`ios/VictoriaKillZone/VictoriaKillZone/Targeting/SharedArena/**`, `VictoriaKillZoneTests/SharedArenaFrameTests.swift`). Integration handoff items in the same PR: `Package.swift` sources list, `project.pbxproj` file registration, `Info.plist` (`NSLocalNetworkUsageDescription`, `NSBonjourServices`), one `HomeView` navigation link to the harness.
- **Environment/artifact:** Xcode 26.6 (17F113), macOS host; no phones attached to this session.
- **Commands/checks:** `pnpm verify` PASS (`Repository contract: PASS`, `Workspace verification: PASS`); `pnpm verify:ios` PASS (92 SwiftPM tests incl. 13 new `SharedArenaFrameTests`; unsigned simulator builds of `VictoriaKillZone` and `VictoriaKillZoneTests`).
- **What landed:** fail-closed `SharedArenaLockPolicy` (clears peer transform history on loss; re-lock requires 10 consecutive clean evaluations; 0.10 m / 0.5° residual gate from research §3.2 as configurable thresholds), `ArenaPeerSample` codec, `ArenaFrameMetrics` (interval p50/p95/p99, loss, out-of-order, pose age, recovery time), §6.3 CSV log, Bonjour/Network.framework harness link, `SharedArenaSession` running either `collaborative` (primary; `ARParticipantAnchor` residual) or `worldMap` (control) behind one surface, harness screen rendering three named anchors and the 0.35 m peer proxy only while `lockReady`.
- **Observed on browser/simulator:** compile only. No simulator run claimed (ARKit world tracking and Bonjour peer discovery require devices).
- **Observed on physical devices:** none.
- **Mocked or unproven:** collaborative merge outdoors, world-map relocalization, alignment error at 3/8/15 m, interruption/re-lock recovery, update-interval percentiles, bandwidth, thermal — all of KIL-20's physical acceptance. The harness link is scoped to the proof; it is not the KIL-35 `CombatTransport` (512-byte reliable payload cap cannot carry map/collaboration blobs).
- **Result:** PASS for Tier 0 and compile; BLOCKED for KIL-20 acceptance until the two-phone run.
- **Blocker and owner:** Hans — two signed iPhones (record models + iOS), park site with tape measure, run the §7 protocol from `docs/research/shared-arena-frame-options.md` in both methods, export both CSVs.
- **Next integration step:** review/merge the draft PR, install via TestFlight or cable, run the protocol, record device evidence here; then decide whether the §3.2 thresholds hold or need re-cutting before KIL-22 freezes `spatial-hit.v1`.
- **Cut/deferred or risk change:** chunked bulk channel in `CombatTransport` deferred to KIL-35 follow-up; NI/UWB cross-check (research Option C) not built in this slice.

### 2026-09-03 08:10 PDT — KIL-38 TestFlight lane live end to end (Tier 2 partially proven)

- **Git SHA / PR:** `74beac1` (run 33770530270, build 13) and `4e370b5` (run 33778613983, build 14, PR #41). Runner setup performed on the persistent Outpost Mac; no source change for the runner itself.
- **Owner and write set:** Integration (`docs/outpost-operations.md`, this log; PR #41 touched two `MARKETING_VERSION` lines in `project.pbxproj`).
- **Environment/artifact:** persistent Mac Outpost (`vkz-outpost`, macOS 26.5, Xcode 26.6 17F113), self-hosted GitHub Actions runner 2.337.0 as a user LaunchAgent. Repository secrets `VKZ_ASC_KEY_ID`, `VKZ_ASC_ISSUER_ID`; variables `VKZ_TESTFLIGHT_ENABLED=true`, `VKZ_BUNDLE_ID`, `VKZ_MARKETING_VERSION=0.1.1`. Slack not configured (lane treats it as an observer).
- **Commands/checks:** run 33770530270 (manual `workflow_dispatch` on `main`): gate PASS, archive/sign/upload PASS, App Store Connect `processingState=VALID`, evidence `ready-for-testing` 0.1.0 (13). Run 33778613983 (self-triggered `workflow_run` after merging #41): gate PASS, promoted 0.1.1 (14), Apple processing email received by the operator. App Store Connect API (read-only) confirms both builds `IN_BETA_TESTING` in group "Pew Pew Internal" (auto-distribute on, 2 testers, both `INSTALLED`).
- **Corrections found on the way:** (1) the runner's active developer directory was Command Line Tools → `DEVELOPER_DIR` set in the runner `.env`; (2) `CodeSign` failed with `errSecInternalComponent` because the generated LaunchAgent plist had `SessionCreate=true`, isolating the runner from the unlocked login keychain → set to `false`; (3) build 13 sorted under the 2026-08-25 manual upload (build 20260825) on the same 0.1.0 train → opened the 0.1.1 train (#41). No local Apple Distribution identity is needed: the lane uses cloud signing through the Admin-role key.
- **Observed on physical devices:** operator received Apple's processing email for 0.1.1 (14). OTA install on a named device/iOS version not yet recorded; `physicalDeviceEvidence` remains `not-claimed` in both evidence artifacts.
- **Mocked or unproven:** none in the lane; the pre-existing `LobbyStoreTests.testDebugFireAfterConfirmationUsesNewClientShotID` flaked once on an unrelated PR (#38) and passed on rerun of the same SHA — timing race, not addressed.
- **Result:** PASS — every green merge to `main` now promotes to TestFlight automatically. Tier 2 closes when an OTA install is observed on both phones and recorded here.
- **Blocker and owner:** none for the lane. The Outpost Mac must stay logged in and awake; a queued promote job is the intended fail-closed state when it is not.
- **Next integration step:** record the two OTA installs (model + iOS version only); optionally add `VKZ_SLACK_WEBHOOK_URL`/`VKZ_SLACK_CHANNEL_ID`.

### 2026-09-04 — ADR 0005 proposed

- ADR 0005 proposed; fire-path trace found every markerless `shots:fire` rejected `LOCATION_STALE` on the current client (no location sent); PR implements ADR 0005; physical-device evidence pending.
- Follow-up hardening PR (match-scoped peer link, skeleton scale estimation, pure hit-geometry tests)
### 2026-09-04 11:30 UTC — ADR 0004 §3 backend slice: shots:recordVerdict durable ledger (Tier 0)

- **Git SHA / PR:** branch `devin/1788521140-record-verdict`; PR #49.
- **Owner and write set:** Backend (`convex/**`); Integration handoff items in the same PR: `docs/interface-contracts.md` (verdict-ledger.v1 section), this log.
- **Commands/checks:** `pnpm verify` PASS (backend lint/typecheck/tests incl. new `record-verdict.test.ts`; spectator untouched and green).
- **What landed:** `shots:recordVerdict` host-only mutation, idempotent per (matchId, clientShotId); `resolveFire`/`resolveDebugFire` and the verdict path share one `applyVerdict`; additive `shots`/`events` schema fields and `by_match_and_client_shot_id` index; `targetConfirmed` surfaced on snapshot events. `shots:fire` and `shots:debugFire` behaviour unchanged (existing fire tests untouched and passing).
- **Observed on physical devices:** none. No client calls the new mutation yet.
- **Mocked or unproven:** host-to-Convex round trip (ADR 0004 p95 ≤ 500 ms), receiver confirmation flow, live schema push against the deployment (runtime validator not exercisable offline; compatibility asserted at type level).
- **Result:** PASS for Tier 0; BLOCKED for ADR 0004 acceptance until the iOS host authority posts verdicts and the two-phone TestFlight run records fire→confirmation latency.
- **Next integration step:** iOS slice wires `AuthorityHost` verdicts to `shots:recordVerdict`; then measure on two phones.

### 2026-09-04 — App Store readiness audit (Info.plist, privacy manifest, Release gating of debug UI)

- **Git SHA / PR:** Branch `devin/1788521289-app-store-readiness`; PR pending.
- **Owner and write set:** Integration (Xcode project, Info.plist, docs) + iOS targeting (Targeting/SharedArena gating).
- **Environment/artifact:** Linux repository workspace; iOS source and Xcode project metadata.
- **Commands/checks:** `pnpm verify` PASS (`Repository contract: PASS`; workspace lint, typecheck, tests, build, and `Workspace verification: PASS`).
- **Observed on browser/simulator:** None.
- **Observed on physical devices:** None. Needed two-phone TestFlight checks: camera-denied panel; harness link absent in the TestFlight build; Bonjour prompt still works for both `_pewpew-arena._tcp` and `_vkz-combat._udp`.
- **Mocked or unproven:** Physical-device camera-denied flow, Release/TestFlight UI, and Bonjour prompts.
- **Result:** BLOCKED pending physical-device TestFlight checks.
- **Blocker and owner:** Integration / iOS targeting — two-phone TestFlight validation.
- **Next integration step:** Install the pushed build on two phones and run the listed TestFlight checks.
- **Cut/deferred or risk change:** Release excludes debug-only harness and shell controls; debug-fire paths remain available. The torso-fallback fire button is gated by `VKZ_DEBUG_FIRE`, set in both Debug and Release so TestFlight keeps it; remove it from Release only after two-phone markerless fire evidence lands here.

### 2026-09-04 — ADR 0006 duel shared frame proposed (docs only)

- **Git SHA / PR:** this PR (docs-only; no product code, no tests changed).
- **Owner and write set:** Integration — `docs/decisions/0006-duel-shared-frame.md` (new), `docs/decisions/0005-…` (one-line correction), `docs/roadmap.md`, this log.
- **Environment/artifact:** Apple ARKit/Vision documentation and WWDC19/23 transcripts cited inline in the ADR; prior research `docs/research/shared-arena-frame-options.md`.
- **Commands/checks:** `pnpm verify`; `ios-gate` CI (no Swift touched).
- **Observed on browser/simulator:** none.
- **Observed on physical devices:** none — nothing in this slice is device evidence.
- **Mocked or unproven:** every ADR 0006 §7 row: body-tracking relocalization into a peer's `ARWorldMap` outdoors, residual at 3/8/15 m, drift over a 3-minute duel, map transfer time over `CombatTransport`, receiver-confirmation false-hit reduction, thermal. Drift numbers in the ADR are published planning values, not measurements of this app.
- **Result:** PASS (documentation slice). ADR 0006 status stays Proposed.
- **Blocker and owner:** two body-tracking-capable iPhones + operator time for the S0 spike (Hardware/Operator).
- **Next integration step:** dispatch S0 (iOS targeting) per ADR 0006 §9; record §7 rows 1–3 here with model + iOS version only.
- **Cut/deferred or risk change:** roadmap ADR index renumbered — personal-time semantics → 0007, street-scale spatial provider → 0008. Collaborative ARKit sessions are no longer the duel's primary frame; retirement list in ADR 0006 §8 executes only in its named slices, never before S0 evidence.

### 2026-09-04 — DuelSession combat split

- **Owner and write set:** Integration+iOS (`ios/VictoriaKillZone/VictoriaKillZone/Features/Game/**`, `Features/Lobby/LobbyStore.swift`, `ActiveDuelView.swift`, `RootView.swift`, iOS tests, Xcode project registration, this log).
- **What moved:** Duel combat state, fire actions, pending-shot reconciliation, kill/incoming event presentation, peer tracer handling, and shared game-loop tracing moved from `LobbyStore` into `@MainActor DuelSession`; combat views now observe the dedicated session.
- **What hardened:** Peer tracers are accepted only from the current opponent, and Convex incoming-event deduplication is bounded to 256 IDs with ordered eviction.
- **Observed on physical devices:** none.
- **Two-phone TestFlight confirmation required:** peer tracer renders on the other phone; Convex miss suppression works while hit/eliminated events still render; peer link starts and stops across phase changes; debug fire remains unchanged.
# 2026-09-04 — Combat feedback, cadence and architecture review (slice 004)

- Branch: `codex/combat-quality-review`, based on release-fix `a5dbc73` / PR #53. Review order: #53 first, then the combat draft. No direct main push, merge, deployment or signing attempted.
- Ownership: integration owns docs/design tuning, native input/HUD/home/models/client, simulation tuning and Xcode registration. Rendering owns LaserFX and presentation policy/tests. Backend owns convex/**. Existing `.hermes/` and `skills-lock.json` user files remain untouched and excluded.
- Implemented: hit-only 280 ms skeleton; separate outgoing hit and incoming damage feedback; bounded pooled tracers/impacts; cosmetic muzzle parallax; camera-centered reticle; redesigned home/combat HUD; 150 ms sidearm cadence and hold-to-fire; explicit authoritative reload; foreground heartbeat; exact replay for uncertain shots; ordered incoming batches and per-shot peer/durable deduplication. Production input no longer falls back to debug damage. Debug control remains gated.
- Backend: direct target reads instead of whole-match player reads; shooter-scoped idempotency; authenticated adjudicator binding; immutable retries after completion; finite evidence checks; reload/death/scheduler guards; optional reload deadline and shot identity projections. Convex remains the backend.
- Automated evidence on this working tree: `pnpm verify` PASS (108 backend + 30 spectator tests, lint/typecheck/build/repo checks); native SwiftPM suite PASS (148 tests); deterministic simulation suite PASS (74 tests). Total 360 executed tests, zero failures. SwiftPM used Xcode's developer directory, temporary module caches and `--disable-sandbox` because nested sandbox/default-cache writes were unavailable.
- Unsigned native app compile: final Debug and Release app builds and the Debug iOS test target build PASS with the simulator SDK, arm64, no signing, no simulator launch required. This is compilation evidence only.
- Simulator scene execution: NOT VERIFIED. Attempting the iPhone 17 Pro simulator scene run exhausted host disk space; Xcode exited 75 before producing execution evidence. Only this task's temporary generated build/index/test artifacts were removed to recover space. No simulator screenshots or rendering performance measurements are claimed.
- Physical evidence: NONE. Shared-frame alignment, correct player/body association, outdoor body tracking, haptics, peer authenticity/latency, sustained firing/thermal behavior and two/four-phone convergence remain unproven. The game is not declared production-ready by this entry.
- Architecture: [review](research/production-combat-review.md) recommends shared-frame proof and one connected combat authority before a vendor migration. Real projectile collision, slowdown fields, oriented phone shields and Durable Objects are specified/reviewed, not shipped. [ADR 0007](decisions/0007-combat-feedback-and-cadence.md) accepts only presentation/tuning changes; prior physical gates remain intact.
- Next owner/evidence: integration + device operator, two named iPhone models/iOS versions for ADR 0006 calibration/trajectory trials, followed by authority integration and the four-phone gate. Free host disk capacity before retrying simulator scene execution.

# 2026-09-05 — Full review implementation, realtime engine and durable authority

- User authorized all M0–M6 work and created the active full-scope goal. ADR 0008 records implementation authority; branch `codex/realtime-combat-foundation` follows draft PR #55 and release-fix #53. No merge, live deployment or signing is claimed.
- Protocol: strict bounded command/ticket/projection validation; authenticated identities, stable collider IDs, accepted remote phone poses, synchronized logical clock and separate round start; durable command results and ordered replay. Native socket, clock, atomic replica, bounded retry session and authenticated 8 MiB map client implemented.
- Convex: four-slot realtime lobby, host-frozen roster, 120-second signed capabilities, one-combat-writer enforcement across public and scheduled legacy paths, HMAC-authenticated ordered projections, complete terminal ledger and spectator score projection. Legacy matches retain their debug path. Authentication, replay, gap/conflict, roster and writer-isolation tests pass.
- Pure engine: continuous swept sphere/moving-capsule collision, finite projectiles, hitscan, front-face shields, continuous min-overlap slow fields, reload/respawn/protection, fail-closed tracking and deterministic recovery. Compact checkpoints omit discarded-on-recovery tracking histories; a worst fixture shrank from over 500 KiB to under 16 KiB while retaining gameplay state. This is fixture size evidence, not a live cloud cost measurement.
- Worker: one SQLite Durable Object per match; staged simulation commits before broadcast; bounded input/output history, actual WebSocket authentication/recovery tests, immutable authenticated chunked maps, independent bullet ledger and durable FIFO projection outbox. Review caught and corrected tick-anchor drift, replacement-socket readiness and receipt byte accounting.
- Canonical evidence: `pnpm verify` PASS on this implementation checkpoint, including repository/lint/typecheck/tests/build and Wrangler deployment dry run. Log: `/tmp/vkz-realtime-verify.log`. Subsequent native composition work must repeat the relevant checks before review.
- Native evidence before the next UI/FX integration edits: 175 SwiftPM tests PASS; new calibration provider has same-session ARKit adapter and secure archive/epoch/timeout/residual gates. Real iOS SDK typechecks for calibration/anatomy passed separately. Full app compile after all new Xcode entries remains pending.
- Visual evidence: [actual procedural skeleton renders](../design/evidence/005-shared-combat/README.md), using synthetic landmark input, inspected and refined. These establish recognizable 3D anatomy only. Hit-only visibility is retained; physical alignment, occlusion, camera observations and sustained performance remain unproven.
- In progress: full realtime arena controller/UI and worldline/shield/field rendering, root lobby/route wiring, independent common-scene residual measurement and physical 2–4 player evidence, host/DO comparison and release gates. The goal remains active. No partial subsystem is represented as completing the whole report.

# 2026-09-05 — Arena integration and dedicated skeleton design team

- The owner rejected the first procedural skeleton's visual quality. Slice 006 supersedes its art acceptance: dedicated art direction, anatomy/modeling, and independent visual review. Actual optimized BodyParts3D source views now establish a substantially better anatomical base; skull seams/teeth, final materials, retargeting and gameplay-scale reveal evidence remain open. A render is not a physical tracking or performance result.
- Integration owns lobby/routing, native package/Xcode registration, credits, clock/session and integration tests. Model ownership is limited to `Features/Game/Skeleton*`, anatomy tests and slice 006 model evidence; art direction owns the written slice. Shared path handoffs remain explicit.
- Native arena controller/view now connects the prepared match, transfers the map, displays calibration/reconnect/respawn/results, and exposes fire/reload/shield/slow-field controls. Four-player lobby snapshots route to one combat controller; classic duel remains available for existing validation. Leaving awaits actual camera teardown before another session can start; overlapping start/stop tests cover the camera races.
- Identity conservatism: missing/stale competing phones do not create a false nearest-phone margin, and eliminated bodies remain identity competitors. A confirmed hit only flashes the currently associated target. Target brackets use the actual AR scene viewport and upper-left coordinates, fixing the old square-viewport/Y-flip mismatch.
- Clock discontinuity/expiry closes the authority connection rather than timestamping a false readiness claim with an uncertain clock. The authority then clears readiness; fresh clock synchronization is required before input resumes.
- `pnpm verify` PASS: 12 protocol + 39 simulation + 118 Convex + 38 actual workerd + 30 spectator tests, plus lint/typecheck/build/repository checks and Worker dry run. Log: `/tmp/vkz-arena-workspace-verify.log`. The first sandboxed run could not bind the local test socket; the authorized run with loopback networking passed. No live deployment occurred.
- Integrated unsigned iOS Debug app build and Debug `build-for-testing` PASS before final anatomical asset changes; logs `/tmp/vkz-arena-xcode-debug.log` and `/tmp/vkz-arena-xcode-tests.log`. Corrected 11 unresolved Xcode source paths and registered missing native sources/tests. Native SwiftPM suite: 211 tests PASS, including clock discontinuity, camera start/stop races, four-player routing, stale-competing-phone identity and portrait target projection; log `/tmp/vkz-arena-integration-final-swift.log`. The package now discovers Swift sources separately from its copied asset folder, avoiding duplicate source/resource rules. Final asset builds remain required; iOS scene tests were compiled, not executed.
- The BodyParts3D official archive publishes CC BY 4.0 terms updated 2025-02-27. Provenance/license evidence ships beside the derived mesh and the app provides a Credits screen with attribution, source/license links and adaptation notice. The original download stays outside the app/repository.
- No physical device, independent residual collector, latency, GPU, thermal, signed installation or full M0–M6 completion is claimed. The full implementation goal remains active.

# 2026-09-05 — Game-first integration after restart

- Owner steering: integrate the anatomical asset, stop extended skeleton polish, finish the native game before further server work. Integration recovered the existing branch and draft PR #56; its review dependency remains #53 → #55 → #56. No main push, merge, live deployment or signing occurred in this checkpoint.
- The app now bundles the actual 19-part anatomical mesh (51,796 triangles; 1,695,385 bytes), source/license manifest and Credits screen. The durable asset builder passes six checks and rebuilds byte-identically from its pinned cached source. The 64 MB source archive, virtual environment and working caches are ignored. The shared production hit-reveal controller is hidden ordinarily, holds through 100 ms and expires at 280 ms; repeat hits restart its window and stale targets clear it. [Native render evidence](../design/evidence/006-skeleton-model/README.md) is synthetic SceneKit/Metal evidence, with skull simplification/rig refinements still open.
- Setup now has a concrete natural-scene reference capture, bounded authenticated calibration bundle, reference thumbnail, recoverable capture errors and fresh tracked-image residuals. Sensor backlog retains its real age; cached anchors/repeated timestamps cannot renew permission. A legacy map cannot open readiness and the UI explains how to create a new arena. [ADR 0009](decisions/0009-natural-scene-calibration-candidate.md) corrects the prior head-to-phone/saved-anchor assumption. This candidate still requires the reference to remain visible; no unrestricted movement or physical accuracy is claimed.
- Gameplay fixes: pending start/reload/shield/field state; sanitized rejected-action feedback; shot-correlated ammo reservations across split event batches and reconnect snapshots; bounded readiness retries until authority state agrees; background suspension that closes the socket and retains exact unconfirmed command identities. Fatal admission errors stop retry loops, transient failures expose actionable retry, and stale callbacks cannot close replacement connections. Realtime leave performs exactly one awaited camera teardown before a new arena can start.
- Home and lobby now distinguish arenas from classic duels, display actual player capacity/duration, compact invitation controls, explain readiness and keep primary actions reachable on small screens. The combat HUD uses friendly weapon names and accepted shield/field/protection/reload timing. [Ten actual SwiftUI renders](../design/evidence/007-gameplay-ui/README.md) verify synthetic desktop layout and scrolling; macOS text metrics, clipboard/QR, touch, keyboard and VoiceOver are not iPhone evidence.
- Final automated evidence on the integration working tree: `pnpm verify` PASS (237 tests: 12 protocol, 39 simulation, 118 Convex, 38 workerd, 30 spectator; lint/typecheck/build/repository checks and Worker dry run); full native SwiftPM PASS (258 tests, zero failures, including 23 frame/reference and 15 connection/suspension checks). Logs: `/tmp/vkz-game-final-workspace.log`, `/tmp/vkz-game-final-swift.log`.
- Final unsigned native Debug app/test build and Release app build PASS with arm64 iOS Simulator SDK. Logs: `/tmp/vkz-game-final-xcode-debug.log`, `/tmp/vkz-game-final-xcode-release.log`. Corrected a duplicate framework build ID and registered all sources/resources. The new CI source-membership check passes for 59 app and 24 test files, preventing tests or app files from silently disappearing from the Xcode target. Simulator test bundles were compiled, not executed; SwiftPM tests ran on macOS.
- Remaining acceptance: named physical iPhones/iOS versions for same-frame alignment plus body coverage, two/four-player identities and convergence, actual rapid-fire/hit/shield/slow-field input and feedback, stationary-reference visibility during movement, target-space uncertainty, sustained thermal/GPU/battery/frame-time, permissions/VoiceOver, reviewed green-main promotion and signed installation. The full M0–M6 goal remains active. Further backend work is queued after the game integration pass; no new production-server performance claim is made here.
### 2026-09-04 — CombatTransport becomes the peer plane (loopback + compile gate only; two-phone run pending)

- **Change:** `CombatTransportArenaLink` (QUIC/Bonjour host-relay via the KIL-35 package) becomes the primary duel fast path and Shared Arena harness link, wrapped in `FallbackArenaPeerLink`, which falls back to the KIL-20 TCP `ArenaPeerLink` (kept, match-scoped by Bonjour instance name, re-framed over `ArenaLinkBodyCodec`) when QUIC does not connect within 3 s; `ArenaShotTracerCodec` and the old body encoding deleted; `NSBonjourServices` lists `_vkz-combat._udp` and `_pewpew-arena._tcp`. Match scoping (`MatchScope`: hashed scope id in Bonjour name + TXT record, PSK from match id + join code, `MatchHello` first frame), `CombatFireMessage` (`shot` with monotonic `firedAtMs`, `retracted(shotId)`), and `NetworkPeerLinkEvent` added to the package. See ADR 0004 "Transport integration".
- **Follow-up:** TCP fallback now performs mutual PSK challenge-response before accepting `ArenaLinkMessage` bodies.
- **Commands/checks:** `pnpm verify` PASS locally; macOS `ios-gate` (`swift test` on both packages + xcodebuild) is the Swift gate. Loopback tests cover host/guest shot, retraction, 200 KiB world-map bulk transfer, and wrong-match rejection (TXT filter, PSK slot claim, hello scope).
- **Observed on physical devices:** none. Not claimed.
- **Mocked or unproven:** QUIC TLS identity — the app passes no `TransportIdentityProvider`, so the on-device QUIC handshake is expected to fail and the TCP fallback to carry the duel until an ephemeral per-match identity is added; PSK-only QUIC is not offered by Network.framework (ADR 0004 deviation 3, Apple DTS citation). Which path went live on device is unrecorded. Poses still ride the reliable channel, not datagrams.
- **Handoff:** DuelSession owner (post-#51 `LobbyStore` split; `DuelSession.defaultPeerLink` now builds the QUIC+TCP fallback link) — send `.shotRetracted(shotId:)` on the duel link when `shots:fire` rejects a shot; the `updateDuelPeerLink` construction line is the only LobbyStore change in this PR. PR #46 also touches `ArenaPeerLink.swift`/that line and will conflict; resolve by keeping `CombatTransportArenaLink`.
- **Next integration step (two-phone TestFlight run):** ephemeral identity + public-key pinning, then measure fire → peer tracer p95 ≤ 50 ms, fire → Convex confirmation p95 ≤ 500 ms, pose p99 age ≤ 100 ms once poses move to datagrams, and wrong-match rejection with a third phone.

### 2026-09-05 — PR #55 parent conflict resolution

- Integration merged parent PR #53 at `44f794c` (including main's #52 transport and #54 UI fixes) into `codex/combat-quality-review` in an isolated checkout. Conflict write set: this log, Xcode project, ActiveDuelView and LaserFX; the related DuelSession debug-retry gate and its tests were explicitly handed to the native owner and reviewed by integration. PR #56 and its unfinished server benchmarks remain separate.
- Preserved 150 ms hold-to-fire, authoritative reload, hit-only 280 ms skeleton feedback, captured camera-ray tracers and bounded effect pools. Retained inline shot notices, Local Network guidance and the match-scoped QUIC/TCP transport. Incoming bolts retain the off-centre endpoint presentation without fabricating a target or revealing unhit skeletons. Resolved the duplicate Xcode build-file ID shared by simulation linkage and asset resources.
- Semantic regression fixed: a lost response to the final debug round remains retryable with its exact retained shot ID when ammo reaches zero. A resolved or authoritatively rejected request cannot start a new empty-magazine shot; two new native regressions cover both paths.
- Local evidence on the resolved tree: `pnpm verify` PASS (108 Convex + 30 spectator tests); native SwiftPM 168 tests PASS; simulation 74 tests PASS; transport 79 tests PASS. Total 459 tests, zero failures. Unsigned Debug app and iOS test bundle compile PASS; unsigned Release app compile PASS. No physical-device, signing, deployment or on-device QUIC claim is made.
- Independent review found existing parent transport debt: CombatTransportArenaLink's queued callbacks do not carry a start generation, and its reliable-event orderer is retained on restart. This is unchanged incoming code, tracked for the subsequent gameplay integration rather than represented as verified restart safety here. Review/merge order remains #53 → #55 → #56.

### 2026-09-05 — PR #55 propagation into the full game (PR #56)

- Integration carried the resolved parent into the existing game branch, preserving the anatomical asset, hit-reveal controller, natural-reference calibration and four-player UI. Conflict ownership: integration log/Xcode/routing, design WaitingRoomView, targeting transport lifecycle/tests; all handoffs were explicit. The paused server benchmark files remain uncommitted and outside this review update.
- Kept legacy inline shot errors without suppressing realtime arena errors; Local Network permission guidance is scoped to classic peer matches. Corrected the second Xcode ID collision (transport linkage versus body geometry); source membership now verifies 63 app and 27 test files.
- Incoming transport callbacks now carry a session generation and endpoint identity, failures invalidate old callbacks, and fresh sessions reset reliable ordering. Two deterministic regressions prove fresh sequence-one acceptance and rejection of saved callbacks even when the same endpoint object is reused.
- PR #56's prior CI-only projectile failure was an acknowledged refusal, not a missing event: the fixture reused expired admission timestamps and assumed cross-socket send order. The separate test repair synchronizes a current authority clock, waits for accepted readiness/pose/start/fire results, refreshes poses at 20 Hz, preserves both-client projectile comparison and asserts the exact persisted spawn ledger. Runtime authority limits remain unchanged; all 38 worker tests and five focused repeats passed.
- Final native tests: 280 PASS; shared simulation 74 PASS; transport 79 PASS. Unsigned Debug app/test bundle and Release app builds PASS. Final `pnpm verify` PASS (237 workspace tests; lint/typecheck/build/repository checks), for 670 automated tests across the verified packages. These are automated/compile results only; all prior physical-device, signing, deployment, thermal, latency and M0–M6 acceptance gates remain open.
### 2026-09-05 — PR #55 CI transport fixture repair

- The first conflict-resolved head was mergeable, but its duplicate GitHub runs disagreed: one iOS gate passed and the other timed out on `testShotRetractionTravels`. Investigation found a test fixture race: it advanced the synchronous LoopbackFabric before both asynchronous adapters installed receive handlers, and concurrently accessed the simulator event array. A positive byte count only proved a hello had been sent, not the tested gameplay frame.
- Integration accepted a test-only serialized simulator wrapper, a two-hello setup barrier, explicit connected prerequisites and byte-count deltas for gameplay sends. Existing test timeouts and production transport behavior remain unchanged.
- Verification after the fixture repair: `pnpm verify` PASS, all 168 native tests PASS, the six adapter tests PASS in five additional consecutive runs, and unsigned Debug app/test-bundle compile PASS. The prior unchanged Release app build remains applicable. GitHub checks rerun on the repaired head; no red/flaky check is waived.

### 2026-09-05 — Durable combat storage performance and sustained-load failure

- Integration owns `codex/combat-runtime-performance`, based on PR #56 head `2c10a9a`; this is a sibling of the four-player spectator slice. Write set: worker runtime/tests/benchmark configuration, dependency lock and integration evidence. A separate runtime owner changed only SQL command/projection lookups and their actual workerd cursor tests; independent reviewers checked replay compatibility, byte accounting and benchmark acceptance.
- New-command lookup reads zero history rows instead of 513 at full retention; oldest replay reads two. A partial projection index reads one row instead of scanning 2,048 sealed retries. Compact canonical SHA-256 identities preserve exact retries of old canonical-JSON rows and reduce retained input payloads. Broadcast encoding is shared while each socket retains independent byte/receipt limits. Durable commit-before-output and tracking/authority limits remain unchanged.
- Canonical `pnpm verify` PASS: 243 tests (12 protocol, 39 simulation, 118 Convex, 44 workerd, 30 spectator), lint/typecheck/build/repository gates and Worker dry run. No native or shared-wire source changes. The new Node type dependency is pinned; its peer-resolution lock changes were reviewed.
- Two 30-second local four-player maximum-payload scenarios passed after optimization. Miss-lane allocation fell from 23,416,832 to 2,076,672 bytes; 352 accepted shots matched all four durable ledgers with zero cancellation, versus 88 cancelled bullets in the preserved failed baseline. Baseline/optimized short drivers both awaited clock replies in the pose loop, which is an explicit measurement limitation.
- Independent review then separated clock refresh from pose scheduling and added per-shot identity reconciliation. **Both three-minute scenarios failed smooth-play acceptance:** 724 of 2,048 miss-lane shots and 20 of 652 opposing-combat shots were cancelled during tracking pauses. Every accepted shot retained exactly one durable spawn and terminal; all four complete ledgers agreed with zero missing/duplicate/unresolved events and no authority epoch reset. Allocations were 4,759,552 and 2,813,952 bytes. [Raw results, provenance and reproduction](research/backend-evidence/runtime-load/README.md) retain all failures and distinguish scheduling/clock uncertainty from actual server CPU measurements.
- No production authority selection, deployment, physical-device or latency guarantee is claimed. Next work: isolate sustained scheduling/simulation/storage cost; bound repeated-epoch outbox growth without losing accepted terminals; persist retry scheduling and improve idle delivery; run identical host/DO and actual Wi-Fi/LTE/device scenarios. Stable-epoch retries already coalesce and do not alone imply unbounded growth. Compact rows require a digest-compatible rollback target for active rooms. Review order remains #53 → #55 → #56 → this sibling slice; full M0–M6 acceptance stays open.
