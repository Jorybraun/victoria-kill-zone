# ADR 0001: Native iOS + Convex Phase 0 stack

- **Status:** Accepted
- **Date:** 2026-08-22
- **Decision owners:** Product and integration

## Context

The workspace contains archived Unity, custom-server, and LAN-oriented experiments. They are useful product and technical history, but continuing from multiple prototype architectures would split ownership, weaken the markerless targeting goal, and make two-device evidence harder to reproduce.

The current [technical specification](../../victoria-kill-zone-technical-spec.md) defines a focused markerless 1v1 duel. The [build orchestration prompt](../../victoria-kill-zone-build-prompt.md) defines the corresponding parallel work boundaries and physical-device gates.

## Decision

Phase 0 uses:

- native Swift and SwiftUI for the iPhone app;
- ARKit for the rear-camera session and shooter ray;
- Apple Vision body-pose detection for markerless head, torso, and limb regions;
- Core Location for coarse arena membership;
- hitscan with immediate local effects;
- anonymous device identity plus match-scoped sessions;
- Convex as authority for phase, sessions, health, ammo, cooldown, score, shot ledger, reload, respawn, and spectator state;
- React, TypeScript, Vite, and the Convex React client for a read-only spectator;
- external phone mirroring and OBS (or equivalent) for dual POV presentation.

Phase 0 is exactly 1v1. Convex receives discrete gameplay events and reduced telemetry, not camera frames or 60 Hz pose/motion data.

This decision supersedes archived Unity, custom-server, and LAN implementations as active architecture. The entire `archive /` tree remains preserved and reference-only. Nothing there is deleted or imported into active source by default. Reuse requires a new accepted ADR that identifies the exact artifact, license/provenance, interface, tests, and owner.

## Consequences

- iOS camera and targeting work requires macOS/Xcode and physical iPhones; the Mac Outpost is the promotion lane for those proofs.
- Convex and spectator work can proceed in parallel in Cloud agents behind frozen contracts.
- The spectator is read-only, the server owns damage values, and no permanent account system is needed for the prototype.
- Markerless identity beyond a duel, shared AR coordinates, UWB, projectile physics, WebRTC, persistent accounts, App Store submission, and physical accessories remain outside Phase 0.
- Earlier archive builds may still inform design and risk analysis, but they are not build dependencies and cannot determine current behavior.

## Reconsider when

Revisit this decision only after the complete two-phone loop and spectator proof pass, or if physical-device evidence demonstrates a blocking platform limitation. Any replacement must preserve the acceptance scenario and include a migration and rollback plan.
