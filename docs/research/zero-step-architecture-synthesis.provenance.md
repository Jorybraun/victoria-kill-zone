# Provenance: Zero-step AR room understanding with authoritative combat — architecture synthesis (BIO-36)

- **Date:** 2026-09-26. Repository read at `main` `0750e9b` (clean, non-shallow checkout; verified with `git status` and `git rev-parse --is-shallow-repository`).
- **Scope:** read-only research synthesis for [BIO-36](https://linear.app/biossphere/issue/BIO-36/spike-engineer-zero-step-ar-room-understanding-and-authoritative). Produced exactly two uncommitted files: `docs/research/zero-step-architecture-synthesis.md` and this sidecar. No code, test, configuration, branch, commit, push, PR, deployment, ADR, Linear update or device trial was produced. `git status` after writing shows only the two new untracked files.
- **Rounds:** (1) full read of seven BIO-36 research briefs and their seven provenance sidecars (14 files, ~1,900 lines, downloaded as session attachments; listed below); (2) repository re-verification of every fact on which two or more briefs disagreed, plus spot-checks of the facts they agreed on; (3) reconciliation into one architecture; (4) self-review of labels, source references and repository status.

## Inputs

| Id | Brief | Sidecar read | Track |
|---|---|---|---|
| B1 | `continuous-room-mapping-ios.md` | yes | Apple platform capability matrix, client gates, LiDAR policy |
| B2 | `evolving-room-model-options.md` | yes | representations, alignment/fusion, drift, bandwidth, S0–S3 |
| B3 | `match-durable-object-evolving-map.md` | yes | Cloudflare DO constraints, retention/fusion split, recovery, versioning |
| B4 | `zero-step-room-understanding.md` | yes | wire messages, collision ordering, degradation ladder, replay/epochs |
| B5 | `zero-step-room-understanding-and-authoritative-combat.md` | yes | release drift audit, release architecture, physical matrix M1–M15 |
| B6 | `client-evidence-threat-model.md` | yes | threat matrix, corroboration, attestation, trust tiers, privacy |
| B7 | `zero-step-play-product-model.md` | yes | product model, terminology, gating rules, acceptance criteria |

All seven were written 2026-09-26 against the same commit and all seven sidecars state that no physical device was used. None is committed to the repository; the synthesis cites them as B1–B7 and does not assume the reader has them.

## Repository verification performed in this synthesis

Commands were read-only (`grep`, `sed`, `read`, `git status`, `git rev-parse`). Facts re-checked against source:

| Fact | Where | Result |
|---|---|---|
| Live targeting configuration has no `planeDetection` | `ios/…/Targeting/TargetingSession.swift` L1002–1012 (`ARBodyTrackingConfiguration` / `ARWorldTrackingConfiguration`, `worldAlignment = .gravity` only) | confirmed — settles disagreement 1 below |
| `planeDetection` set only in frame-mapping / install / MapLab paths | same file L1431, L1666, L1676; `Targeting/MapLab/MapLabARDriver.swift` L137 | confirmed |
| Sighting never applies the mapping configuration | `Features/Realtime/RealtimeArenaController.swift` L443–453 (`guard … !usesSighting`) | confirmed |
| No mesh/depth/scene-reconstruction consumer under `ios/` | `grep` for `ARMeshAnchor`, `sceneReconstruction`, `ARPlaneAnchor` | absence confirmed |
| `fire` shape and `BodyObservation` fields; `uncertaintyMeters: 0.08` constant | `packages/combat-protocol/src/index.ts` L25–31, L65; `RealtimeArenaController.swift` L393 | confirmed |
| `LIMITS` values (16 KiB / 128 KiB / 384 000 / 60 cmd/s / 64 per tick / 512 / 1024 / 128 / 8 MiB / 120 s) | `index.ts` L2–8 | confirmed |
| Body gates `0.8` / `0.1 m` / `COVER_OBSERVATION_MS = 1_000` / `BODY_ANCHOR_METERS = 2` / `MAX_SPEED = 15` / `pose.tracking !== "normal"` refusal | `combat-simulation/src/index.ts` L185, L283–289; `history.ts` L6–10 | confirmed |
| `resolveFlights` comparator `atMs → projectileId → distance → shield-before-body → targetId → zone` | `combat-simulation/src/flight.ts` L167–168 | confirmed |
| `CombatRoom` epoch bump on restore, 24 h retention, `storage.sync()` after commit | `services/combat-worker/src/room.ts` L21, L58, L405 | confirmed |
| SQLite tables incl. `schema_migrations`, `shared_maps`, `map_chunks` | `store.ts` L41–66 | confirmed |
| `selectCombatGeometry` sighting iff roster ≤ 2 | `convex/functions/combat.ts` L31–36 | confirmed |
| Deploy workflow has no Worker step | `.github/workflows/deploy.yml` (`grep wrangler|combat` → none) | confirmed |
| Build-log 2026-09-17 (iPhone 14 / iPhone 16 multi-room failure; iOS versions not recorded) and 2026-09-22 ("Linking play area" stall, 288 KB relay hypothesis) | `docs/build-log.md` L5, L534 | confirmed |

Not re-verified here and taken from the briefs (each brief cites file:line): `validation.ts` exact-key behaviour; Convex `prepare`/`ticket`/`publishProjection` details; `combat-deploy.mjs` guard list and `not-tested` acceptance fields; `promotion-gate.mjs`/`deployment-gate.mjs` shape; iOS `Envelope.v` and ticket `v` literals; `BulletLedger` and replay `default:` branch; `contracts/fixtures` not referenced under `ios/`.

## Disagreements between briefs and how each was resolved

1. **Plane detection during live Quick Play** — B1 ("In app today: Yes"), B2 ("enabled but discards anchors"), B4 ("enabled but unused") vs B5/B7 ("only in frame-mapping paths"). Resolved by source in favour of B5/B7; B1 §6.1 and B2 rec. 2 are re-scoped in the synthesis (§3.1 item 1). This also removes the only indirect device grounding any brief had for plane yield.
2. **Live session configuration** — B1 assumes `ARWorldTrackingConfiguration`; source shows `ARBodyTrackingConfiguration` where supported. Resolved by source; Apple documents `planeDetection` on the body configuration and scene reconstruction/collaboration on world tracking only.
3. **`ARPlaneAnchor.Classification` includes `door`/`window`** — B6 cites the Apple page; B5 marks unverified. Kept as documented with device behaviour unverified.
4. **Where fusion runs** — B3 (DO owns transform + fused snapshot, fusion in DO outside the tick) vs B2 (transform estimation and geometry fusion on phones; DO stores metadata) vs B1 (DO aligns patches server-side). Resolved as: DO owns *acceptance*, tier, `mapEpoch`, manifest and bounded sparse patches; DO may run bounded hypothesis scoring outside the tick; DO never runs ICP/bundle adjustment/mesh or occupancy fusion; dense fusion and queries on phones (§6.1, §7.4). Inference, not sourced.
5. **Single vs second DO class** — B3 (single) vs B7 (open). Resolved: single class now; re-open on measured tick contention (§13, §16).
6. **Confidence ladder naming** — B7 C0–C3, B2 S0–S3, B1 T0–T3, B3 none/coarse/aligned/saved-arena. Unified as R0–R3 + Arena (§7.5) with each brief's tiers mapped in the table; thresholds remain the briefs' placeholders.
7. **Effect of surface evidence on a shot** — B5 ("refuse with `occluded`") vs B4 (terminal `surfaceHit`) vs B7 ("fall back rather than refuse"). Resolved: shot accepted and resolved with a distinct terminal reason; refusal reserved for invalid body evidence (§8.2).
8. **Trajectory transport** — B4 new batched `trajectory` command vs B3/B5 retain the existing `pose` stream. Resolved: retain `pose`, add a bounded ring in the DO; batching deferred (§8.3, §16).
9. **Patch cadence/size caps** — B4 (≤ 4/s, ≤ 2 KiB, ≤ 256 live), B2 (≤ 1 msg/s × 50 × ~100 B), B3 (≤ 64 KiB/msg, ≤ 2 MiB/player). All are budgets against the same repository limits; none is measured. Kept as competing placeholders behind one acceptance row (§8.4, §15 B2).

## Sources accepted

- **Official vendor documentation** — only pages that at least one brief fetched and cited by URL, with no brief contradicting the claim: Apple ARKit/Vision/DeviceCheck/App Store pages (synthesis §18 items 1–16, 29), Cloudflare Workers/Durable Objects pages (17–26, 28, 30), Convex environment variables (27). Every URL in §18 was checked to appear verbatim in at least one brief's source list. Access dates and rendering caveats are those recorded in the briefs' sidecars (several Apple pages render JS-only and were read via the `.md` endpoint or a mirror; the synthesis inherits those caveats and does not add new fetches).
- **Repository** — files listed in §18, read at `0750e9b`.
- **Academic / practitioner** — Slocum et al. (USENIX Security 2024), Kimera-Multi, ORB-SLAM3, Gambetta; used only as marked in B2/B6 for attack taxonomy and multi-map aliasing, never for a repository or platform fact.

## Sources rejected or caveated

- Any brief statement about device behaviour (time-to-first-plane, merge time, collaboration byte rate, thermal cost, raycast accuracy, body-range error, anchoring false-positive rate) — carried only as an unmeasured item in §15/§17; where a brief guessed a target number it is quoted and labelled speculation.
- B1's "Both phones run `ARWorldTrackingConfiguration` with plane detection (already true)" and B2's "start consuming the plane anchors the session already detects" — rejected at source (disagreement 1).
- B1's LiDAR device list — kept only for the iPhone 16 Pro / 17 Pro models whose Apple support-page sections B1 states it fetched; older Pro models are not asserted.
- Cloudflare storage tier figures (10 GiB Paid / 1 GiB Free), CPU-limit configurability and hibernation/eviction timings — reported as the briefs recorded them and flagged as living documents to re-read before any ADR.
- Unity/Niantic/ARCore and other non-Apple platform material referenced by earlier repository research — not used.

## Speculation explicitly marked in the synthesis

Every numeric threshold in §6–§11 (patch caps, decay constants, residual bounds, c₁/c₂, σ < 2 m, t_stable, tick slice ≤ 5 ms, ring 60 s); the mutual-sighting estimator's convergence; usefulness of ARKit collaboration as a hypothesis source; door/window classification behaviour on non-LiDAR phones; the fused-frame paged snapshot; App Attest latency; every "guessed" target time in §15 (A1 < 10 s, D1 σ < 2 m within 1 min, D2 < 2 %).

## Evidence versus inference by synthesis section

| Section | Evidence base |
|---|---|
| §3 repository facts | repo, re-verified here |
| §4 platform constraints | official docs as cited by the briefs |
| §5 ownership | repo + AGENTS.md; unassigned paths flagged as open |
| §6 DO model | Cloudflare docs + repo store pattern; retention/fusion split is inference; schema and caps are proposal |
| §7 map and fusion | representations: B2 derivations + Apple docs; estimator/tiers: proposal; costs: unmeasured |
| §8 shot evidence | current ordering: repo; extension and rule: proposal |
| §9 security/privacy | repo trust boundary + Apple App Attest/privacy docs + B6 threat model; rules are proposal |
| §10 device policy | Apple docs; runtime-probe rule; behaviour unverified |
| §11 fallback table | existing rows: repo; new rows: proposal |
| §12 release | drift: repo (B5 audit); extensions: proposal, unimplemented |
| §13–§14 | inference/proposal |
| §15 acceptance plan | mandatory future work; nothing executed |
| §16–§17 | open |

## Verification pass

- Every §18 URL appears verbatim in at least one input brief's source list (checked by string match across the 14 files).
- Every repository line number quoted in the synthesis was read in this session; line numbers are as of `0750e9b`.
- No statement in the synthesis asserts physical-device behaviour as fact; the only device observations cited are the two build-log entries, quoted with their own limitations (iOS versions not recorded; hypothesis unconfirmed).
- No secret, credential, device identifier or raw sensor payload appears in either file.
- `git status --short` after writing lists only `docs/research/zero-step-architecture-synthesis.md` and `docs/research/zero-step-architecture-synthesis.provenance.md` as untracked; no tracked file changed.

## Known limits

- The synthesis inherits every fetch caveat of the seven sidecars; it made no new external fetches.
- Repository facts marked "taken from the briefs" above were not independently re-read here.
- The recommendation depends on §15 rows A1–A4 and B1 before any slice beyond 0–2 is engineered, and on D1–D2 before any shared-frame behaviour is designed in detail. Per AGENTS.md, none of this becomes an ADR without a named device, iOS version and build.
