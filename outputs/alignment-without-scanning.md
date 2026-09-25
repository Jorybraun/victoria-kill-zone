# Alignment Without Environment Scanning — Synthesis

Follow-up to `markerless-multiplayer-ar.md`. Question: can the 4-player
co-located shooter establish spatial alignment without environment scanning?
Two research tracks (R-A: ranging hardware; R-B: game architectures) converged
on the same answer. ~60 sources; drafts in `outputs/.drafts/`.

## Verdict

**A shared world map is not required at all.** For a body-shooter the only
required datum is "where is the peer relative to my camera," and UWB Nearby
Interaction delivers exactly that — distance (~10–20 cm error) plus direction
to each peer, expressed in *your* local frame, continuously, with no scanning,
no merged map, no markers. Every iPhone since 11 (except SE) has the hardware;
both test devices (iPhone 14, iPhone 16) qualify.

## The two viable architectures (ranked)

### 1. UWB Nearby Interaction — frame-free peer positions + seeded transforms

- `NISession` streams distance + direction per peer in the local device frame.
  WWDC20 documents the 4×3 topology (4 devices × 3 sessions each) — the exact
  Phase 1 shape. Tokens can ride the existing combat WebSocket; no
  MultipeerConnectivity needed.
- **Bootstrap:** one bidirectional distance+direction sample plus both ARKit
  camera poses yields the inter-frame transform in closed form (4-DOF under
  `.gravity`: yaw + translation). Validated by LocAR (5 users, 3 floors,
  <1 m median error), SynchronizAR (UIST'19), and an MDPI 4-DOF solver.
- **The killer property:** keep NI running during play and peer positions are
  continuously known *even if the world maps never merge* — collab merges
  become refinement, not prerequisite.
- **Caveats:** direction only inside a ~±55° cone behind the phone (players
  must face each other once — a ~3 s "point at your squad" ritual); multiple
  dev reports say U2-chip iPhones (15/16 Pro) withhold `direction` without
  camera assistance — **must be verified on the iPhone 16 first**; camera-
  assisted NI is incompatible with `isCollaborationEnabled` in the same
  ARSession, so if camera assistance is needed it runs in a bootstrap-only
  phase before collab starts.
- No production game usage found — usage is accessory demos + academic
  systems. Physics and API support are solid; product proof is absent.

### 2. Host-screen marker bootstrap (HoloKit, MIT-licensed) — deterministic fallback

- Host renders a 4 cm high-contrast marker on its own screen (runtime
  `ARReferenceImage`, per-model DPI table); peer `detectionImages` detects it;
  fused-pose handshake (clock-sync + ~50 timestamped pose pairs + least-squares
  yaw + std-dev gates) yields the transform. Complete OSS implementation read
  directly — portable to Swift.
- HoloKit then **drops collaborative sessions entirely** — drift is accepted,
  manual "Resync" re-runs the ritual. For match-length sessions with ~0.5 m
  hitboxes this is adequate.
- Optical QR-on-screen variant solves full 6-DOF in one shot (Snap patent
  US12243266 — legal flag; the plain image-marker variant is older art).
- **Requires an ADR**: a marker rendered transiently at join-time arguably
  fits the repo's "no visible target markers" rule (it isn't a gameplay
  marker), but the constraint should be amended explicitly.

## Rejected

- Pure camera-space hit detection alone (RealTag/LegitLaser model): ARKit
  tracks one body and can't identify *which* person was hit — RealTag users
  report bystanders taking damage. At 4 players, identity must come from
  ranging or pose exchange. `personSegmentation` remains useful as a
  hit-*validation* layer (is the crosshair on a human).
- BLE RSSI (meter-scale), GPS+compass (5–30° heading error, erratic indoors),
  acoustic ranging (research-grade, DSP surface area).
- Manual "tap the same spot" bootstrap — position only, yaw unresolvable
  without compass.

## Recommended path

1. **ADR + prototype NI rendezvous** (primary): token exchange over the
   existing combat WebSocket; 3 `NISession`s/device; "point at your squad"
   phase; closed-form pairwise transforms to host frame; keep collab deltas
   flowing as refinement. First device test: does the iPhone 16 (U2) deliver
   `direction`?
2. **If U2 direction is nil:** camera-assisted NI in a bootstrap-only phase
   (collab off during bootstrap), or distance-only + few-steps solve.
3. **If NI proves unreliable in the arena:** host-screen marker bootstrap via
   new ADR — fully deterministic, ~1–2 s ritual, MIT reference code.
4. **Later, independent of alignment choice:** `personSegmentation` hit
   validation; NI continues as live peer-position feed during play.

## Fit with current codebase

- Token exchange: reuse the combat WebSocket relay (same mechanism as collab
  deltas) — avoids adding MultipeerConnectivity, which `Transport/README.md`
  deliberately excludes.
- `isCollaborationEnabled` stays on the game ARSession (plain NI doesn't
  conflict; only *camera-assisted* NI does).
- DuelFrame merge policy gains an NI-seeded branch; `ARParticipantAnchor`
  evidence remains the alignment confirmation signal.
- 4-player cap satisfied by documented 3-sessions-per-device topology.
