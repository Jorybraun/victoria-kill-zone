# Scan & Save and gameplay proof — accepted first implementation slice

Status: Ready for local implementation, 2026-09-07. Integration owns this packet.
This slice executes KIL-48–50 under the full production-combat goal. It does not
select a new production alignment method or change combat eligibility.

## Offline scan loop

Home exposes SCAN & SAVE independently of callsign, backend configuration and
match creation. The library offers NEW SCAN, TEST SCAN, Delete and Done. Capture
uses world tracking only: slowly observe nearby detail, then SAVE SCAN when usable,
enter a name, save and return. No reference rectangle, opponent, room dimensions
or network is required. Existing reference-backed game arenas remain available
under a separate legacy create flow; opening scan management never creates a match.

Saved scans live only on this phone. TEST SCAN resets the camera and installs the
saved world map; show Looking for this scan, then Scan recognized on this phone
only after fresh ARKit relocalization. Copy explains that this is a recognition
test, not proof of multiplayer alignment. Wrong place, timeout, permission denial,
interruption and storage corruption have explicit retry/delete recovery.

Use current VKZ semantic palette and typography, SF Symbols, scrolling layouts,
Dynamic Type, labelled 44-point minimum actions and a compact camera overlay.
Keep the camera visible. Show one short current instruction, Cancel/Done and the
relevant save/retry action. No progress percentage, raw telemetry, debug-fire
control or game action in this workflow. Retry is explicit after backgrounding.

One owner holds the camera. Capture/recognition cancellation invalidates late
callbacks and awaits teardown before dismissal or deferred invite handling.
Saving cannot publish a cancelled late result; a completed atomic save remains.

## Frozen boundaries

Integration owns Domain/MapLabModels.swift, AppEnvironment/Root/Home entry wiring,
legacy library-mode restrictions, Xcode membership and docs. MapLabDriving,
MapLabStoring and their value/error types are the local contract.

Scanner owner owns new Features/MapLab/**, Services/MapLabStore.swift,
Targeting/MapLab/** and MapLab-specific tests. One actor stores version-1 manifests
plus raw secure ARWorldMap archives in a distinct MapLab directory: at most 12
maps, 8 MiB/map, metadata bounded at 4096 bytes. Generated UUID paths, checksum,
bounded reads, atomic private publication, backup exclusion, protected files,
corruption deletion and secure decode remain required. No old saves are changed.
Only world-tracking support is required for this scanner; no body, image-reference
or production readiness code may be relaxed. Library API:
`MapLabLibraryView(store: any MapLabStoring, onDone: @escaping () -> Void)`.
Driver/UI factories remain scanner-owned; Root needs no ARKit type.

Spatial owner owns the existing SharedArenaSession/SharedArenaHarnessView,
SharedArenaModels, new Targeting/QuickPlay/** and spatial-specific tests. The
experimental shared origin must use explicit arenaFromLocal/localFromArena math,
per-run credentials, epoch/staleness fences and revoked validity on reset. It is
measurement-only. Remove demonstration shared secrets and any implication that
participant-anchor consistency independently proves hit accuracy. No combat
readiness or scanner driver edits. For this first slice, a manually shared random
experiment code is acceptable for the DEBUG measurement harness; it is not the
Quick Play user flow, and is never a marker attached to a person.

Combat owner owns Features/Game/RealtimeCombatFX.swift, new
Features/Replay/** and replay/presentation tests. Feed explicit synthetic accepted
events through the real replica/presentation/SceneKit path; include non-identity
transforms, miss, slow-segment, terminal, stale/duplicate and clear/restart cases.
No real server calls, manufactured body readiness, health edits, backend or
targeting code. DEBUG replay may use a standalone scene with a labelled synthetic
fixture; it does not claim phone gameplay. Root owns any Home diagnostic entry.

## Acceptance

- iOS 17/iPhone source baseline; no model hard-code or LiDAR dependency. Test the
  oldest declared supported non-LiDAR class, standard/small-screen and Pro classes
  when devices are available; iPhone 14 is one regression. All physical rows pending.
- Scanner: offline capture/save/restart/load/recognition; wrong-location recovery;
  cancellation/background at suspended boundaries; no match/network calls.
- Spatial: distinct translated/rotated origins, stale/missing anchors, epoch reset
  and credentials isolated per run. Measured physical accuracy remains a later gate.
- Combat: replay accepted projectile IDs once, transform geometry exactly once,
  terminate/expire correctly, hide stale effects and avoid skeleton dependence.
- Canonical pnpm verify, affected Swift tests, Xcode source checks and iOS builds;
  screenshots where a simulator can show UI. Physical recognition/multiplayer
  remains unverified until actual named-device runs; never claim it from fixtures.
