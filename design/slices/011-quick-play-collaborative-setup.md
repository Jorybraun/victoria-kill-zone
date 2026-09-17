# Quick Play setup (continuous collaboration)

Proposed scope under [ADR 0011](../../docs/decisions/0011-quick-play-continuous-collaboration.md); frozen once that record is accepted. Replaces the setup states of [slice 010](010-quick-play-setup.md) for unsaved Quick Play matches — slice 010's combat HUD and recovery copy carry forward unchanged. Saved-arena measured setup is unchanged.

## User states

| Stage | Host | Joiner | Primary action |
|---|---|---|---|
| Connecting | "Connecting players (n/m)" | "Connecting players (n/m)" | none — peer link establishes |
| Aligning | "Move toward the play area" | "Move toward the play area" | none — alignment is automatic and continuous |
| Aligned/waiting | "Aligned — waiting for players (n/m)" | "Aligned — waiting for players (n/m)" | Host: PLAY enabled when all connected players aligned |
| Running | existing combat HUD | existing combat HUD | — |
| Degraded | "Hold steady — re-aligning" | "Hold steady — re-aligning" | none — automatic recovery; fire disabled |
| Lost | "Alignment lost" | "Alignment lost" | "Re-align", Leave |
| Incompatible | "This match needs the same iOS version on every phone" | same | Leave |

There is no Scanning stage, no Sharing stage, and no timed-alignment failure: alignment is a continuous condition that can complete at any point. A participant who cannot yet see any mapped feature stays in Aligning with the "Move toward the play area" prompt — including mid-match.

## Copy rules (unchanged from slice 010 unless noted)

- No reference panel, thumbnail, capture controls, or "hold the reference in view" copy.
- No numeric residual or accuracy figure.
- Match-menu status: "Aligned by shared scan (approximate)".
- Camera stays visible throughout setup and recovery; opaque backing only immediately behind legible text.

## New copy

- Aligning prompt: "Move toward the play area" (subtext: "You'll join when you can see somewhere already mapped").
- iOS mismatch: "This match needs the same iOS version on every phone" with Leave as the only action.
