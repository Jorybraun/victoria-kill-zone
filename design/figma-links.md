# Victoria Pew Pew Figma handoff

## Active file

- [Victoria Pew Pew — iOS G1/G2](https://www.figma.com/design/3VdPoHHat7eq3KPEgJn8gB)
- Scope authority: [Slice 001: Create, join, start, debug fire, synchronized health](slices/001-g1-g2-network-vertical-slice.md)
- Last verified: 2026-08-22

## File inventory

The file contains Cover, Getting Started, Foundations, five component-library pages, the `iOS · Slice 001` screen page, and Utilities. The screen page covers 22 portrait states across entry/setup, lobby/countdown, active network testing, degradation/recovery, and completed/cancelled outcomes.

Public component sets:

- Button (`14:2`): primary/secondary × default/pressed/disabled/loading
- Field (`16:54`): callsign/duel code × idle/focused/error/disabled
- Status Chip (`17:27`): telemetry/ready/pending/danger/muted
- Player Card (`18:56`): open slot plus host/guest readiness and disconnection states
- Telemetry (`19:46`): health/ammo/countdown/duel code × large/compact, plus shared HUD health/phase/ammo variants

## iOS handoff

- Baseline viewport: 390 × 844 pt, portrait, iOS 17.
- Screen horizontal inset: 16 pt. Minimum interactive target: 48 × 48 pt.
- Figma uses Inter and Roboto Mono because the remote renderer does not draw Apple system fonts. SwiftUI remains SF Pro/SF Rounded and SF Mono/system monospaced.
- The active slice deliberately uses a neutral network-test surface. It does not introduce targeting, boundary enforcement, competitive statistics, respawn loops, weapon simulation, persistent identity, or 3+ player targeting.
- Code Connect is deferred until this editable file is published as a Figma library. Component descriptions and the Utilities page carry the SwiftUI handoff in the meantime.

## Naming handoff

- User-visible product name: `Victoria Pew Pew`; compact Home monogram: `VPP`.
- Migration-sensitive `VKZ` code/token identifiers, repository paths, bundle IDs, Convex names, routes, and stable API identifiers remain unchanged.
- Integration must apply the user-visible name to the native app display name and integration-owned product docs; Spectator must apply it to its owned page title and copy. No naming migration is authorized for internal identifiers.

## Validation

Verified in Figma on 2026-08-22:

- 22/22 screen frames are exactly 390 × 844 pt with 16 pt left/right padding.
- All frozen Slice 001 copy and the nine-state taxonomy are represented.
- Every screen uses shared component instances; public sets contain 39 variants total.
- Button and field instances meet the 48 pt minimum touch target.
- Status chips pair visible text with a shape cue; color is supplementary.
- No missing fonts, out-of-bounds descendants, or out-of-scope visible data were found in screen frames.
