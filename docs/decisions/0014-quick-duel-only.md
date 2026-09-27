# ADR 0014 — Quick Duel is the only mode; the shared frame is removed

Status: **accepted**, 2026-09-27. Records the product owner's decision tracked in [BIO-37](https://linear.app/biossphere/issue/BIO-37); the reasoning is [docs/research/multiplayer-identity-synthesis.md](../research/multiplayer-identity-synthesis.md) (§4 removal plan, §5 identity architecture, §7 trust model, §8 physical acceptance matrix) and the file-level inventory is [docs/research/shared-arena-removal-inventory.md](../research/shared-arena-removal-inventory.md). Integration owns this record. Nothing in this record is physical-device evidence.

Supersedes [ADR 0010](0010-quick-play-relocalized-frame-and-phone-proxy.md) and [ADR 0011](0011-quick-play-continuous-collaboration.md). Supersedes in part [ADR 0005](0005-duel-body-tracking-and-visible-shots.md), [ADR 0006](0006-duel-shared-frame.md), [ADR 0008](0008-realtime-combat-implementation.md) and [ADR 0009](0009-natural-scene-calibration-candidate.md), wherever they rely on a shared frame or on the `trackedBody` / `phoneProxy` geometries. Amends [ADR 0013](0013-quick-play-sighting-hits.md) (player cap and roster rule); ADR 0013 remains the foundation of the only mode.

**Absence:** there is no `docs/decisions/0012-*.md` in this repository. ADR 0013 refers to an "ADR 0012" (Nearby Interaction rendezvous, PR #105); that record was never committed here. This ADR does not cite, reconstruct or supersede it; the Nearby Interaction rendezvous it described is removed below as a concept.

## Context

Four records (ADR 0006, 0009, 0010, 0011, plus the uncommitted rendezvous record) tried to give co-located phones one shared coordinate frame. None aligned two phones in a recorded physical trial, and every one put a setup step in front of PLAY. ADR 0013 made camera sighting the Quick Play default and removed the frame gate for it, but kept the shared-frame machinery alive behind `trackedBody` (Saved Arenas) and `phoneProxy`. The owner has now decided that machinery does not return.

## Decision

1. **Quick Duel is the only play mode.** It is ADR 0013's camera body-sighting geometry. There is no second mode, no mode picker and no fallback geometry.
2. **Removed concepts (the owner's list).** The following are removed entirely and are not future options: the shared frame; Saved Arenas; scanning; alignment; relocalization; map linking; rendezvous (including Nearby Interaction); `ARWorldMap` save/load and map sharing; collaborative sessions; MapLab; and every ADR 0010 / ADR 0011 shared-frame concept (relocalized frame, phone-proxy verdicts, continuous collaboration, frame readiness). Code for them is deleted, not hidden. The dependency-ordered removal is synthesis §4.3 (R0–R9).
3. **Each phone keeps its own AR frame.** No participant needs, estimates or exchanges a common coordinate system. Nothing about a peer's pose is a hit input.
4. **The match Durable Object is combat authority.** The `CombatRoom` DO decides every verdict from the command batch it receives; Convex remains the lobby and durable ledger.
5. **Start is never gated by setup.** No scanning, alignment, relocalization, rendezvous, permission ritual or identity state may block `start`, block `fire`, pause a match or return it to setup. Ready means camera running and connected.
6. **Player target: 2–4, subject to the identity gate.** The product target is 2–4 players with zero setup, **subject to the identity gate in synthesis §5 and §8**: the cap stays at 2 until target identity for 3–4 players ships and passes the physical acceptance rows. This record does not raise the cap and does not choose an identity cue.
7. **Attribution rule (synthesis §5.4, thresholds deliberately omitted).** Inside the sighting branch, deterministically over the ordered command batch, the DO: (a) validates the sighting shape, refusing with `noSighting` when no body is in view; (b) applies the existing freshness and quality gates; (c) filters candidates to living, connected, non-shooter roster members — a candidate that is not on the roster at all is `invalidInput`, and zero survivors is `noSighting`; (d) renormalises the survivors' confidences; (e) attributes to the unique survivor, or with two or more survivors to the top candidate only if it leads the runner-up by a fixed margin, otherwise refuses with `ambiguousTarget`; (f) resolves geometry against the attributed player as today; (g) records the attribution basis (`sole` / `separated`) and corroboration (`shooterOnly`). There is no health-based tie-break, no split damage, no redirect to a player the shooter did not name, and no veto from a client's self-reported ambiguity. Refusals cost no ammo or cooldown. Two players is the same rule with one candidate. The margin and every other number are fixed by a later ADR from §8 device data, not here.
8. **Trust principle (synthesis §7).** Fail closed on attribution, fail open on corroboration, never fail at match scope. Nothing the client says about identity — candidate confidences, cues, bodies-in-view counts, ranging samples, appearance scores, a peer's self-reported pose or sighting — is a security input; they are honest-client fairness inputs and audit data. Trusted facts remain ticket claims, connection identity, the DO receive clock and sequence state. Colluding or modified clients can defeat cross-client checks; the model provides fairness among honest clients and auditability, not anti-cheat.
9. **Kept.** The debug-fire path, local surfaces (BIO-36, flag-off), the problem report path (`ReportProblemView` / `MatchReportClient` / `report.ts`, with the diagnostics type renamed mode-neutral and its wire shape unchanged), invite QR, `/health` and the release manifest.

## Consequences

- The product is a working two-player Quick Duel at every removal step; mixed client versions keep working while the server still accepts removed messages (synthesis §4.3).
- 3–4 player play is not available until the identity gate is met; with no discriminating cue, every multi-opponent sighting would be refused by rule 7.
- Historical ADRs keep their text for provenance; their status lines point here.

## References

- [docs/research/multiplayer-identity-synthesis.md](../research/multiplayer-identity-synthesis.md) — §4 (removal plan and stack), §5.4 (attribution rule), §7 (trust model), §8 (physical acceptance matrix), §10 (decisions O1–O13)
- [docs/research/shared-arena-removal-inventory.md](../research/shared-arena-removal-inventory.md) — file-level inventory
- [docs/research/zero-step-architecture-synthesis.md](../research/zero-step-architecture-synthesis.md) — BIO-36 predecessor (authority, local surfaces, confidence-is-a-hint)
