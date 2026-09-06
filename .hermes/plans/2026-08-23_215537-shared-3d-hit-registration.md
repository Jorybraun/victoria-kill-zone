# Shared 3D Hit Registration Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Replace PEW PEW's shooter-submitted 2D hit claim with a measured shared-3D phone-proxy hitscan foundation, then use that foundation for persistent projectiles and personal time.

**Architecture:** ARKit and nearby peer networking form the high-frequency local spatial plane; a designated host retains timestamped phone-transform history and produces a provisional bounded-rewind verdict. Convex remains the durable authority for identity, rules, idempotency, ammo, damage, score, projectile spawn/terminal records, and spectator snapshots. Clients render immediately and reconcile to Convex; Convex never runs the 60 fps frame loop.

**Tech Stack:** Swift 6, SwiftUI, ARKit, SceneKit, MultipeerConnectivity/Network framework, simd, Convex TypeScript, React, TypeScript, Vite, Vitest.

**Linear control plane:** Parent `KIL-17`; planning/prototype children `KIL-18` through `KIL-22` in `Victoria Kill Zone — Demo Candidate`.

---

## Current state

- Current local branch is `codex/pew-pew-concept-site` at `9ed003a`, one commit ahead of `origin/main` (`d639f04`).
- This feature must start from the latest green `main`, not from the concept-site branch.
- The current iOS effect creates a local SceneKit sphere/beam from the AR camera transform.
- `shots:fire` accepts optional origin/direction but Convex does not persist or intersect them.
- Damage is currently resolved immediately from target ID, 2D Vision zone, and confidence.
- There is no shared AR world, peer transform history, clock correlation, phone proxy, rewind evaluator, persistent projectile, or spectator spatial grid.
- `docs/research/shared-ar-hit-registration.md` contains the research basis but is currently untracked and must land through a reviewed docs PR.
- The canonical gate is `pnpm verify`; iOS/device work also requires `pnpm verify:ios` and physical-device evidence.

## Non-negotiable invariants

1. One canonical right-handed, metre-based `Shared Arena Frame`.
2. One canonical `arenaFromPhone` transform per pose sample; derive the inverse.
3. Points use homogeneous `w=1`; directions use `w=0`.
4. Shot origin, direction, pose sequence, and monotonic timestamp come from one AR frame.
5. Never trust unbounded client wall-clock timestamps.
6. Tracking failure or stale history fails closed.
7. Local peer networking owns high-frequency transforms; Convex owns durable state transitions.
8. No exact geographic coordinates in public spectator state.
9. Current debug fire remains until new physical evidence proves its replacement.
10. Personal time begins only after normal-time persistent projectile collision passes.

## Linear dependency graph

```text
KIL-17 Shared 3D hit registration and persistent projectiles
  |
  +-- KIL-18 Requirements, vocabulary, design states
          |
          +-- KIL-19 Deterministic transforms and rewind prototype
                  |
                  +-- KIL-20 Two-iPhone shared arena and phone proxies
                          |
                          +-- KIL-21 Latency measurement and authority ADR
                                  |
                                  +-- KIL-22 Freeze spatial-hit.v1
                                          |
                                          +-- implementation issues created only here
```

No planning issue has a Devin delegate or Devin playbook label. `devin-ready` may be added only by KIL-22 after contracts and write boundaries freeze.

---

### Task 1: Land the research baseline

**Linear:** supports KIL-18

**Objective:** Put the cited research in version control from a clean branch based on current `main`.

**Files:**
- Create: `docs/research/shared-ar-hit-registration.md`
- Modify: `docs/build-log.md` only to record the docs-only outcome if required by Integration

**Steps:**

1. Save or move the current untracked research draft out of the concept branch without losing it.
2. Create a short-lived docs branch from latest green `main`.
3. Restore only `docs/research/shared-ar-hit-registration.md`.
4. Re-run citation verification.
5. Run `pnpm verify`.
6. Open a focused draft PR and link it to KIL-18.
7. Review for unsupported Call of Duty claims; retain the explicit statement that Activision's exact production algorithm is not publicly documented.
8. Merge only after CI is green.

**Verification:**

```sh
python3 ~/.hermes/skills/research/grounded-citations/scripts/sources.py verify docs/research/shared-ar-hit-registration.md --strict
pnpm verify
```

Expected: citations OK; repository and workspace verification PASS.

---

### Task 2: Freeze product vocabulary and observable states

**Linear:** KIL-18

**Objective:** Resolve what the target represents and what users observe before interfaces or code change.

**Files:**
- Create: `CONTEXT.md`
- Create: `docs/features/shared-spatial-hit-registration/requirements.md`
- Create: `docs/features/shared-spatial-hit-registration/acceptance.md`
- Create: `design/slices/002-shared-phone-proxy-hit-registration.md`

**Decisions to close:**

- Sphere versus capsule phone proxy.
- Proxy size and whether it represents the player or an explicit game objective.
- Minimum player separation and maximum shot range.
- Tracking/mapping states that permit firing.
- Provisional versus confirmed feedback and rollback behavior.
- Maximum acceptable shared-frame error at 3, 8, and 15 metres.
- Safety copy and accessibility signals that do not rely on colour alone.

**Steps:**

1. Interview Jory using concrete edge cases.
2. Write glossary entries only in `CONTEXT.md`.
3. Write requirements without implementation prescriptions.
4. Freeze entry, calibration, ready, predicted, confirmed, rejected, degraded, and recovery states.
5. Define physical evidence and numerical acceptance thresholds.
6. Review against the technical spec and safety section.
7. Mark KIL-18 Done only after Integration accepts all four artifacts.

**Verification:** Every term is used consistently; no unresolved choice is delegated to an implementer.

---

### Task 3: Freeze the deterministic spatial module interface

**Linear:** prerequisite inside KIL-19

**Objective:** Define one deep pure module before implementation.

**Proposed module:** `SpatialHitEvaluator`

**External interface:**

```swift
struct PhonePoseSample: Equatable, Sendable {
  let sequence: UInt64
  let sampledAt: ContinuousClock.Instant
  let arenaFromPhone: simd_float4x4
  let trackingQuality: TrackingQuality
}

struct FrameAlignedShot: Equatable, Sendable {
  let clientShotId: String
  let firedAt: ContinuousClock.Instant
  let originArena: SIMD3<Float>
  let directionArena: SIMD3<Float>
  let shooterPoseSequence: UInt64
}

struct RewindPolicy: Equatable, Sendable {
  let maxHistoryAge: Duration
  let maxPoseAge: Duration
  let maximumRewind: Duration
}

protocol SpatialHitEvaluating: Sendable {
  func evaluate(
    shot: FrameAlignedShot,
    targetHistory: [PhonePoseSample],
    proxy: PhoneTargetProxy,
    policy: RewindPolicy
  ) -> SpatialVerdict
}
```

Internal seams may cover matrix validation, interpolation, proxy construction, and ray intersection, but callers learn only the types above and `evaluate`.

**Files to freeze after repository inspection:**
- Create likely: `ios/VictoriaKillZone/VictoriaKillZone/Targeting/Spatial/SpatialHitEvaluator.swift`
- Test likely: `ios/VictoriaKillZone/VictoriaKillZoneTests/SpatialHitEvaluatorTests.swift`
- Integration handoff: `ios/VictoriaKillZone/Package.swift` if explicit source inclusion changes

**Verification:** Interface review applies deletion test, locality, point/vector semantics, and no ARKit/Convex imports in the pure evaluator.

---

### Task 4: Implement deterministic transforms and bounded rewind with TDD

**Linear:** KIL-19, blocked by KIL-18

**Objective:** Prove spatial math before live AR or networking.

**Test order:**

1. Identity transform preserves point and direction.
2. Translation changes point but not direction.
3. Rotation transforms both correctly.
4. Round-trip through derived inverse returns the source within tolerance.
5. Non-finite and non-invertible transforms fail closed.
6. Out-of-order sequences are rejected.
7. Interpolation returns endpoints and midpoint correctly.
8. Missing/bracketing history rejects rather than extrapolating silently.
9. Rewind beyond policy cap rejects.
10. Known ray hits a known sphere/capsule.
11. Known ray misses.
12. Two simulated phone frames reconstruct one arena point.

**Commands:**

```sh
pnpm verify:ios
pnpm verify
```

**Deliverable:** standalone PR, no live ARKit or Convex change.

---

### Task 5: Design the shared arena session seam

**Linear:** design checkpoint for KIL-20

**Objective:** Keep AR world sharing and peer transport behind one small interface.

**Proposed external interface:**

```swift
protocol SharedArenaSession: Sendable {
  var states: AsyncStream<SharedArenaState> { get }
  var remotePoses: AsyncStream<RemotePhonePose> { get }

  func startHosting(playerId: String) async throws
  func join(playerId: String) async throws
  func stop() async
}
```

The implementation hides AR world-map capture, peer discovery, encryption, collaboration/world-map payloads, clock sync, sequence handling, sampling rate, and reconnect behavior.

**Likely files:**
- Create: `ios/VictoriaKillZone/VictoriaKillZone/Targeting/Spatial/SharedArenaSession.swift`
- Create: `ios/VictoriaKillZone/VictoriaKillZone/Targeting/Spatial/ARKitSharedArenaSession.swift`
- Create: `ios/VictoriaKillZone/VictoriaKillZone/Targeting/Spatial/PeerPoseTransport.swift`
- Test: `ios/VictoriaKillZone/VictoriaKillZoneTests/SharedArenaStateMachineTests.swift`
- Integration-owned modify: `ios/VictoriaKillZone/Package.swift`
- Integration-owned Xcode project/workspace edits if required

**Constraint:** One adapter is acceptable for the hardware seam because a deterministic fake is the second adapter used by tests.

---

### Task 6: Prove shared phone proxies on two physical iPhones

**Linear:** KIL-20, blocked by KIL-18 and KIL-19

**Objective:** Demonstrate one shared 3D frame before enabling spatial fire.

**Implementation steps:**

1. Host maps the arena and exposes mapping quality.
2. Guest receives the map and relocalizes.
3. Both exchange `PhonePoseSample` messages at an initial measured 10–20 Hz.
4. Each rejects duplicate/out-of-order sequences.
5. Each retains a one-second ring buffer.
6. Both render three shared anchors and both phone proxies.
7. Spatial fire remains disabled.
8. Tracking interruption transitions to degraded state and clears stale readiness.

**Physical evidence:**

- Exact SHA, Xcode version, phone models, and iOS versions.
- Alignment disagreement at 3, 8, and 15 metres.
- Pose update p50/p95/p99, age, loss/out-of-order counts, recovery time, thermal state.
- Walk-away/return and AR interruption/relocalization recordings.

**Deliverable:** iOS targeting PR plus separate read-only Outpost/device report. Source fixes return through a new PR.

---

### Task 7: Instrument the latency path

**Linear:** KIL-21, blocked by KIL-20

**Objective:** Measure, not assume, whether the hybrid architecture feels realtime.

**Required timestamps:**

```text
fireInputAt
localFeedbackAt
peerClaimSentAt
peerClaimReceivedAt
hostVerdictAt
convexMutationStartedAt
convexMutationReturnedAt
phoneSnapshotObservedAt
spectatorSnapshotObservedAt
reconciledRenderAt
```

**Metrics:** p50/p95/p99 for peer pose age, host verdict, Convex mutation, subscriptions, and end-to-end reconciliation.

**Initial budgets to test:**

```text
render frame                 <= 16.7 ms at 60 fps
phone pose interval          <= 50 ms at 20 Hz
pose age at evaluation       <= 100 ms
local feedback               same frame
host verdict                 <= 50 ms after claim receipt
Convex confirmation          measured, no assumed threshold
```

**Privacy:** Logs contain no session secret, device identifier, precise geographic location, or signing material.

---

### Task 8: Accept the authority ADR

**Linear:** KIL-21

**Objective:** Decide where spatial truth lives using measured data.

**File:**
- Create: `docs/decisions/0003-shared-spatial-hit-authority.md`

**Compare:**

1. Convex computes rewind/intersection.
2. Target phone confirms and Convex compares claims.
3. Host phone gives provisional verdict; Convex validates rules and records once.

**Recommended prototype choice:** option 3, contingent on KIL-21 measurements.

**ADR must freeze:** trust limitation, maximum rewind, pose age, clock-correlation method, provisional UI, rejection correction, idempotency, disconnect/recovery, and threshold for adopting a dedicated realtime simulation service.

---

### Task 9: Freeze `spatial-hit.v1`

**Linear:** KIL-22, blocked by KIL-18 through KIL-21

**Objective:** Publish one reviewed cross-lane contract.

**Files:**
- Modify: `docs/interface-contracts.md`
- Modify: `victoria-kill-zone-technical-spec.md`
- Create: contract fixtures in the existing integration-owned contract location selected during KIL-22
- Add contract tests in iOS, Convex, and spectator without implementing behavior

**Contract vocabulary:**

- matrix serialization and coordinate conventions;
- `PhonePoseSample`;
- `PhoneTargetProxy`;
- `FrameAlignedShotClaim`;
- `SpatialVerdict` and rejections;
- history, sequence, clock, rewind, and staleness limits;
- Convex evidence/ledger fields;
- sanitized spectator projection.

**Verification:** all three consumers decode the same fixtures; `pnpm verify` and `pnpm verify:ios` pass.

---

### Task 10: Create implementation issues only after contract freeze

**Linear:** final deliverable of KIL-22

**Objective:** Fan out isolated implementation work without overlap.

**Create these future issues:**

1. iOS realtime shared-arena adapter and pose history.
2. iOS frame-aligned shot claim and provisional feedback.
3. Convex spatial verdict/shot ledger and idempotent mutation.
4. iOS/Convex wire adapter.
5. Spectator current/rewound proxy and shot-ray debug grid.
6. Cross-surface integration.
7. Two-phone physical acceptance.

Each issue must include:

- one observable outcome;
- exact allowed and forbidden paths;
- frozen input contract and starting SHA;
- dependencies;
- exact tests/build commands;
- required automated and physical evidence;
- standalone PR unless dependence requires a named native stack;
- checkpoint and stop conditions.

Add `devin-ready` only to 1, 2, 3, or 5 when its lane is isolated. Keep 4, 6, and 7 with Integration/Jory.

---

### Task 11: Implement and accept live phone-proxy hitscan

**Objective:** Replace the production markerless shot path only after all isolated lanes pass.

**Integration flow:**

```text
same-frame AR shot sample
  -> local immediate FX
  -> peer host receives claim
  -> bounded rewind evaluator
  -> provisional spatial verdict
  -> Convex validates game rules + commits once
  -> phone/spectator subscriptions
  -> reconcile UI
```

**Acceptance:** one hit, one miss, one stale-pose rejection, one excessive-rewind rejection, one duplicate retry, one disconnect/recovery; all agree across two phones and spectator.

Keep debug fire until five consecutive physical runs pass on one promoted SHA.

---

### Task 12: Plan persistent projectiles as a separate slice

**Objective:** Use the accepted spatial history, not the old 2D claim, for visible bullets.

**Do not implement in the hitscan PR.** Create a new requirements/design/ADR cycle covering:

```text
projectileId
originArena
directionArena
speedMetersPerSecond
radiusMeters
spawnedAtServer
maxLifetimeMs
state
resolvedAtServer
```

Clients reconstruct position; the host evaluates swept collision against target history; Convex stores spawn and terminal state. Normal-time persistent projectiles must pass before personal time is designed.

---

## Verification matrix

| Layer | Automated | Physical/observable |
|---|---|---|
| Pure spatial math | deterministic Swift tests | none |
| Shared arena state machine | fake adapter tests | two phones relocalize |
| Peer transport | ordering/staleness tests | p50/p95/p99 and recovery |
| Convex authority | Vitest idempotency/rules tests | mutation + subscription on both phones |
| Spectator | Vitest/RTL reconstruction tests | browser agrees with devices |
| Integration | `pnpm verify`, `pnpm verify:ios` | exact-SHA five-run sequence |

## Risks and stop-the-line conditions

- Shared-frame error exceeds the accepted target size margin.
- AR interruption silently reuses stale transforms.
- Clock offset cannot be bounded.
- Peer messages arrive too stale for the accepted rewind policy.
- Convex confirmation produces unacceptable p95 reconciliation delay.
- A task needs files owned by another active lane.
- Public spectator projection leaks precise historical positions or secrets.
- A physical-device claim has only simulator evidence.
- Persistent projectiles or personal time are pulled into the first hitscan slice.

## Execution posture

The next action is KIL-18, not code. Finish requirements and target-proxy decisions, then execute KIL-19 as a deterministic prototype. Devin remains idle until KIL-22 freezes `spatial-hit.v1` and creates isolated implementation issues.
