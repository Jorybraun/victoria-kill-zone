# Scan & Save component review

Eight captures of the actual SwiftUI Home and MapLab library at 375 × 667 points, rendered offscreen on macOS with explicit synthetic storage. Source/module hashes, exact cases and limitations are in [manifest.json](manifest.json).

The normal Home actions and empty/saved/error library states are visible without clipped controls. Home uses its accessibility layout branch. macOS does not reproduce iOS Dynamic Type metrics or navigation chrome; matching library PNGs across Dynamic Type settings are recorded, not presented as phone accessibility proof. No camera, recognition, touch, VoiceOver or multiplayer acceptance is claimed.

Local reproduction used `/tmp/vkz-map-lab-preview/run.py` against the successful SwiftPM build. Full native gate: `/tmp/vkz-map-lab-ios-final.log` (379 app tests, two physical-only skips; Debug app/tests and Release app compiled).
