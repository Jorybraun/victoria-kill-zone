# ADR 0012 — Quick Play: UWB Nearby Interaction rendezvous for alignment seeding and live peer positions

Status: **accepted**, 2026-09-18. Owner accepted this record after the alignment-without-scanning research synthesis (`outputs/alignment-without-scanning.md`, ~60 sources; drafts under `outputs/.drafts/`). Integration owns this record, the token relay and the rendezvous client flow; targeting owns the NI session manager, transform solver and DuelFrame policy branch; design owns the slice update. Nothing in this record is physical-device evidence — every claim below carries its research citation and requires the device trial in "Evidence to collect."

## Context

ADR 0011 (accepted 2026-09-17) replaced one-shot world-map share with continuous ARKit collaboration: `isCollaborationEnabled` on every participant, `CollaborationData` relayed through the combat WebSocket, `ARParticipantAnchor` as the merge signal. The mechanics are correct and now relayed losslessly (PR #104: bounded outbound backlog, unbounded inbound stream, co-view guidance copy).

But the *physics* is unchanged: ARKit merges maps only when devices co-view the same mapped region — Apple's own onboarding for this feature is "hold the phones side by side," and WWDC 610 warns cross-direction views rarely localize. Owner reports from physical trials: alignment does not complete in practice. The merge requirement is documented Apple behavior, not a defect we can engineer around within the collab model alone.

The alignment-without-scanning research (`outputs/alignment-without-scanning.md`) established two convergent findings:

1. **A shared world map is not required for a body-shooter.** The only spatial datum combat needs is *where is the peer relative to my camera* — walls and floors matter only for occlusion realism. Pure camera-space detection (RealTag/LegitLaser model) fails at >2 players because ARKit cannot identify *which* person was hit — but ranging and pose exchange solve identity directly.
2. **UWB Nearby Interaction delivers that datum frame-free.** `NISession` streams distance (~10–20 cm error, independently measured) plus a direction vector to each peer, expressed in the local device's own frame. One bidirectional distance+direction sample plus both ARKit camera poses yields the pairwise inter-frame transform in closed form (4-DOF under `.gravity` alignment: yaw + 3D translation) — validated by LocAR (5 users, <1 m median error across 3 floors), SynchronizAR (UIST'19), and an MDPI 4-DOF UWB/V-SLAM solver.

Hardware is available: every iPhone since 11 except SE carries a U1/U2 UWB chip; both trial devices (iPhone 14, iPhone 16) qualify. WWDC20 documents the 4×3 topology — four devices each running three parallel `NISession`s — which is exactly the Phase 1 player cap.

## Decision

Quick Play gains an **NI rendezvous phase** that seeds inter-device alignment and keeps live peer positions flowing for the life of the match. Collaborative mapping (ADR 0011) remains enabled — it becomes a *refinement* path rather than the sole alignment prerequisite.

1. **Topology.** Each participant runs one `NISession` per other participant (three sessions at a 4-player match — the documented-safe count). `NIDiscoveryToken`s are exchanged over the **existing combat WebSocket** as a new relayed message type, alongside `collab` payloads. No MultipeerConnectivity is added — the `Transport/README.md` constraint (Network.framework only, no MPC) is preserved; the token is opaque data and the worker already relays opaque payloads per match room.
2. **Rendezvous ritual.** Setup gains a short "point at your squad" phase: participants stand ~1–4 m apart and aim their back cameras at one another for ~3 s. This is required by UWB physics — `direction` is only reported inside a cone behind the phone (~±55°, roughly the ultra-wide camera FoV). It replaces the current co-view guidance copy during setup; co-viewing remains useful afterward as collab refinement.
3. **Transform solve.** With bidirectional distance+direction and each device's own ARKit camera pose, each device computes peer positions in its own world frame; pairwise transforms to the elected host frame are solved in closed form and cross-checked across the 6 pairwise links (median/consistent subset wins). Require ≥1 direction-bearing sample per pair; surface a retry prompt otherwise (copy: "turn to face each other").
4. **Live peer positions.** NI sessions keep running for the match. Each device knows every peer's position in its own frame on every update — remote players can be rendered and `phoneProxy` verdicts evaluated **even if the ARKit maps never merge**. `ARParticipantAnchor` merges upgrade alignment confidence when they occur; they stop being the gate.
5. **U2 hedge (ordered).** First device test: does the iPhone 16 (U2) deliver `direction` to a peer iPhone? Developer reports flag a direction regression on U2 chips without camera assistance. If `direction` is nil on target hardware, in order: (a) enable `isCameraAssistanceEnabled` in a **bootstrap-only** NI phase — it requires `isCollaborationEnabled = false` on the shared ARSession, so it must run before collab starts and cannot coexist with it; (b) distance-only solve — players take a few steps during rendezvous while ranging, then solve via ≥6-range least squares (MDPI solver).
6. **Permission.** Nearby Interaction prompts once on first `run()`; denial invalidates sessions with `NIError.userDidNotAllow`. Onboarding copy must cover the prompt and the denial recovery path.
7. **Fallback.** If NI proves unreliable in arena trials after the U2 hedge is exhausted, the documented fallback is the HoloKit host-screen marker bootstrap (transient join-time marker, MIT-licensed reference implementation, drift accepted with manual resync). Adopting it requires amending the AGENTS.md visible-marker constraint via its own decision record — this ADR does not amend it.
8. **Debug fire** stays until the NI-seeded path has the physical-device evidence below, per AGENTS.md.

## What changes for the player

- Setup becomes: join match → "point at your squad" for ~3 s → play. No room scan, no standing side by side pointing at a wall, no waiting for a merge.
- Players stay findable even when ARKit tracking degrades — the HUD has a peer position channel that does not depend on map state.
- One new permission prompt (Nearby Interaction) on first use.

## Consequences

Positive:
- Alignment becomes deterministic and measurable — distance/direction are numbers, not an opaque merge state. Every rendezvous yields a verifiable transform or an explicit failure with a retry.
- Peer positions are known continuously, independent of ARKit map state — the collab failure mode (no co-view → no merge → no play) stops being fatal.
- The setup ritual shrinks to facing each other once — the same gesture the game wants anyway.
- No new transport: tokens ride the existing match WebSocket; no MultipeerConnectivity, no marker, no scan target.

Negative / risks:
- **No production game precedent.** NI usage is accessory demos and academic systems; the physics and API are documented but product-proof is absent. This is the largest risk and the reason the marker fallback is kept warm.
- **U2 direction regression** (self-reported, unresolved): iPhone 15/16-class chips may withhold `direction` without camera assistance — and camera assistance is incompatible with `isCollaborationEnabled` in the same ARSession, forcing a bootstrap-phase split or the distance-only fallback.
- NI measures the **device antenna**, not the body — peer hitboxes must be sized generously (~0.5 m), and the antenna↔camera extrinsic is a small per-model constant to calibrate.
- One `NISession` per peer is the documented model; the max session count is unpublished (3/device documented-safe, sufficient for the 4-player cap). Beyond 4 players would need verification.
- NI is foreground-only for peer sessions — acceptable for a game, noted for completeness.
- A new permission prompt adds onboarding friction and a denial recovery path.

## Alternatives considered

- **Keep collab-only with co-view guidance (current main):** the merge requirement is documented Apple physics, not fixable by better copy; physical trials already fail. Rejected as primary; retained as the refinement path.
- **Host-screen marker bootstrap as primary:** fully deterministic, shipped OSS precedent (HoloKit, MIT), and drops collab entirely. Rejected as primary because it forfeits the continuous peer-position channel (the property that makes NI uniquely valuable for a shooter), requires amending the visible-marker constraint, and reintroduces a per-join ritual NI makes unnecessary. Retained as the documented fallback.
- **Pure camera-space hit detection (RealTag model):** no shared frame at all — but ARKit tracks one body and cannot resolve *which* peer was hit at 4 players (RealTag's shipped bystander-damage bug). Rejected alone; `personSegmentation` remains a candidate hit-validation layer on top of either path.
- **MultipeerConnectivity for token exchange:** adds a second transport stack for data the match socket already carries. Rejected.
- **BLE RSSI / GPS+compass / acoustic ranging:** meter-scale or research-grade precision; rejected outright by the research.

## Evidence to collect (before production confidence)

Two phones minimum (iPhone 14 U1, iPhone 16 U2), named models, iOS versions and build recorded:

1. **U2 check first:** does the iPhone 16 deliver `NINearbyObject.direction` to a peer iPhone at 1–4 m, back cameras facing? Record per-device. If nil, exercise hedge (a) then (b) and record which path delivered.
2. Rendezvous: time from match join to solved transforms; success rate across ≥5 attempts; transform residual vs. a subsequent `ARParticipantAnchor` merge (cross-check: do both frames agree where the peer is?).
3. Live ranging during play: peer-position error vs. visual estimation at ~3 m and ~8 m; behavior when players turn away (direction loss → distance-only degradation, recovery time on re-facing).
4. NI permission prompt: grant and deny flows; denial recovery copy.
5. Combat under NI-seeded alignment: `phoneProxy` verdicts, health/ammo/K-D convergence — same bar as ADR 0011's evidence list.
6. Setup-log export on both phones for each run: NI session state, direction-bearing sample counts, transform residuals — added to the persisted diagnostics introduced in PR #99.

## References

- `outputs/alignment-without-scanning.md` — synthesis (this decision's evidence base)
- `outputs/.drafts/alignment-without-scanning-R-A.md` — NI capabilities, fusion math, prior art (LocAR/SynchronizAR/MDPI), FoV and U2 caveats
- `outputs/.drafts/alignment-without-scanning-R-B.md` — peer-relative architectures, HoloKit marker bootstrap detail, ranked alternatives
