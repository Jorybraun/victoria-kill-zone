# Quick Play and independent Scan & Save — execution plan

Owner: Integration / Codex local. Tracker: [KIL-46](https://linear.app/kill-victoria/issue/KIL-46/resolve-creator-phone-room-scanning-on-iphone-14-before-multiplayer).
Updated: 2026-09-07. The owner authorized combining this plan with the full
production-combat review and continuing implementation. KIL-47's CI repair is
dispatched; feature lanes await green/frozen inputs. The full M0–M6 goal remains
open and its automatic continuation is usage-limited. Work continues in the
current task; no production setting change, merge or release is implied.

## One goal, two levels of detail

The [roadmap's unified goal](../roadmap.md#active-goal-checkpoint--2026-09-07)
defines the outcome. The [production-combat review](production-combat-review.md)
retains all M0–M6 requirements; its current reading guide separates implemented
components from missing behavior and proof. This plan supplies the execution
order, ownership, acceptance gates and current Linear assignments. They are
one delivery contract, not competing plans.

Review existing UI and functionality against real play: can friends enter a
match, understand how to fire, see incoming shots, trust hits and recover from
interruption? Replace a failing interaction or underlying assumption instead of
continually polishing it. Preserve useful components and security/state invariants.
The immediate product change is optional scanning and low-friction Quick Play.
Manual calibration cannot remain mandatory merely because it is implemented.

## Outcome

Two to four people on supported iPhones can start Quick Play in a new location
without selecting a saved map, manually scanning a room, or setting an arena
radius. Players see accepted shots and agree on damage, ammunition, reload,
deaths/respawns and departures. First prove a mixed-model two-phone match, then
three- and four-player groups. The reported iPhone 14 is one regression case;
it does not define the product's device support or sole acceptance gate.

Separately, one person can open Scan & Save, scan surroundings, name and save a
map, quit the app, and later test recognition in that same location without a
match, opponent or network connection. Saved maps remain optional experiments
and conveniences. They never carry saved gameplay readiness.

No promise of tracking in every lighting condition or featureless environment.
No manual boundary requirement in Quick Play. Radius/perimeter design is deferred
outside this critical path. Shields, bullet time, dodge trials, skeleton polish,
and remaining M0–M6 performance work remain queued after the basic duel is proven.

## Supported-device acceptance

Before feature implementation, Integration freezes a representative test matrix
from the app's declared iOS floor and the actual required AR capabilities. Record
which combinations are supported, untested or unsupported; do not infer support
from a successful build. Include the oldest supported non-LiDAR class, representative
standard iPhones including the reported iPhone 14, and Pro/LiDAR models across
supported iOS versions. Device availability and exact model/OS coverage remain pending.

Source inventory: Xcode Debug/Release and SwiftPM declare iOS 17.0; the app targets
iPhone. The spec recommends iPhone 12 or newer for performance rather than defining
a model whitelist. Current generic targeting availability accepts world OR body
tracking, but `TargetingSession.beginFrameMapping` requires world AND body tracking,
including standalone scanning. A map-only workflow needs a separately scoped
world-tracking capability contract; this does not relax production body admission.
The existing collaboration harness's world-tracking support check cannot establish
support for the integrated Quick Play implementation.

Use runtime capability checks rather than model-specific tuning. Quick Play's
baseline must work without LiDAR; optional hardware enhancements cannot change
combat rules or silently narrow support. Test mixed-model pairs with host/joiner
roles swapped, followed by mixed three- and four-player groups. Exercise alignment,
incoming/outgoing shots, body association, departures and reconnect on each tested
combination. Run the independent scan/save/reopen/recognition loop on one device
from each representative class. An unavailable device leaves that matrix row
unverified; another phone's pass cannot close it.

## Verified starting state and immediate blocker

- Existing chain: #69 `codex/arena-scan-recovery` → #70 `codex/saved-arenas` →
  #71 `codex/room-scanning-14`. All are open; #70/#71 are drafts. Main is
  `2929fd69e6768192f91fbf206cbed62cb202626e` at this checkpoint.
- #69 accepts extending maps, bounds initial scanning and recovers unarmed clock
  synchronization. #70 implements local scan/reference/save. #71 fixes misleading
  camera-failure state and adds actionable tracking guidance.
- #71 head `5e20cefb4f59c32c36de5182403c73ac52863ffb` passed local `pnpm verify`
  and `pnpm verify:ios` (337 app tests, zero failures, one physical-only skip).
  GitHub run **34133648903 failed**: iOS passed; Fast gate timed out after 10 s in
  Worker `runtime.test.ts`, “disconnects a non-acknowledging receiver before its
  outbound queue grows without bound.” The cause is not established. Do not call
  #71 green or dismiss this as flaky without evidence.
- Creating a game currently routes through the saved library. Library management
  also displays USE THIS ARENA. Direct `createRealtimeArena()` bypasses selection
  but still requires host mapping/reference capture; it is not setup-free play.
- The current calibration candidate requires a continuously visible fixed image.
  ARKit collaboration uses world tracking; the current game switches to body
  tracking. A shared-coordinate solution and compatible body targeting both need
  proof before changing production readiness (ADR 0009).
- The active older harness sends raw local camera transforms as arena coordinates
  and compares poses across those frames. Its optional residual and participant
  anchor check are not independent combat-accuracy evidence. Reuse bounded math,
  history and transport components, not those assumptions or its fixed demo secret.
- No physical iPhone 14 scan, two-phone bullets, or freely moving combat acceptance
  has been demonstrated. Exact iPhone variant, iOS and installed build are pending.

## Sequence and checkpoints

Queued dispatch briefs: [KIL-47 — CI repair](https://linear.app/kill-victoria/issue/KIL-47/restore-green-ci-for-the-stalled-combat-receiver-regression),
[KIL-48 — Scan & Save](https://linear.app/kill-victoria/issue/KIL-48/make-scan-and-save-independent-and-test-saved-maps-on-one-phone),
[KIL-49 — automatic alignment](https://linear.app/kill-victoria/issue/KIL-49/prove-temporary-two-phone-alignment-before-adopting-quick-play),
[KIL-50 — projectile/combat proof](https://linear.app/kill-victoria/issue/KIL-50/prove-visible-projectile-rendering-and-multiplayer-state-convergence).
KIL-47 is In Progress with one exclusive Worker/CI owner in
`/tmp/vkz-receiver-ci`, branch `codex/receiver-backpressure-test`, based on main
`2929fd69`. First checkpoint: 2026-09-07 17:10 UTC (45 minutes from dispatch).
KIL-48–50 remain Backlog with explicit paths, exclusions, dependencies,
checkpoints and acceptance commands. Root owns the combined docs and publication.

| Step | Status | Owner | Exit evidence |
|---|---|---|---|
| 0. Establish a green baseline | in_progress: CI repair dispatched | CI/Worker owner, root review | Reproduce or classify the timeout, repair the owning code/fixture, canonical checks and real GitHub jobs pass on exact heads |
| 1. Freeze interfaces and the two user flows | pending | Integration | Accepted next-slice design, supported-device matrix, typed local contracts, exact ownership and dispatch briefs in Linear |
| 2. Fan out scanner, spatial experiment and combat replay | pending; parallel after inputs are green/frozen | Three agents | Each returns a small draft PR plus its specific evidence below |
| 3. Decide positioning and targeting compatibility | pending; needs spatial device evidence | Integration + targeting | Measured method and successor ADR; no fabricated or stale accuracy evidence |
| 4. Integrate Quick Play | pending; depends on 2/3 | Integration + combat | No saved-map dependency; transformed accepted projectiles and real associated targets, lifecycle/reconnect tests |
| 5. Prove the signed build on phones | pending | Integration + device operator | Same-SHA scanner trials across representative device classes, mixed-model two-phone gameplay recordings/ledger, then mixed three/four-player trials |
| 6. Finish combat feel and abilities | pending; requires playable shared frame and target evidence | Client/targeting/simulation owners with explicit handoffs | Remaining M0/M3/M4 cadence, hit feedback, filmed dodge/control and shield/slowdown evidence; small-screen and interruption UX accepted |
| 7. Close backend and spectator gaps | pending; bounded defects may be repaired earlier | Worker, host simulation and Convex/spectator owners in separate paths | Comparable host/DO scenarios, resolved sustained-load failures, recovery/cost/network measurements, authority ADR and agreeing spectator ledger |
| 8. Complete production acceptance | pending; requires preceding behavior and verified canonical SHA | Integration + device operator | Full supported-device matrix, repeated playable matches, thermal/frame-time/battery/memory/accessibility/permission evidence and signed installation; every report gate closed |

### Full-report traceability

| Report milestone | Where it completes in this plan | Still-required result |
|---|---|---|
| M0 — input, feedback and UI | Combat lane, integration, steps 5/6 | Fast sustained fire and misses, authoritative ammo/reload, correct-person hit-only anatomical skeleton/target feedback, compact usable controls and stable reconnect |
| M1 — shared frame | Spatial lane, steps 3–5 | Measured common geometry while moving without a continuously visible fixed reference; no saved-map prerequisite; compatible non-LiDAR body targeting |
| M2 — one authority | Combat lane, steps 4/5/7 | Two-to-four-player identity, event/state convergence, departures and reconnect; one live authority with durable ordered projections |
| M3 — finite bullets | Combat lane, steps 5/6 | Visible accepted worldlines, correct swept collisions/terminal events and physical dodge/control trials without retroactive unfair hits |
| M4 — shield and slow fields | Step 6 | Frozen rules implemented end to end; both phones and ledger agree on blocks, slow segments, cooldown/energy and phone-only movement controls |
| M5 — host/DO comparison | Step 7 | Equivalent authoritative scenarios, sustained reliability/durability, actual-network latency and cost; evidence-based authority choice rather than an assumed cloud win |
| M6 — production evidence | Steps 0/5/8 | Exact-head checks and guarded release plus observed install/gameplay, supported hardware, performance, accessibility and failure recovery |

Scan & Save adds an independent user loop to M1/M6 without replacing either
milestone or becoming a prerequisite for playing. Radius/perimeter options remain
an optional arena-mode follow-up, outside Quick Play's critical path. Before steps
6–8 dispatch, Integration records each bounded issue's exact paths, frozen inputs,
checkpoint and missing evidence in the same tracker. No new whole-backend or
skeleton rewrite is implied; fix or replace what the measured gap requires.

There are four agent slots including Integration. The short CI repair uses one
slot first. After it releases that slot, run exactly three implementation lanes
alongside Integration. Do not send agents into overlapping files or start an
unbounded backend rewrite.

First checkpoint for each coding assignment: **45–60 minutes after dispatch**,
with a compiling, executable increment or a specific reproduced blocker. Stop
and hand back scope drift, missing inputs, repeated failing hypotheses, or path
collisions. These are checkpoints, not promises that the full engine is finished
in an hour. A physical experiment stops after three failed bounded attempts;
retain results and make a decision before more implementation.

## Integration contract, before writes fan out

Integration owns App/Root/Home/Lobby routing, AppEnvironment, Domain/shared DTOs,
CombatWire, transport schema changes, Xcode membership, design/docs and releases.
Only Integration edits these paths; other agents request precise handoffs.

Freeze these small local contracts (names may follow existing module conventions):

- **Map-lab artifact:** typed local identity, name/date, format/version and secure
  bounded ARWorldMap bytes. A map-only artifact is distinct from the current
  reference-backed SavedArenaBundle. Existing saves remain readable. Map-only
  inspection cannot feed game admission or claim multiplayer calibration. Preserve
  size/count limits, private atomic storage, corruption recovery and no credentials.
- **Map test state:** loading, recognizing, recognized-on-this-phone, tracking-lost,
  timed-out and failed; recognition is transient, not persisted readiness. Scan,
  test, game and invite navigation share one awaited camera-ownership boundary.
- **Map-lab capabilities:** world-map capture/test has its own runtime world-tracking
  support check and driver entry. It must not inherit the current combat path's
  body-tracking requirement. The targeting owner supplies any driver change via
  explicit handoff; production targeting/readiness checks retain their meaning.
- **Experimental frame sample:** experiment epoch, origin-anchor identity,
  arenaFromLocal/localFromArena transforms, pose capture time and tracking state;
  validity is revocable. Experimental convergence is not production aligned.
- **Production spatial handoff, only after the decision gate:** frame/authority
  identity, measured validity/expiry, transforms, fresh camera pose and associated
  body observations. Missing body data remains missing. Outgoing geometry is
  transformed once into match coordinates; incoming FX once into local coordinates.
- **Collaboration transport:** per-run authenticated peer identity, bounded secure
  archives/chunking/backpressure and stale-epoch rejection. No fixed demonstration
  credential, new account system or competing combat authority.

Freeze the next user-facing slice only: Quick Play / Join / Scan & Save. Do not
label the current manual-map route Quick Play. The experimental positioning
screen stays clearly separate from a playable match; it can be exposed in a
signed internal test build without adding debug controls to the combat HUD.

## Lane A — Scan & Save (one-phone, independently releasable)

**Outcome:** scan → save → force-quit → reopen → test recognition, with no lobby
or server calls. This lane can finish even if automatic multiplayer alignment fails.

**Owned implementation paths:** Features/Arenas scan/setup/test controller and
view files; Services/SavedArenaStore.swift or a separately typed map-lab store;
scanner/store tests. Domain model, root routing, library-mode contract and Xcode
edits belong to Integration. Existing TargetingSession/DuelFrame files are read-only
unless their single targeting owner accepts an explicit driver handoff.

**Small dependent PRs:**

1. Separate Scan & Save management from game creation. Offer New scan, Test scan,
   Name, Delete, Done. Management never exposes USE THIS ARENA. Preserve
   existing reference-backed scans; do not silently create a match after saving.
2. Add map-only experimental capture/storage and one-phone reload/recognition.
   Reuse the existing world-map driver where valid; this test must not require an
   opponent or an anatomical calibration result. Keep map-only artifacts separate
   from playable calibration bundles. Add an offline recognition screen and bounded
   failure/restart handling. No body-configuration switch is needed for a map-only
   recognition test; legacy calibrated-map inspection may show its extra stages.

**Acceptance:** correct-location recognition after app restart; wrong location or
changed scene never reports success without relocalization; no game/network calls;
corrupt/oversized maps fail before camera entry; cancel/background/interruption
revoke late results and await camera stop. Test each representative supported
device class, including the reported iPhone 14 regression. A file decode or
simulator test alone does not prove recognition. Record model, iOS and exact build.

## Lane B — Automatic alignment and targeting feasibility

**Outcome:** two phones establish a temporary shared frame without loading a saved
location or keeping one fixed reference visible. First demonstrate a shared point
and peer positions; gameplay is disconnected during this measurement experiment.

**Owned paths:** new Targeting/QuickPlay experiment modules; the existing active
SharedArenaSession, SharedArenaHarnessView, SharedArenaModels and dedicated
experiment-policy/tests where needed. One targeting owner writes this whole
boundary. Root owns entry wiring, shared contracts and Xcode. Production DuelFrame
readiness remains unchanged until the decision gate.

**Small dependent PRs:**

1. Correct frame conversion and isolate a per-run authenticated world-tracking
   experiment. Reuse ArenaRigidTransform, bounded histories and ArenaPeerLinking.
   A uniquely identified shared origin defines
   `arenaFromPhone = inverse(localFromOrigin) × localFromPhone`.
   Reject absent/stale/wrong-epoch anchors and poses. Test deliberately translated
   and rotated initial local origins. Reset invalidates all derived transforms.
2. Run continuous ARKit collaboration on mixed-model phone pairs, swap host/joiner
   roles and measure convergence,
   walking/turning/ducking drift, interruption and reconnect. Keep one world-tracking
   session; switching to ARBodyTrackingConfiguration is not a continuity solution.
3. Only if alignment passes, evaluate metric body targeting and player association
   in that same session across the non-LiDAR baseline and supported device classes.
   Vision pose output or
   Nearby Interaction distance alone cannot establish accurate body collision
   volumes/full relative orientation. Return a measured compatible approach or a
   bounded failure report for an explicit product/architecture decision.

**Acceptance:** target automatic convergence within 10 s; each attempt times out
at 30 s, with a three-attempt stop. These are proposed product targets to measure,
not platform guarantees. Test indoors and outdoors with useful common visual
detail, at 3/8/15 m, then three minutes of moving and turning. Use independent
surveyed geometry/poses with documented measurement uncertainty—not anchor equality
or the same SLAM estimate. Report p50/p95/worst errors and invalid-coverage time;
p95 reporting does not relax the current per-sample 10 cm/0.5-degree bounds or
100 ms freshness. Invalid evidence must revoke eligibility. A distance measurement
alone cannot validate orientation. Missing independent measurement is a blocker.
After paired feasibility, repeat with mixed three- and four-player groups and
identity crossing/occlusion before claiming support for the full player cap.

**Decision:** accept a successor to ADR 0009 only with evidence and body-coverage
compatibility. If this fails, keep the working scanner lane and return the precise
tradeoff; do not spend indefinitely polishing the failed positioning method.

## Lane C — Visible bullets, game state and lifecycle

**Outcome:** prove that accepted projectile events render and the engine/client
agree on outcomes, independently of the uncertain camera experiment; then connect
them after spatial and targeting gates pass.

**Owned initial paths:** Features/Game/RealtimeCombatFX.swift, presentation/replay
modules and their tests. Later, after explicit root handoff, the named
Features/Realtime controller/presentation/command files and Services/Realtime
session/replica/clock/socket files. Root keeps CombatWire, Home/Lobby/Root routing
and map-mode selection. Scanner does not edit the realtime combat controller;
targeting supplies geometry rather than writing FX.

**Small dependent PRs:**

1. Replay simulation-generated accepted projectile fixtures through the actual
   replica/presentation/FX with no visible skeleton. Cover spawn, travel, miss,
   slow segments, cancellation, expiry and duplicate delivery; test non-identity
   incoming transforms. This is an explicitly synthetic rendering test and sends
   no manufactured readiness to a live match.
2. Verify existing command/replica lifecycle using isolated explicit fixture modes:
   ammo/reload, damage/death/respawn, join/leave, foreground/background and reconnect.
   Missing bodies must not suppress presentation of an already accepted projectile.
   The real simulation currently requires fresh colliders for every living player
   and cancels flight on coverage loss; keep that unresolved dependency visible.
   Do not silently switch production to phone-proxy collisions or rewrite authority.
3. After Lane B's decision and root integration, consume real transformed poses and
   associated colliders, render accepted worldlines on both phones and reconcile
   server results. Fix only demonstrated runtime defects through their owning lane.

**Acceptance:** every accepted projectile ID appears once and terminates correctly;
no invented target hit or duplicate damage; existing staleness bounds hold. Then,
on mixed-model physical phone pairs with host/joiner roles swapped, record 20 shots
each direction including misses, full
magazine/reload, lethal damage/respawn, leave/background/rejoin and reconnect.
Correlate visible incoming/outgoing shots with authoritative IDs, ammo, health and
K/D. Repeat state convergence and lifecycle trials in mixed three- and four-player
groups from the support matrix. A backend health response or Node probe does not
satisfy this gate.

## CI repair lane and PR dependency graph

The immediate CI owner is limited to services/combat-worker/tests/runtime.test.ts
and related Worker transport code only if a reproduced defect requires it. Root
owns CI configuration. Determine whether the 10-second failure is a lifecycle bug
or fixture scheduling issue; do not skip the test or just raise its timeout.

Preserve the existing #69 → #70 → #71 chain. The stalled-receiver test is already
on main and unchanged by scanning: repair it in a standalone draft PR targeting
main, then Integration propagates the accepted repair to affected descendants.
Repair other earlier-owner code on its owning branch and propagate forward;
reverify every changed head. Scanner
PRs build above their required scan baseline. Spatial experiment and combat replay
can use separate branches from a verified green common baseline when they do not
consume scanner code. Stack only the dependent increments within each lane; the
final integration PR joins the accepted heads. Do not serialize unrelated work
into one giant stack. Every PR declares parent, scope, evidence and merge order.

Use codex/ branches, isolated worktrees and draft PRs. Native Devin/GitHub grouping
and native-stack merge must be arranged by Integration through the repository's
supported release path; ordinary branch links do not establish native grouping.
No native grouping capability is currently exposed here. Merge/release approval
remains separate; this planning request does not approve production promotion.

## Final delivery gate

Run `pnpm verify` and affected native tests/builds on exact PR heads; checks must
actually execute in GitHub. Then reviewed protected merge → same-main CI/Deploy
and applicable smokes → gated signed internal/TestFlight build → verify the actual
processing/ready-for-testing receipt and SHA → device trial. An experiment may
ship for internal testing without claiming the feature is device-promoted.

Completion of the first integration checkpoint requires both independent user
loops: scan/save/reopen and a real mixed-model two-phone quick duel without manual
map setup. Product acceptance also requires the representative supported-device
matrix and mixed three/four-player trials. Record models/iOS/builds and physical
observations without unique IDs or secrets. Sustained latency/thermal behavior,
shields/dodging and the remaining M0–M6 criteria stay open until their own evidence
passes. Do not mark the overall goal complete when only foundation PRs land.

## Primary platform references

- [Apple: Creating a collaborative session](https://developer.apple.com/documentation/arkit/creating-a-collaborative-session)
- [Apple: Building Collaborative AR Experiences](https://developer.apple.com/videos/play/wwdc2019/610/)
- [Apple: Saving and loading world data](https://developer.apple.com/documentation/arkit/saving-and-loading-world-data)
- [Apple: Nearby Interaction worldTransform](https://developer.apple.com/documentation/nearbyinteraction/nisession/worldtransform(for:))

Platform features are candidates; these sources do not prove this game's
cross-phone accuracy, body coverage, convergence time or outdoor reliability.
