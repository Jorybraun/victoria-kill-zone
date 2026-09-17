# ADR 0011 — Quick Play: continuous collaborative mapping instead of one-shot map share

Status: **proposed**, 2026-09-17. Owner acceptance is required before implementation lanes may proceed. Integration owns this record, the transport wiring and the client flow; targeting owns the session/policy changes; design owns the slice update. Nothing in this record is physical-device evidence beyond the cited trial observation.

## Context

ADR 0010 (accepted 2026-09-16) shipped relocalized Quick Play: the host captures a raw `ARWorldMap`, uploads it through the map service, and each joiner installs it and relocalizes. That stack merged under PRs #87/#89/#90/#91 and is on TestFlight build 61.

The first physical trial of that design produced a real finding (2026-09-17): the host completed a successful scan, but a joiner physically located in a different room could not join. This is ARKit physics, not a defect: relocalization requires the joining camera to see visual features present in the shared map, and a map that only covers room A contains nothing a camera in room B can match. The one-shot design hard-codes this boundary — the shared map is frozen at share time and covers only where the host happened to scan.

Owner direction: the game is **free-roaming multi-room**, not a single contiguous scanned area. Under that direction the one-shot share is the wrong transport, regardless of how well it is implemented.

`SharedArenaSession` (built as the KIL-49 alignment experiment, currently only reachable through `SharedArenaHarnessView`) already implements Apple's collaborative-session model: `isCollaborationEnabled` on the world-tracking configuration, `didOutputCollaborationData` → `NSKeyedArchiver` → `.collaboration` link messages with bounded pre-link buffering, `session.update(with:)` on receipt, a shared-origin `ARAnchor` for a common pose frame, and pose streaming. `FallbackArenaPeerLink` already carries `.collaboration` messages with chunked bulk transfer over local QUIC (Bonjour).

## Decision

Quick Play replaces the one-shot map share with **continuous collaborative mapping** (peer-to-peer `ARSession.CollaborationData` exchange for the life of the match).

1. **Session**: every Quick Play participant starts its world-tracking session with `isCollaborationEnabled = true` from the beginning (Apple: enabling it later restarts the session). There is no separate host scan phase.
2. **Exchange**: `didOutputCollaborationData` payloads are serialized with `NSKeyedArchiver` and sent over the match's peer link as `.collaboration` messages — `.critical` reliably, `.optional` best-effort — using the existing `ArenaLinkMessage` type and chunked bulk transfer. Received payloads are applied with `session.update(with:)`.
3. **Transport**: the peer link (`FallbackArenaPeerLink`, local QUIC primary) is wired into the Quick Play realtime flow. Participants are co-located by definition, so local P2P is the intended channel; a server-relayed fallback may be added if trials show the local link insufficient.
4. **Alignment**: a participant is *aligned* once its session has merged shared-map content (collaboration applied successfully), not once it relocalizes into a fixed archive. Alignment is continuous — it can complete at any time during setup or the match, whenever the camera first sees features present in the union map.
5. **Shared frame**: the host plants a named shared-origin `ARAnchor` at its session origin; the anchor propagates through collaboration data. Combat poses are expressed relative to that origin, following the existing `SharedArenaSession`/`arenaFromPhone` pattern. `phoneProxy` verdict geometry (ADR 0010) is unchanged — only the alignment transport changes.
6. **Removed from Quick Play**: host scan → `captureMap` → upload → download → `installMap` → timed relocalization, plus the Sharing stage and the map-store dependency for unsaved matches. The offline Scan & Save feature and saved-arena measured mode (reference capture, `trackedBody` geometry, world-map install) are unchanged.
7. **iOS version parity**: Apple documents that unarchiving collaboration data may fail across OS versions. The client must surface a clear incompatibility message rather than a generic failure, and trial evidence must record both devices' iOS versions.
8. **Cover mechanic**: `phoneProxy` verdicts alone admit through-wall hits — the worker checks ray/sphere intersection against a shared frame that contains no walls, and the HUD projects opponent positions, so blind wall shots would be trivial. Owner decision: cover must be real — if you cannot be seen, you cannot be hit. A `phoneProxy` hit therefore additionally requires a recent (bounded freshness window, ~1 s) Vision body observation of the victim *by the shooter* — soft per-shot coverage, not the old match-pausing rule. Coverage drops degrade offense, never pause the match; a victim's own tracking state does not protect them.

## What changes for the player

- CREATE ARENA no longer has a host "Scan the area"/"Share arena" step. Everyone enters "Move toward the play area" and aligns as soon as their camera sees space anyone else has mapped.
- Multi-room play emerges naturally: as any participant roams, their new coverage merges into everyone's map. A joiner starting in another room aligns the moment they reach any overlap (e.g. a doorway the host mapped through).
- The aligned/degraded/lost recovery model is unchanged; recovery now also benefits from a continuously growing union map.

## Consequences

Positive:
- Multi-room and free-roaming play become possible without a separate mode.
- Setup loses its most failure-prone step (timed one-shot share) and its strictest gate (15 s relocalization window).
- The shared map improves during play instead of being frozen at share time.

Negative / risks:
- Alignment still requires visual overlap — a participant sealed in space nobody has mapped cannot align until they reach some mapped feature. This is inherent; copy must say "move toward the play area," not promise instant join.
- Collaboration bandwidth is continuous for the match's duration, not one burst. `.optional` data must be droppable; link congestion policy needs a bound.
- iOS version parity is a hard constraint for unarchiving; mixed-OS sessions need explicit detection and copy.
- Soft coverage reintroduces a bounded version of the tracked-body dependency: body tracking must function during combat for offense to work at all, and partial-body visibility edge cases will favor cover (a conservative bias — failures protect the victim, never gift a hit).
- The merged one-shot relocalized mode becomes dead code for Quick Play setup; saved-arena measured mode still uses the install path.

## Alternatives considered

- **Keep one-shot share, require the host to walk the whole play area while scanning**: works for small multi-room venues at zero code cost, but keeps a fragile UX (map frozen at share time; joiners still need host-mapped overlap) and does not scale to roaming play. Retained as a fallback procedure for the current build, not as the design.
- **Bootstrap with one-shot share, then continue with collaboration**: fastest first-alignment when it works, but keeps the upload/share stage, the map store, and the failure mode this trial exposed — while the first `.critical` collaboration payload already carries what a merge needs. Rejected as duplicate machinery.
- **Relay collaboration data through the combat worker/Convex instead of local P2P**: works across networks but adds continuous server bandwidth and latency for players who are physically co-located anyway. Deferred; revisit if local-link trials fail.

## Evidence to collect (before production confidence)

Two phones, same iOS version, named models and build:

1. Both phones start in the same room → align without any scan step; time to alignment recorded.
2. Joiner starts in a different unmapped room → shows "move toward the play area"; aligns on reaching overlap; total time recorded.
3. During a match, a player roams into an unmapped room → their coverage merges; a second player later aligns there.
4. Combat at ~3 m and ~8 m after roaming alignment: phoneProxy verdicts, health/ammo/K-D convergence.
5. Cover check: shots at a victim who moved fully behind a wall within the freshness window do not register; the same shot with line of sight does.
6. Mixed-iOS-version pair → incompatibility surfaced cleanly (expected failure, not a crash).
7. Setup-log export captured on both phones for each run.
