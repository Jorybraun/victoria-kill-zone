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
