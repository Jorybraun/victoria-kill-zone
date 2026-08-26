# Shared phone-proxy hit registration acceptance

| Field | Value |
|---|---|
| Status | Corrected and frozen for KIL-18 acceptance |
| Requirements | [requirements.md](requirements.md) |
| Design | [design/slices/002-shared-phone-proxy-hit-registration.md](../../../design/slices/002-shared-phone-proxy-hit-registration.md) |
| Player set | 2–4 (ADR 0003 Phase 1 cap) |

Every gate names the environment that can produce it. An environment may only claim the gates in its own section: hosted CI/Cloud cannot claim a simulator or device result, and a simulator run is never physical-device evidence.

## Gate A — Documentation (hosted CI/Cloud, no Xcode required)

- [ ] Each glossary term in `CONTEXT.md` is defined once, without implementation detail, and every other document uses those exact terms.
- [ ] Requirements, design slice, and research agree on target meaning, proxy radius, lane bounds, rewind cap, pose age, evaluation order, and the authority chain.
- [ ] The packet cites accepted ADR 0003 as the production pivot, creates no second ADR 0003, and does not pre-empt ADR 0004.
- [ ] `phase0.v1`, `g2.v1`, `geofence.v1`, and `match.v2` are unchanged by this packet, and `contracts/fixtures/**` is untouched.
- [ ] The packet states that Integration freezes `spatial-hit.v1` before cross-workstream implementation.
- [ ] No player-visible copy anywhere in the packet contains "host", "guest", or "opponent"; nothing assumes exactly two players.
- [ ] No document states or implies that a target lock is required to fire; ready copy is `FIRE`, `SPATIAL LOCK READY` is retired, and `ACQUIRE TARGET` appears nowhere.
- [ ] The packet defines a shot as one normalized camera ray with an optional candidate, states that a no-candidate shot is an authoritative `miss`, and reconciles this with the technical specification's existing "trigger without a valid zone means miss" rule.
- [ ] The packet requires one deduplicated transient tracer per remote shot for every member, keyed by shot identity, and states that confirmation does not replay it.
- [ ] Tracer behavior is described as hitscan presentation only — no projectile velocity, travel time, or swept collision enters KIL-18.
- [ ] Contract and core work implied by the optional target and the remote tracer is assigned to KIL-19/20/21/22, and this packet changes no DTO or code.
- [ ] `shots:debugFire` and the screen-space Vision claim path are explicitly retained until physical-device evidence passes.
- [ ] Persistent Projectile Worldlines, personal time, body-zone collision, and more than 4 players remain excluded.
- [ ] Every must-decide-now item is resolved here, and every deferred threshold has an owner issue plus a fail-closed default.
- [ ] Every canonical state, HUD, VoiceOver, and rejection label exists exactly once in the requirements label catalog, and each rejection key matches a `ShotRejectionReason` value implemented in `shared/simulation`.
- [ ] `pnpm verify` passes on the exact head SHA of the packet PR.

## Gate B — Deterministic evaluator (hosted CI/Cloud, `shared/simulation` fixtures)

Measured by replaying scenario fixtures through the merged simulation core; each expectation is an exact value, not a range. The reviewer must be able to read the expected verdict from the requirements without running the code.

- [ ] Proxy radius is exactly `0.35` and lane bounds exactly `3` and `15` in every vector; no test overrides a constant.
- [ ] Hit at 8 m, ray through the proxy centre → `hit`, applied damage exactly `34`.
- [ ] Tangential shot whose closest approach equals `0.35 m` → `hit` (boundary is inclusive).
- [ ] Shot whose closest approach is just beyond `0.35 m` → `miss`, no damage.
- [ ] Backward ray (target behind the shooter, `v · d < 0`) → `miss`, never a hit.
- [ ] Separation `2.999 m` → `rejected(targetTooClose)`; exactly `3 m` → evaluated on geometry.
- [ ] Separation `15.001 m` → `rejected(targetOutOfRange)`; exactly `15 m` → evaluated on geometry.
- [ ] Rewind exactly `250 ms` → evaluated; `251 ms` → `rejected(shotTooLate)`; a claim dated after the evaluation instant → `rejected(shotTooLate)`.
- [ ] Pose age exactly `100 ms` → evaluated; `101 ms` → `rejected(poseTooOld)`.
- [ ] Bracketing samples more than `100 ms` apart → `rejected(poseTooOld)`; no interpolation across the gap.
- [ ] Empty or missing target history → `rejected(poseTooOld)`, never `miss`.
- [ ] Any sample used in the resolution with tracking `lost`, or a stale latest sample on either phone → `rejected(trackingLost)`.
- [ ] Self-target and non-member target → `rejected(invalidTarget)`; dead target → `rejected(targetNotAlive)`; dead shooter → `rejected(shooterNotAlive)`.
- [ ] A shot whose ray meets no candidate resolves as `miss` with the shot recorded and ammunition consumed — never suppressed, and never reported as a lock-related rejection.
- [ ] With no other member in the hittable set at all, a fired shot still produces exactly one `miss` verdict.
- [ ] A ray passing within 0.35 m of a member outside the lane (2.5 m and 16 m) resolves as `miss` on the target-agnostic reading; on a named-target claim the same input reports `targetTooClose` / `targetOutOfRange`. Both readings are asserted on the same fixtures.
- [ ] With two candidates on one ray, the nearer forward intersection takes the damage and the farther member's health is unchanged.
- [ ] A claim violating several rules reports exactly the reason the fixed evaluation order names.
- [ ] A repeated logical shot (same client shot id) yields one Spatial Verdict and applies damage once.
- [ ] Non-finite components, a non-invertible or non-orthonormal transform, and a zero-length direction are rejected at ingress and never reach the geometry test as a `miss`.
- [ ] Identical input sets in any arrival order produce byte-identical event sequences, replayed twice.
- [ ] A 3-player and a 4-player scenario each produce correct pairwise verdicts, with uninvolved members' health unchanged.

## Gate C — Simulator (requires Xcode; cannot be claimed from hosted Cloud)

Simulators can prove state machines, copy, and accessibility. They cannot prove relocalization, drift, or latency.

- [ ] The iOS target builds for the simulator on the packet SHA and the simulation core's tests pass on that toolchain.
- [ ] All eight spatial states render with the exact canonical HUD copy: `calibrating`, `ready` (`FIRE`), `predicted`, `hitConfirmed`, `missConfirmed`, `rejected`, `degraded`, `recovered`.
- [ ] With no candidate detected, the ready state still shows `FIRE` and an enabled trigger; a press produces a predicted tracer and reconciles to `MISS CONFIRMED`.
- [ ] Closing each fire gate in turn (dead, tracking lost, geofence, empty magazine, cooldown) disables the trigger and names that gate; no target condition ever disables it.
- [ ] An injected remote shot draws exactly one transient `INCOMING SHOT` tracer along the received origin and direction, and injecting the same shot identity again draws none.
- [ ] Every one of the eight rejection reasons renders its exact canonical label and corrective action from injected verdicts.
- [ ] A predicted shot changes no health, ammunition, or score, and repeat fire is disabled while it is pending.
- [ ] An authoritative verdict contradicting the prediction visibly replaces the predicted panel and never stacks a second result.
- [ ] Injected tracking loss locks fire within one frame of the state change and shows stale positions only as dimmed, labelled diagnostics.
- [ ] Recovery returns to `ready` without replaying any earlier shot animation.
- [ ] VoiceOver reads the exact canonical lines and distinguishes predicted from confirmed; Reduce Motion removes travel and pulsing without hiding state; touch targets remain 48 × 48 pt.
- [ ] The proxy renders as a game objective, never a body outline, at 2, 3, and 4 players.
- [ ] Simulator evidence is labelled as such in the build log and claims no spatial measurement.

## Gate D — Physical device (two to four iPhones; required before claiming live shared-3D hit registration)

- [ ] Every phone model and iOS version is named, with no device identifiers or secrets recorded.
- [ ] All members relocalize into one Shared Arena Frame; three non-collinear anchors are compared across every device.
- [ ] Transform disagreement is recorded at 3 m, 8 m, and 15 m for every pairing (KIL-20 owns the tolerance).
- [ ] Five known hit vectors and five known miss vectors are repeated at each of 3 m, 8 m, and 15 m.
- [ ] At each of 3 m, 8 m, and 15 m, ten shots fired deliberately off-target each yield one `MISS CONFIRMED`, one ammunition decrement, and one shot-ledger entry — zero suppressed inputs and zero rejections.
- [ ] Firing with no other member in view yields the same recorded miss.
- [ ] On two phones, every remote shot produces exactly one correctly oriented tracer on the receiving phone — hits and misses alike — with the drawn direction matching the shooter's aim to the reviewer's eye.
- [ ] No tracer is duplicated by reconciliation, backgrounding, resubscription, or reconnect replay; a reconnecting phone draws no tracer for shots fired while it was away.
- [ ] One packet later than 250 ms is rejected without damage; one pose older than 100 ms is rejected without damage.
- [ ] Tracking interruption on one phone locks fire on that phone only, and fresh relocalization restores it while the others keep playing.
- [ ] With 3 or 4 players, a shot at one named target changes only that target's health; a second member inside 3 m of the shooter blocks nothing.
- [ ] Convex records exactly one authoritative transition per accepted shot, and every phone plus the spectator reconcile to it.
- [ ] Host verdict latency and Convex authoritative p50/p95/p99 are recorded as measurements for KIL-21, not as claims.
- [ ] The spectator shows the `REWIND 0–250 MS` disclosure and exposes no precise historical coordinates.
- [ ] No compile or simulator result is described as physical evidence anywhere in the evidence record.

## Exit

KIL-18 closes when Integration accepts this packet — terminology, frozen semantics and limits, trigger authority, authority chain, must-decide-now versus deferred split, the eight-state design packet, and this evidence plan — with Gate A satisfied and Gates B–D scheduled to their owners. KIL-19 stays blocked until that acceptance is merged, and no `devin-ready` label or implementation dispatch is authorized before it.
