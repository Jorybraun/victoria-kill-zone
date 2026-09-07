# Saved arenas — accepted local setup slice

Status: Ready. Integration accepted for the user's request to scan before a game
and keep the map for future games. Depends on PR 69's bounded scan recovery.

## Outcome

A host prepares a named arena before creating a match, then reuses that scan in
future matches from this phone. Guests receive the same bytes through the existing
authenticated match service. Every phone still establishes fresh alignment.

## User journey

- Home: `CREATE ARENA` opens the arena library in selection mode. `SAVED ARENAS`
  opens the same library for preparation and management. `JOIN ARENA` stays direct.
- Empty: `Your arenas, ready to play` and `Scan a room once, then reuse it for your
  next game. Saved on this phone.` Primary action: `SCAN AN ARENA`.
- Library: show names and saved dates. Selecting an arena loads and validates it;
  `USE THIS ARENA` creates a lobby only after loading succeeds. `SCAN AN ARENA`
  launches standalone setup. Deletion requires confirmation and removes the local
  copy only. Loading, errors and retry are inline; no camera or network on listing.
- Setup: a camera preview with compact instructions. Scan -> capture a fixed,
  textured natural reference -> name -> `SAVE ARENA`. Retain the existing capture
  deadline and explicit `RESTART SCAN`. Reference capture never grants readiness.
- Saving: disable repeated actions, atomically persist, await camera teardown,
  then return the saved selection to the library. Do not create a match implicitly.
- Cancel/background: invalidate suspended captures and await teardown before
  dismissing or allowing another camera owner. Background returns to a paused
  state with an explicit restart; interactive dismissal is disabled during setup.
- Corrupt, missing, incompatible or full storage: useful rescan/delete/retry copy;
  never create a match from an unreadable arena. If the room changed, rescan it.
- New saved-arena match: share saved bytes after the authenticated first room
  snapshot, then show `Align with saved arena` and the existing reference image.
  No host scanning step is required for this path. World relocalization, body
  relocalization and fresh measured residual gates remain mandatory.

## Local module contracts (v1)

`SavedArenaSummary`: immutable Sendable/Equatable/Codable metadata containing
`id: UUID`, `name: String`, `createdAt: Date`, `frameID: String`, `byteCount: Int`.
`SavedArenaBundle`: immutable Sendable/Equatable `summary` plus `bytes: Data`.
It can reconstruct a validated `DuelFrameMap` for a supplied new `epoch`.
No saved epoch, pose, readiness, player/session ID, ticket or credential.

`SavedArenaStoring: Sendable`: async throwing `list() -> [SavedArenaSummary]`,
`save(name: String, bytes: Data) -> SavedArenaBundle`,
`load(id: UUID) -> SavedArenaBundle`, `delete(id: UUID)`.
`LocalSavedArenaStore` actor owns Application Support files, atomic writes,
bounded metadata, at most 12 maps and 8 MiB per map. Names are trimmed, nonempty,
at most 60 characters. Validate hash, bundle/reference and secure world-map
decoding. Generated filenames only; protected private files excluded from backup.
Typed failures must allow list/load/delete recovery without exposing paths.

`ArenaSetupController` (MainActor) owns only offline scan lifecycle and save state.
Inputs: existing `TargetingSession`, `SavedArenaStoring`. Exposes frame provider,
scan/reference/save state and explicit async start/restart/capture/save/stop.
`ArenaSetupView` consumes it plus a completion returning the saved bundle (or
cancel). It uses the existing palette, buttons and reference panel. No cloud
client dependency. Teardown completes before completion is delivered.

Integration owns library presentation, selected arena lifecycle and match wiring.
`LobbyStore.createRealtimeArena(using: SavedArenaBundle)` binds an immutable
selection only to the successfully created host session, clears it on join/leave,
and passes it to the realtime map coordinator. Existing legacy API stays available
for tests/debug callers. The coordinator rejects conflicting already-shared bytes,
uploads only as host and installs with the current match epoch. Download/auth
contracts remain unchanged; map transfer gets an injectable protocol for tests.

Dependency direction: Home/library -> setup/storage or LobbyStore -> realtime
coordinator -> authenticated map transport + DuelFrameProvider. Storage never owns
camera, game state or network. Setup never opens a room. Durable Objects remain
the live combat authority; no backend or shared wire contract changes.

## Ownership and verification

- Storage owner: new Domain/SavedArenaModels.swift, Services/SavedArenaStore.swift,
  SavedArenaStoreTests.swift only.
- Setup owner: new Features/Arenas/ArenaSetupController.swift and ArenaSetupView.swift,
  ArenaSetupTests.swift only. Existing targeting files require root handoff.
- Integration: Home, RootView, LobbyStore, new library UI/model, realtime map
  composition/transport protocol, Xcode membership, integration tests and docs.

Use existing VKZPalette and button styles; adaptive layouts, labelled controls,
44-point minimum targets, Dynamic Type, accessible reference image descriptions.
No large panels over the playing camera; setup can use full explanatory space.

Boundary evidence: storage restart/roundtrip/delete/corruption/capacity/atomicity;
cancel/background/late-callback camera teardown; saved bytes in a new epoch start
unaligned; host-only upload, idempotent reuse and conflict rejection; selection
cleared before another session. Run `pnpm verify` and iOS tests/build. Simulator
evidence can support UI only. Reuse in the same room after app restart, changed
room rejection and two-phone alignment must be reported as physical-device
acceptance pending until observed on named devices. Rollback removes the entry
flow without changing backend data or protocol.
