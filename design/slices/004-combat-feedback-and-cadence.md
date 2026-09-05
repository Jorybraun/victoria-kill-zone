# Slice 004 — combat feedback and cadence

Status: accepted for implementation by integration, 2026-09-04, from the product owner's current request. Device promotion remains pending.

## Outcome

The duel has a camera-centered crosshair, immediate firing feedback, a skeleton that flashes only after a confirmed outgoing hit, and a complete fire/reload loop.

## Frozen behavior

- Skeletons stay invisible during acquisition and lock. A confirmed outgoing hit opens a 280 ms skeleton/impact flash only while a fresh body observation is available. Losing tracking clears it immediately. Incoming damage never displays an outgoing hit marker.
- Trigger press fires once; holding it repeats while the match, camera, connection, ammo, cooldown and reload gates allow. Release, scene inactivity, disappearing, or death stops repeat. Voice and accessibility activation retain single-shot input.
- Sidearm cadence is 150 ms (400 RPM maximum), 8 rounds, 1250 ms reload, unchanged zone damage. One unresolved cloud mutation at a time bounds retries; cloud round-trip time still limits sustained cadence until peer authority is integrated. The cooldown begins at dispatch, without another full wait after acknowledgment.
- A fresh camera ray with no valid target produces a miss, spends ammunition and renders a tracer. No production fire control invokes debug fire as a fallback.
- Reload has a visible control, requesting/active states, authoritative completion, and retryable error. Health/ammo remain server-owned. No local refill on a timer.
- Reticle is fixed at the camera viewport center, independent of HUD text height. Top: health, round clock, score and opponent. Bottom: weapon/ammo, fire, reload and optional voice. Connection/tracking blockers remain readable.
- Colors retain existing semantic tokens; warm amber is weapon/impact emphasis, cyan is telemetry, red is incoming damage, white is idle aim. Text contrasts with opaque dark backing. Controls have at least 44 pt targets and explicit VoiceOver labels; Reduce Motion removes muzzle flashes.
- Home screen presents the game identity, callsign, create and join actions. Debug harness remains debug-only.

## States and acceptance

Searching permits misses with a fresh camera ray; camera blocked permits no fire. Target lock changes only the reticle cue. Pending shots show immediate cosmetic tracer without claiming a hit. Accepted damage shows hit feedback. Reject/reconnect/respawn/reload prevents repeat damage effects. Empty ammo exposes reload. Finished/cancelled shows the result and exit.

Automated tests cover authoritative hit feedback, miss/retry/cooldown/reload boundaries and bounded FX policy. Simulator builds validate layout compilation. Two physical phones must demonstrate repeated fire/reload, both clients and spectator agreeing, hit-only skeleton placement, camera-center alignment, safe cancellation, thermal/frame-time and transport latency before promotion.

## Ownership and dependencies

Integration: this packet, docs, shared tuning, native models/client, DuelSession, ActiveDuelView, HomeView, Xcode references and integration tests. Backend: convex/**. Rendering: LaserFX.swift, CombatPresentationPolicy.swift and presentation tests. No spectator contract redesign. Phone shields and dodgeable projectiles require the separate authority/shared-frame work in the architecture review; no inert buttons advertise them as available.
