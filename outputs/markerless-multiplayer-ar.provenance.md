# Provenance: markerless-multiplayer-ar

- **Date:** 2026-09-17
- **Rounds:** 1 (3 parallel researcher subagents: R1 ARKit internals, R2 alternatives, R3 report pipelines) + lead-agent code audit of the repo's collab path
- **Sources consulted:** ~89 across the three research files (R1: 19, R2: 38, R3: 32)
- **Sources accepted:** all; no fabrications flagged by researchers; R1 notes some Apple docs were read via a mirror (canonical URLs recorded)
- **Sources rejected:** none reported
- **Verification:** PASS WITH NOTES — headline claims trace to Apple primary docs + WWDC transcripts; community failure reports marked medium confidence; exact merge timing (10–30 s) is a single vendor source
- **Plan:** outputs/.plans/markerless-multiplayer-ar.md
- **Research files:** outputs/.drafts/markerless-multiplayer-ar-R1.md, -R2.md, -R3.md
- **Code evidence:** DuelFrameProvider.swift, TargetingSession.swift (lines 1373–1446, 1706–1774), RealtimeArenaController.swift (wireCollaboration), RealtimeCombatSession.swift (sendCollaboration), services/combat-worker/src/room.ts + connection.ts + packages/combat-protocol/src/index.ts (relay, budgets, limits)
