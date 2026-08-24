# Testing strategy — useful simulations, not checkbox tests

Status: Draft for review — 2026-08-24
Owner: Integration
Purpose: Define the test tiers every KIL ticket must satisfy, the scenario harnesses that make gameplay testable without two humans in a park, and what may only be proven on physical devices. Companion to [docs/playbooks/kil-ticket-loop.md](playbooks/kil-ticket-loop.md) and the Mac Outpost operations guide.

## Principles

1. **A test is useful if it would have caught the prototype's real failures** (score/death divergence, duplicate fire, stale-pose hits, reconnect desync) — not if it merely re-asserts a constant.
2. **Determinism is the test enabler.** The simulation core (KIL-34) is pure: same inputs → same verdicts. Therefore gameplay scenarios become *replayable fixture files*, and every bug becomes a permanent regression scenario.
3. **Simulators simulate networks and logic, never physics of the world.** Camera, Vision quality, GPS, UWB, radio behavior outdoors, haptics, and thermal are physical-device evidence only (per AGENTS.md). Tests must be honest about their tier.
4. **Every ticket names its tier evidence in the PR.** CI enforces Tier 0; the Outpost runs Tier 1; humans + TestFlight builds produce Tier 2 artifacts.

## Tiers

### Tier 0 — Deterministic (every PR, any machine, `pnpm verify`)

| Suite | What it proves | Where |
|---|---|---|
| Convex domain tests (existing) | Rules: damage clamp, cooldown, idempotency, respawn, winner | `convex/tests/**` |
| Contract fixture round-trips (existing, extend for match.v2) | Both clients and backend parse the same wire shapes | `contracts/fixtures/**` |
| **Scenario verdict suite (new, KIL-34)** | End-to-end combat truth: timeline in → verdicts out | `shared/simulation/scenarios/**` |
| **Determinism property tests (new, KIL-34)** | Same scenario twice → byte-identical verdict log; event arrival order within a tick does not change verdicts | simulation core tests |

**Scenario fixture format (the executable spec).** One JSON file per scenario:

```jsonc
{
  "name": "rewind_hit_inside_window",
  "description": "Shooter fires at target's 180ms-old position while target strafes; verdict must be HIT via rewind, not MISS against current position.",
  "clock": { "tickMs": 16 },
  "players": [
    { "id": "A", "proxy": { "shape": "sphere", "radiusM": 0.35 } },
    { "id": "B", "proxy": { "shape": "sphere", "radiusM": 0.35 } }
  ],
  "timeline": [
    { "atMs": 0,   "poseSample": { "player": "B", "pos": [4.0, 1.4, 0.0] } },
    { "atMs": 50,  "poseSample": { "player": "B", "pos": [4.0, 1.4, 0.4] } },
    { "atMs": 180, "fire": { "shooter": "A", "origin": [0,1.5,0], "dir": [1,0,0], "claimedAtMs": 60, "clientShotId": "s1" } }
  ],
  "expect": [
    { "verdict": { "shotId": "s1", "outcome": "hit", "target": "B", "rewoundToMs": 60 } }
  ]
}
```

**Required scenario families** (each ticket adds its own; these are the floor):
- Rewind correctness: hit inside window; miss outside 250ms cap; pose gap larger than max pose age → rejected with reason; interpolation between samples.
- Fairness/abuse: claimed timestamp in the future → clamped/rejected; claimed timestamp older than window → rejected; duplicate `clientShotId` → replay not double damage; conflicting reuse → rejected.
- Multiplayer (4 players): crossfire — A and C hit B in the same tick (damage order deterministic); kill credited once when two shots land on 1 HP; dead player's queued shot rejected; respawned player targetable again.
- Lifecycle: fire during countdown/finished rejected; ammo exhaustion; cooldown boundary at exactly 350ms.
- Projectiles (Phase 2): worldline position at t; dodge (proxy moved before arrival) → miss; expiry; bullet-time-scaled arrival deadline.

### Tier 1 — Mac Outpost simulations (every iOS/backend PR that touches the loop)

Runs headlessly on the `pew-pew-macos` Outpost. This is where "useful simulation" lives:

1. **Swift package + XCTest suites** (existing: targeting state machine, wire models, voice gate) via `xcodebuild ... -destination 'generic/platform=iOS Simulator' build-for-testing` + `test-without-building`.
2. **Two-simulator convergence match (new — the flagship).** Script boots two iOS Simulator instances (`xcrun simctl`), both launch the app against a **dev Convex deployment**, and a UI-test driver performs: create → join → ready → start → N debug-fires → assert on both simulators and via a spectator query that health/ammo/K-D/events converge within a timeout. Assertions read state through `queries:matchSnapshot`/`spectatorSnapshot`, not screenshots. This is exactly the class of bug KIL-36 is hunting, made repeatable.
   - Variants: mid-match app relaunch on one simulator (reconnect/recovery); duplicate-fire retry (idempotency on the wire); 4-simulator variant once match.v2 lands.
3. **Transport loopback simulation (KIL-35).** In-process pair (later: two simulators over loopback) exchanging pose datagrams + reliable fire events through a fault-injection shim (configurable delay, jitter, drop %, reorder). Asserts: latest-state semantics (stale pose discarded), fire events never lost/reordered, host verdicts stable under 5% loss. Radio physics excluded — explicitly Tier 2.
4. **Voice corpus regression (KIL-37).** Committed audio fixture corpus (`ios/**/VoiceFixtures/`: recorded "pew", "pew pew", rapid repeats, near-misses like "few"/"pew you", crowd noise, wind) fed offline through the recognizer/classifier in XCTest. Reports FP/FN/latency percentiles; PR fails if FP/FN regress against the recorded baseline JSON.
5. **Latency measurement harness (KIL-21 feeder).** A debug scheme target that replays scripted fire/pose activity and emits timestamped JSON (`fire→verdict`, `fire→Convex confirmation`, subscription fan-out). On simulators it measures the software path only — numbers are labelled `SIMULATOR` and never satisfy the physical gate.

### Tier 2 — Physical device evidence (TestFlight builds, human-in-the-loop, sanitized)

Cannot be simulated; the Outpost produces the build (KIL-38 TestFlight lane), a human runs the scenario, the app's harness writes the evidence artifact, and the session records it in `docs/build-log.md` + the Linear ticket:

| Scenario | Instrumented artifact |
|---|---|
| 2-phone (then 4-phone) outdoor match: 5 clean kill/respawn cycles | in-app match report JSON (verdicts, health timeline) + screen recordings |
| Peer transport outdoors: sustained pose cadence, loss/jitter | transport stats JSON from both phones (KIL-35 instrumentation) |
| KIL-21 latency percentiles on devices | harness JSON, labelled `DEVICE`, appended to build-log |
| Targeting acquisition at 3–8m, tracking loss/reacquire | targeting session log + video |
| Geofence boundary walk (KIL-28) | arena-state transitions log + video |
| Voice fire outdoors (wind/distance) | corpus-format live capture for lab replay |

Rules: name device models + iOS versions (no UDIDs), sanitize logs, simulator evidence never closes a Tier 2 checkbox.

## Per-ticket tier map

| Ticket | Tier 0 | Tier 1 | Tier 2 |
|---|---|---|---|
| KIL-33 match.v2 contracts | fixtures round-trip | — | — |
| KIL-34 simulation core | scenario suite + property tests (the deliverable itself) | — | — |
| KIL-35 transport | protocol codec tests | loopback fault-injection; 2-sim exchange | outdoor cadence/loss stats |
| KIL-36 autopsy | regression scenario reproducing the found bug | 2-sim convergence match (must fail before fix, pass after) | 5-cycle 2-phone run |
| KIL-37 voice | gate logic tests (existing) | audio corpus FP/FN/latency | outdoor live capture |
| KIL-38 TestFlight loop | — | archive/sign/upload lane dry-run | OTA install observed on both phones |
| KIL-27/28 geofence | evaluator unit tests | simulated location scripts on simulator | boundary walk |
| KIL-19/20/21 spatial | rewind math fixtures | harness on simulators (`SIMULATOR`-labelled) | shared-arena + latency numbers outdoors |

## Definition of done (every code ticket)

1. `pnpm verify` green (Tier 0 embedded).
2. Tier 1 suites named by the ticket pass on the Outpost; new scenarios committed.
3. Tier 2 checkboxes either satisfied with evidence or explicitly deferred with owner + date in the PR and Linear ticket.
4. Any bug found in review/play becomes a scenario fixture before its fix merges.
