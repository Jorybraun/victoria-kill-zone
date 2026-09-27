# Provenance: Roster UX for 2–4 player Quick Duel (BIO-37, slug `roster-ux-multiplayer`)

- **Date:** 2026-09-27 (all URLs accessed this date; repository state `main` @ `3d89b7f`, clean, up to date with `origin/main`).
- **Rounds:**
  1. Prior-art pass over in-repo research: zero-step-architecture-synthesis.md (+ provenance), zero-step-play-product-model.md (+ provenance), shared-arena-frame-options.md (+ provenance, for style and the reused Nearby Interaction source), ADR 0013, AGENTS.md (Phase 1 cap 4). Used to avoid repeating BIO-36 and to diff the new audit against BIO-36's §3 route audit.
  2. Source audit of player-facing iOS surfaces: `App/RootView.swift`, `Features/Home/HomeView.swift`, `Features/Lobby/{JoinDuelView,WaitingRoomView,LobbyStore}.swift`, `Domain/LobbyModels.swift`, `Features/Realtime/{RealtimeArenaView,RealtimeArenaPresentation,RealtimeArenaPolicy,RealtimeArenaController,RealtimeBodyAssociation,RealtimeCommandState,RealtimeReferencePanel}.swift`, `Services/Realtime/RealtimeCombatSession.swift`, `Targeting/TargetingSession.swift`.
  3. Authority/admission audit: `convex/functions/{schema,matches,combat}.ts`, `packages/combat-protocol/src/index.ts`, `packages/combat-simulation/src/{index,flight}.ts`.
  4. Terminology sweep: `rg -i` over string literals for `scan|align|arena|relocaliz|calibrat|linking|squad|play area|shared frame|reference|map` in `ios/VictoriaKillZone/VictoriaKillZone/{App,Features,Domain,DesignSystem,Services}`, per-file counts, then manual classification of every hit in active/lobby/home files into categories A–D.
  5. PR state: #134 and #135 viewed via the repository's PR tooling (`gh` CLI was unauthenticated for this remote and was not used); #135 branch diff (`origin/devin/1790480685-quick-duel-review-fixes`) read for new player-visible strings.
  6. Primary-documentation pass: Apple Vision (VNDetectHumanBodyPoseRequest, Detecting Human Body Poses in Images), ARKit (ARBodyTrackingConfiguration, ARBodyAnchor, ARFrame.detectedBody), HIG (Accessibility, Color).
  7. Synthesis and self-review.
- **Sources consulted:** 9 external pages fetched (the 8 cited plus one failed fetch, below); ~25 repository files; 2 PR descriptions; 1 branch diff.
- **Sources accepted:** 8 numbered sources, all Apple primary documentation; source 8 (Nearby Interaction session guidance) reused from shared-arena-frame-options.md source 23 and not re-fetched this round. No practitioner sources were needed or used.
- **Sources rejected / caveats:**
  - `developer.apple.com/documentation/nearbyinteraction/ninearbyobject/direction` returned no content on two fetch attempts; not cited. NI facts are limited to what BIO-36 already verified, and the brief does not choose an identity mechanism.
  - No Cloudflare documentation consulted: every authority claim in the brief is a repository fact (simulation/admission rules); Durable Object runtime/deploy behaviour was established by BIO-36 and is not re-argued.
  - PR #135 is **open**, not merged; the brief audits `main` and treats #135's single new string as pending. Its lifecycle after 2026-09-27 was not tracked.
  - The terminology counts (≈68 Saved Arena lines, ≈42 Map Lab lines) are line counts of regex hits, not an exact string inventory; categories B's Arenas/MapLab rows are listed as "whole feature" rather than string by string. Category A (normal-path) strings were each read and listed individually.
- **Speculation explicitly marked in the brief:** everything in §4–§7 (product model, colour/slot assignment, glyph scheme, identity-state table, fail-closed trigger policy, opponent strip, kill feed, shooter-name feedback, degraded-state table), the "Limited targeting" badge, the ≤ 5 s START-to-live target, and the inference that a kill feed is derivable from existing events without a protocol change.
- **Verification:**
  - Every `[Apple n]` citation resolves to the source list (n = 1–8, each used at least once); no orphan sources.
  - Repository claims re-checked against source text: `QuickDuel.maxPlayers = 2` and `rosterFullMessage`; `QUICK_DUEL_MAX_PLAYERS = 2` in create/join/prepare; `prepare` requires ≥ 2, all connected (≤ 15 s) and all ready; simulation `opponents.length !== 1 → ambiguousTarget`, `targetPlayerId` mismatch → `invalidInput`, `associationConfidence < 0.8 | uncertaintyMeters > 0.1 | no colliders → noSighting`; `associateSighting` exactly-one-opponent; targeting keeps one ARKit anchor (`first(where: isTracked)`) or one Vision candidate (`max(by: score)`); `applyBodyHit` event order (shooter changed → terminal → target changed); target cue label source; roster strip shown only in the match menu; refusal copy strings; absence of colour fields in `players` schema and `CombatPlayerState`.
  - Apple quotations checked verbatim against fetched pages ("returns a unique observation for each detected human body pose"; "tracks the movement of a single person"; "Convey information with more than color alone"; "Avoid relying solely on color…").
  - Confirmed the brief does not re-derive BIO-36 conclusions (frame architecture, deployment, evidence model); those are referenced.
  - `git status` shows only the two new untracked files under `docs/research/`.
- **Not done (by instruction):** no code edited, no branch created, no commit, no push, no PR, no deployment, no build or test run, no device trial.
- **Known limits:**
  - No physical-device evidence exists for any sighting behaviour; all device-dependent acceptance criteria (5, 15) and legibility/colour claims are targets.
  - The UX contract assumes an identity source that reports per-shot `targetPlayerId` with confidence; the choice of that source (ADR 0013 point 8) is out of scope and may change §5.4/§7 (e.g. whether "Limited targeting" exists).
  - The "Unidentified" state presumes multi-candidate body detection, which the current targeting code does not provide (it forwards one body per frame).
  - Classic (non-Durable-Object) mode copy was flagged, not resolved.
  - Rematch mechanics and lobby lifecycle after results were not audited.
