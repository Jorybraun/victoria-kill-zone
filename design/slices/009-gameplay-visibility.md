# Gameplay visibility

Accepted scope: make the classic duel and realtime arena camera usable during a match. Existing game rules, palette, targeting and hit effects remain authoritative.

## Frozen presentation

- Keep the reticle at the absolute camera center; HUD layout must not reposition it.
- Use a single compact top row for local health, remaining round time and a 44-point menu button. Opponent/roster and score detail belong in the menu.
- During play, use one compact bottom row for ammunition, reload and hold-to-fire. Arena shield and slow-field actions remain directly available as compact buttons above this row.
- Events and rejected-shot notices appear only while populated. No empty toast containers or permanent weapon/help/footer rows reserve camera height.
- Secondary voice, leave, help and status detail belong in an explicit scrollable menu. The menu states that the match continues. Opening it cancels held fire and pauses classic voice recognition; closing it never resumes held fire. Preserve existing voice preference.
- Keep setup, recovery, respawn and end-of-match actions available. Show a compact actionable blocker summary during classic play; its full explanation and settings action live in the menu.
- Remove the classic debug fallback button from both gameplay and menu, as explicitly requested. The debug session method and network API remain intact.
- Retain palette colors and use opaque surfaces only immediately behind legible controls. Avoid a full-width opaque combat card.

## Accessibility and acceptance

- All buttons have at least 44 × 44-point touch targets, descriptive labels and meaningful values. Menu content scrolls and supports accessibility text sizes. Compact gameplay controls in both modes use the existing classic HUD type-size ceiling; menu and preparation content remain uncapped, and the arena roster uses one column at accessibility sizes.
- Verify a small phone and larger phone in both modes, with and without notices. The resting classic HUD should occupy only the top 44-point control row and approximately 64-point bottom control row, plus safe-area margins.
- Verify menu opening during held fire stops repetition, voice cannot fire through the menu, dismissal does not restart firing, and leave/settings/voice actions remain reachable.
- Verify reticle, muzzle flash, incoming damage and confirmed-hit feedback still render independently of HUD layout.
- Root integration owns build/test/simulator evidence. A simulator or layout review does not establish physical-device camera, targeting, haptic or network behavior.
