# Plan: markerless-multiplayer-ar

## Trigger

Physical-device trial of collaborative Quick Play (ARKit `CollaborationData`
relay + `ARParticipantAnchor` merge) on latest TestFlight build: user reports
"room scanning is definitely not working." Goal: determine whether our
collaborative alignment architecture is sound and correctly implemented, or
whether a different bootstrap strategy is warranted.

## Key questions

1. **ARKit collaboration mechanics** — how do `isCollaborationEnabled`,
   `ARSession.CollaborationData`, and `ARParticipantAnchor` actually merge
   sessions? What are Apple's documented requirements (proximity, iOS version
   parity, lighting/features, first-exchange bootstrap)? What failure modes do
   developers report on-device (merge never happens, deltas not emitted,
   participant anchor absent)?
2. **What shipped co-located AR games actually use** — ARWorldMap
   share+relocalize vs ARSession collaboration vs image/object anchor bootstrap
   vs Niantic Lightship/VPS vs hybrid. What does evidence say about reliability
   in ordinary rooms?
3. **Player-report + diagnostics pipelines** — patterns for bundling voice
   notes, logs, and device metadata from mobile games; crash reporting
   (MetricKit/Sentry) appropriate for a 4-player AR game in TestFlight phase.
4. **Synthesis** — is our current design (continuous collaboration, no initial
   scan) the right architecture? If merges are unreliable in practice, what is
   the best bootstrap/repair strategy (e.g., anchor-assisted bootstrap then
   collaboration for relocalization)?

## Evidence needed

- Apple docs/WWDC on collaborative sessions + ARParticipantAnchor
- Developer reports of collaboration merge behavior on physical devices
- Docs/blogs on Lightship VPS, shared AR in shipped titles
- Our implementation audited against documented requirements

## Scale decision

Subagents (3 parallel researchers) — broad multi-domain survey:
- R1: ARKit collaboration internals + on-device failure modes
- R2: Alternative alignment architectures in shipped games
- R3: Mobile-game report/diagnostics pipeline patterns

## Task ledger

- [x] Plan written; user confirmed sequencing (fix bugs, then research)
- [x] Immediate defects fixed: audio-session config + ticket lifecycle (PR #103)
- [ ] R1/R2/R3 evidence gathered
- [ ] Draft synthesized vs our implementation
- [ ] Citations verified; provenance written
- [ ] Physical setup-log from user trial correlates merge-failure hypothesis

## Verification log

- (pending)

## Decision log

- 2026-09-17: user confirmed latest TestFlight build — collab path is what
  failed, not legacy frozen-map flow
- 2026-09-17: sequence = fix report defects first (PR #103), then research
