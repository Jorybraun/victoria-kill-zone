# Provenance — multiplayer-identity-synthesis.md (BIO-37)

## Scope and mode

- Linear: [BIO-37](https://linear.app/biossphere/issue/BIO-37). Principal-architect synthesis of seven independent briefs into one recommendation.
- Mode: **read-only research.** No source file was edited; no branch, commit, push, PR, deployment, ADR, Linear update or device trial was made. The only files written are this sidecar and `docs/research/multiplayer-identity-synthesis.md`, both left **uncommitted** in the working tree.
- Repository: `Jorybraun/victoria-kill-zone`, local checkout on `main` at `3d89b7f` (clean tree before writing), read on 2026-09-27.
- Predecessor: `docs/research/zero-step-architecture-synthesis.md` and its sidecar (BIO-36), used as the settled baseline and as the style template; not re-derived.

## Fixed inputs taken from the product owner (not re-argued)

Shared frame / Saved Arena removed permanently (ADR 0010/0011, `SharedArena`, `DuelFrame`, scanning, alignment, relocalization, map-linking, rendezvous, `ARWorldMap` save/load, collaborative sessions); Quick Duel / ADR 0013 sighting is the only mode; per-phone AR frames; `CombatRoom` DO authority; start never gated by setup; 2–4 players, zero setup; Convex knows the roster; BIO-36 local-surface / bounded-evidence plan stays valid where compatible.

## Research rounds

1. **Input recovery.** All seven briefs and seven provenance sidecars were obtained through the session attachment mechanism. An earlier direct `curl` attempt returned `{"detail":"Unauthorized"}` and produced empty files under a scratch directory; those were discarded and never used as sources.
2. **Baseline.** Read `AGENTS.md`, the BIO-36 synthesis and sidecar, ADR 0010, 0011, 0013, and the `docs/decisions/` listing (0012 absent).
3. **Brief reading.** Each brief and sidecar read in full; claims tagged by the brief's own label (repo / platform / inference / proposal / speculation / absence).
4. **Primary re-verification.** Every repository fact the synthesis depends on for a decision, and every point on which briefs disagreed, was re-read at `3d89b7f` (list below).
5. **Reconciliation.** Eleven disagreements resolved (§3.2 of the synthesis; reasons below).
6. **Authoring and self-check.** Synthesis written; load-bearing file:line citations re-checked after writing (config default, interface-contracts sentence, `Info.plist` key, refusal copy, store version check, `resolveSighting` health/protection check, idle retention, `DuelPeerLink` conformers, player-facing strings).

## Sources

### Input briefs (all accepted; each is an uncommitted 2026-09-27 document against `3d89b7f`)

| Id | Brief | Sidecar | Notes on use |
|---|---|---|---|
| B1 | `shared-arena-removal-inventory.md` | `shared-arena-removal-inventory.provenance.md` | Inventory, keep-list, PR stack, ownership gaps, ADR status edits. Step 6 (cap raise bundled) re-sequenced. |
| B2 | `vision-opponent-identification.md` | `vision-opponent-identification.provenance.md` | Identity signal matrix, rejected signals, `identity` block idea (folded into `cue`/`trackAgeMs`). "Plausibly in view" elimination corrected (needs a shared frame). |
| B3 | `radio-ranging-identification.md` | `radio-ranging-identification.provenance.md` | Plain NI bearing as optional shooter-side cue; Camera Assistance and BLE RSSI rejected; measurement list for §8.3. |
| B4 | `multi-target-protocol-authority.md` | `multi-target-protocol-authority.provenance.md` | Wire shape, policy D, two-player worked case, ledger fields, additive compatibility. Health tie-break and mutual-sighting bonus not adopted as verdict inputs. |
| B5 | `roster-ux-multiplayer.md` | `roster-ux-multiplayer.provenance.md` | Product model, copy audit, HUD states, slot glyph/colour. O4 (local fail-closed trigger) resolved differently: shot still sent. |
| B6 | `trust-multi-target.md` | `trust-multi-target.provenance.md` | Threat matrix, fail-open/closed table, tiers. Pair-transform estimator and `identityMismatch` veto rejected as frame estimation; "Backend owns simulation" corrected per `AGENTS.md`. |
| B7 | `device-validation-multiplayer.md` | `device-validation-multiplayer.provenance.md` | Device classes, rosters, scenarios, metrics, evidence capture E1–E6, fixture gaps. Adopted with S0b/X2 rows made explicit. |

### Repository files re-read at `3d89b7f`

`AGENTS.md`; `docs/research/zero-step-architecture-synthesis.md` (+ provenance); `docs/decisions/0010-*`, `0011-*`, `0013-*` and directory listing; `docs/interface-contracts.md` (Realtime combat v1 paragraph, ~L704); `packages/combat-protocol/src/index.ts` (L45–68 rules, defaults, `rulesSchemaKeyPaths`), `validation.ts`; `packages/combat-simulation/src/index.ts` (L262–300 fire path; refusal before `p.ammo--`), `flight.ts` (L87, L126–151), `history.ts`, `state.ts`, `tests/sighting.test.ts` (L80–83); `services/combat-worker/src/room.ts` (L22 idle retention, L44, L160–161, L231–233 `niToken`), `store.ts` (L41–42, L58–67 including version check L66–67, L120–133 pruning), `report.ts`, `bullet-ledger.ts`, `routes.ts`; `convex/functions/combat.ts` (L27), `matches.ts`, `schema.ts`, `convex/domain/config.ts` (L8), `fire.ts`, `convex/functions/shots.ts`; iOS `Targeting/TargetingSession.swift` (L1173), `Features/Realtime/RealtimeBodyAssociation.swift` (L17–18, L61), `RealtimeArenaController.swift` (L423), `RealtimeCommandState.swift` (L58–75), `CombatWire.swift`, `ReportProblemView.swift`, `Services/Realtime/MatchReportClient.swift`, `RealtimeCombatSession.swift` (L182), `Domain/LobbyModels.swift` (L233, L240, L247, L250), `Features/Lobby/LobbyStore.swift` (L160), `WaitingRoomView.swift` (L90), `Features/Home/HomeView.swift` (L27, L30, L88, L135), `Features/Game/DuelPeerLink.swift`, `App/RootView.swift`, `App/AppEnvironment.swift`, `Features/Arenas/*`, `Features/MapLab/*`, `Targeting/SharedArena/*`, `Targeting/QuickPlay/SharedOrigin*`, `Targeting/NearbyInteraction/*`, `Info.plist` (L53); `ios/VictoriaKillZone/Package.swift`, `project.pbxproj`, `Transport/CombatTransport/**`; `scripts/ci/check-xcode-sources.py`, `verify-ios.sh`, `check-release-manifest.mjs`; `release-manifest.json`; `contracts/fixtures/combat.v1.json`; `scripts/combat-replay/scenarios.ts`; `scripts/release/combat-deploy.mjs`; `spectator/src/components/MatchHeader.tsx` (L24), `spectator/src/data/demoFixtures.ts`, `spectator/src/domain/spectator.ts`; `docs/build-log.md` (searched for sighting / ADR 0013 entries: none).

### Vendor documentation

Apple and Cloudflare pages listed in §13 of the synthesis were **not re-fetched** in this synthesis; they are cited as quoted by the named briefs, whose sidecars record the fetch. Where a brief recorded a failed fetch (B4 on Nearby Interaction pages), the claim was taken only from a brief that did fetch it (B3), or left as an absence.

### Rejected or not used

- Empty/unauthorized `curl` downloads (not sources).
- Any claim of device accuracy, latency, thermal cost or session concurrency not stated by a vendor page — none exist; treated as absences.
- Practitioner/academic sources on multi-target identity in phone AR — none found by any brief.

## Reconciliation decisions (reasons)

1. Ambiguity: refuse when candidates do not separate (B2/B4/B5); apply + `shooterOnly` when they separate but lack corroboration (B6). Different questions, both honoured.
2. Pair-transform veto (B6 §5.1): rejected — estimating a cross-phone rigid transform is shared-frame alignment, which the owner removed.
3. Frame-dependent "plausibly in view" elimination (B2 §3.10): corrected to frame-free facts only.
4. Mutual-sighting bonus (B4): ledger-only; a peer self-report must not move a verdict (B6 §4.4).
5. Lowest-health tie-break (B4): rejected as the attack payoff (B6 §4.1); positive margin makes ties unreachable.
6. Client margin field: not on the wire; derived by the DO from candidates.
7. `bodiesInView`: recorded; only `< 1` rejected; never raises ambiguity for others.
8. NI code: deleted in removal; any bearing cue re-enters as a new, evidence-gated slice.
9. Ownership: `AGENTS.md` wins; unassigned paths provisionally Integration, flagged O8.
10. Cap switch: last slice, gated on physical rows.
11. Slot glyph/colour: HUD presentation only, not a worn/displayed identity signal.

## Verification performed

- Repository state: `git status` before writing showed a clean `main` at `3d89b7f`; after writing, only the two new untracked files.
- Re-read of every file:line cited as **[repo]** in the synthesis (listed above).
- **Not run:** `pnpm verify`, `pnpm verify:ios`, any unit/contract/fixture test, simulator, staging probe or deployment — no code changed. No physical device was used.

## Known limitations

- No physical-device evidence exists for any claim; every threshold (margin `0.35`, freshness, candidate ages, misattribution targets) is a placeholder.
- Line numbers are accurate at `3d89b7f` only.
- The seven briefs were written by independent agents on the same day against the same SHA; their agreement on repository premises is corroborating, not independent verification of platform behaviour.
- Vendor pages were not re-fetched; wording could have changed since the briefs fetched them.
- Ownership of unassigned paths is a proposal, not a repository fact.
- Copy replacements are proposals pending the Design owner's slice freeze.

## Statement

This synthesis makes no implementation, build, test, deployment or physical-device claim beyond what is listed under "Verification performed". It recommends; it does not decide.
