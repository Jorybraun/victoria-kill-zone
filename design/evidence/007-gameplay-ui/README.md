# Native gameplay entry and lobby review

These ten images render the **actual current `HomeView` and `WaitingRoomView` sources**, linked against existing production dependencies. The fixtures are synthetic; no live match or camera is involved. The renderer uses an offscreen macOS `NSHostingView` so native scroll views and text fields are captured. Earlier blank `ImageRenderer` attempts were replaced and are not retained as evidence.

Regenerate after a successful current macOS SwiftPM build:

```sh
python3 scripts/gameplay-preview/run.py
```

The harness never runs SwiftPM or modifies the app. It prepends `@testable import VictoriaKillZone` to temporary copies of the unchanged component sources, links existing build objects, and deletes its temporary executable afterward. `manifest.json` records component and supporting-module hashes plus every PNG hash. `build.log` retains compiler/linker diagnostics.

All images are 375 × 667 points/pixels, a small phone-sized review viewport. `standard` uses `.large`; `accessibility` selects `.accessibility3`. This exercises the actual accessibility layout branches, but **macOS font metrics and controls are not iOS Dynamic Type evidence**. UIKit-only code-copy and QR controls are excluded on this platform. No images are retouched.

| Evidence | Observed result |
|---|---|
| `home-standard.png` | Callsign, Create arena, and Join arena fit in the initial viewport. |
| `home-*-bottom.png` | Programmatic scrolling reaches the bottom content and Credits label. Navigation activation is not tested here. |
| `lobby-one-player-*.png` | One-player fixture renders the invite code, remaining capacity, and the readiness guidance. |
| `lobby-four-players-standard.png` | Compact invitation and roster appear above fixed Ready/Align controls. |
| `lobby-four-players-standard-bottom.png` | Native scrolling, including the footer's content inset, exposes the fourth player and Leave lobby while Ready/Align remain reachable. |
| `lobby-four-players-accessibility-bottom.png` | Player status is stacked below identity; all four players, inline Ready/Align controls, and Leave lobby are reachable in the scroll content. |

Fixture roster: host Alex and guest Riley ready; guest Morgan not ready; guest Alexandria North disconnected. The fixture uses the safe shell store and an explicit four-player arena room. No authoritative duration is present, so the duration summary is correctly omitted. The preview does not fabricate weapon configuration or network completion.

No app source change was required by the observed render review. Remaining iPhone verification is concrete:

1. Check 375-point and narrower devices at default and largest supported Dynamic Type, including the keyboard and safe-area insets.
2. Scroll to every roster member and reach Ready, Align arena, Leave lobby, and Credits using touch and VoiceOver.
3. Copy and share a code, expand the QR invitation, and open the resulting link on another phone.
4. Observe live readiness/start pending states and reconnect recovery with two and four participants.

These images establish component layout in the declared synthetic desktop harness. They do not establish physical-device input, networking, permissions, camera alignment, or release readiness.
