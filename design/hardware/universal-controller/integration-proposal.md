# Physical trigger → game input (proposal)

Status: design exploration, 2026-09-06. No app, firmware, backend, or shared interface change is implemented or frozen by this packet. Integration and iOS owners must accept a separate slice before implementation.

## Intended experience

The player docks a phone vertically in an adjustable, brightly coloured arcade grip, connects the accessory in the app, and uses their index finger to press a momentary button. Holding it should use the active weapon's existing cadence; releasing it stops future shots. The phone camera supplies the aim ray. The game supplies the laser/tracer, sound, and phone haptics. The shell contains no optical emitter.

## Proposed connection

A normally-open momentary switch is read by a small Bluetooth Low Energy board. Firmware debounces the switch and reports button state plus a monotonic sequence counter. The app acts as the BLE central through Apple's [Core Bluetooth](https://developer.apple.com/documentation/corebluetooth) APIs. A [Seeed XIAO nRF52840](https://wiki.seeedstudio.com/XIAO_BLE/) is one board candidate: the manufacturer lists a 21 × 17.8 mm board and BLE support. Board choice, circuit, supply, wiring clearance, antenna location, service UUIDs and message layout remain to be confirmed on a bench.

Prototype the link with USB power from an external power bank. This kit has no battery cradle, battery selection, charging design, firmware, or demonstrated radio connection. The enclosure has no connector-specific power opening; bench-test the board outside the housing until a connector panel and board restraint are designed.

This is a custom BLE peripheral proposal, not a claim that an arbitrary Bluetooth camera shutter remote will work. Camera remotes often present another kind of input; prove compatibility with the app before choosing one. A supported game controller is a possible later alternative via Apple's [Game Controller](https://developer.apple.com/documentation/gamecontroller) framework.

## Integration seam to preserve

The native arena has `RealtimeArenaController.setTriggerHeld(_:)` in `ios/VictoriaKillZone/VictoriaKillZone/Features/Realtime/RealtimeArenaController.swift`. Dispatch accessory input into the existing input path on the main actor. Do not create a second shot loop or invoke backend damage from hardware. The native arena source is included in the current main baseline.

The existing duel surface also has `startRepeatingFire()` / `stopRepeatingFire()` hold/release entry points in `Features/Game/DuelSession.swift`. The iOS owner should adapt the currently shipped game surface, and retain touch and voice input. A hardware press must not depend on having a target lock. All existing ammunition, cooldown, tracking, presence, life-state and authoritative verdict rules remain owned by the game.

For multiple input sources, track each source's state. Releasing a touch must not incorrectly release a still-held accessory trigger, or vice versa. A lifecycle clear cancels every input source.

## Proposed lifecycle behaviour to test

| Event | Proposed behaviour |
|---|---|
| Fresh press while connected and eligible | Forward the press to the existing trigger input. |
| Hold | Existing weapon cadence controls repeat. The accessory does not emit shot commands. |
| Release | Stop future repeat immediately; leave already-dispatched shots alone. |
| Switch bounce or duplicate/out-of-order notification | Reject duplicate/stale state; produce no extra press. |
| Connection lost, app backgrounded, device unbound | Release that source and cancel hold. |
| Reconnect with physical button already held | Require a release followed by a new press; no firing on reconnect. |
| No input updates while held | Use a proposed 100 ms state heartbeat and 300 ms stale-state timeout; tune after device measurements. |
| Death, reload, match exit or tracking loss | Use existing game cancellation gates; require fresh input after recovery. |

Numbers above are proposed engineering targets, not measured latency or accepted shared contracts. Measure physical switch closure to local tracer onset on a named iPhone/iOS version, reporting median and 95th percentile separately from authoritative verdict latency. Set an initial local-input target of <100 ms p95 and revise from evidence.

## Acceptance handoff

1. Integration accepts accessory state/lifecycle semantics and assigns an iOS input owner and firmware owner.
2. Bench-test the button and BLE link before relying on the printed enclosure. Record board model/firmware and iPhone model/iOS version, never unique identifiers.
3. Verify press, hold, release, duplicate notifications, missed release, disconnect, background, reconnect-held, and touch/voice coexistence.
4. Demonstrate the existing firing gates, camera aim and authoritative damage on physical phones. Report fit and camera clearance for each phone/case combination.
5. Keep the existing debug-fire path and release gates until their documented physical-device replacement evidence is recorded by Integration.

This design proposal changes neither the multiplayer cap nor targeting authority.
