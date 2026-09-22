# Quick Play setup (continuous collaboration)

Proposed scope under [ADR 0011](../../docs/decisions/0011-quick-play-continuous-collaboration.md); frozen once that record is accepted. Replaces the setup states of [slice 010](010-quick-play-setup.md) for unsaved Quick Play matches — slice 010's combat HUD and recovery copy carry forward unchanged. Saved-arena measured setup is unchanged.

## User states

| Stage | Host | Joiner | Primary action |
|---|---|---|---|
| Connecting | "Connecting players (n/m)" | "Connecting players (n/m)" | none — peer link establishes |
| Aligning | "Stand side by side and point at the same spot" | "Stand side by side and point at the same spot" | none — alignment is automatic and continuous |
| Aligned/waiting | "Aligned — waiting for players (n/m)" | "Aligned — waiting for players (n/m)" | Host: PLAY enabled when all connected players aligned |
| Running | existing combat HUD | existing combat HUD | — |
| Degraded | "Hold steady — re-aligning" | "Hold steady — re-aligning" | none — automatic recovery; fire disabled |
| Lost | "Alignment lost" | "Alignment lost" | "Re-align", Leave |
| Incompatible | "This match needs the same iOS version on every phone" | same | Leave |

There is no Scanning stage, no Sharing stage, and no timed-alignment failure: alignment is a continuous condition that can complete at any point. A participant who cannot yet see any mapped feature stays in Aligning — including mid-match.

The Aligning prompt asks players to co-view one spot because ARKit merges world maps only when devices see the same mapped region (Apple's own onboarding is "hold the phones side by side"); merge also needs one device's mapping status to reach `mapped`, which is why pointing at a textured area matters.

## Copy rules (unchanged from slice 010 unless noted)

- No reference panel, thumbnail, capture controls, or "hold the reference in view" copy.
- No numeric residual or accuracy figure.
- Match-menu status: "Aligned by shared scan (approximate)".
- Camera stays visible throughout setup and recovery; opaque backing only immediately behind legible text.

## New copy

- Aligning prompt: "Stand side by side and point at the same spot — the phones link automatically."
- iOS mismatch: "This match needs the same iOS version on every phone" with Leave as the only action.
