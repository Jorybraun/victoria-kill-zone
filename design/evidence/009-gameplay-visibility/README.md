# Compact classic duel HUD

These four captures render the current `ActiveDuelView` source with synthetic match data in native macOS SwiftUI phone-sized viewports. They are **not iPhone or camera screenshots**. The fixture has 100 health, 8 rounds, 42 seconds remaining and an available synthetic searching tracker; it never connects to a backend or accesses a phone.

Reproduce from the tested checkout:

```sh
pnpm verify:ios
python3 scripts/gameplay-preview/run.py --combat-hud
```

The preview compiles an unmodified copy of the view with `@testable import VictoriaKillZone`, linked to the production dependencies from the completed SwiftPM build. `manifest.json` records source/module and capture hashes.

- `classic-375-standard.png` and `classic-393-standard.png`: resting compact layout, no blank toast rows, full-width bottom card, opponent strip or debug button. Health/time/menu and ammo/reload/fire fit; the reticle remains centered.
- The `large-text` captures request `xxxLarge`. macOS renders effectively identical text metrics here, so these do **not** prove iOS enlarged-text fit.
- Independent visual review found no clipping in the captured layouts. The camera background is a fallback gradient. Notch/safe-area behavior, actual camera contrast, transient notices, menu touch/VoiceOver behavior and physical incoming-laser visibility require iPhone evidence. Arena layout compiles but is not pictured here.

The classic laser fix uses a fresh observed origin when available and a camera-relative cosmetic incoming cue when no fresh head is tracked. Its 180–300 ms presentation does not delay confirmed damage or create a physical dodge window. The real-time arena retains its authoritative finite flight and disables this extra cosmetic cue for confirmed incoming-hit haptics.
