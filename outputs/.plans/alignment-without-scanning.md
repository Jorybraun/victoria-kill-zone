# Plan: alignment-without-scanning

## Trigger

Follow-up to markerless-multiplayer-ar research. ARKit collaboration merge
requires co-viewed mapped regions — the documented weakness the user keeps
hitting. Question: what alternatives exist to environment scanning for
establishing a shared frame / playable multiplayer AR session?

## Key questions

1. **UWB Nearby Interaction** — iPhone 11+ U1/U2 chips measure
   distance+direction peer-to-peer via NINearbyObjectSession. Accuracy, FOV
   limits, iOS requirements, can it seed or replace coordinate-frame alignment?
   Can continuous ranging substitute for a merged world map?
2. **Peer-relative game architectures** — does a 4-player shooting game need a
   shared *world* frame at all? Alternatives: exchange per-device poses in a
   common convention, UWB-derived relative positions, skeletal/body-relative
   targeting where "the other player" is the anchor.
3. **Non-visual bootstrap methods** — optical handshake (screen flash pattern
   seen by peer camera), acoustic/ultrasonic chirps, Bluetooth RSSI, manual
   "tap the same physical point" anchor, compass+GPS seeding. Evidence of use
   in shipped products.
4. **Transient marker bootstrap** (deepest R2 finding) — host-screen-rendered
   image marker detected via ARImageTracking: implementation cost, accuracy
   (fused-pose trick), whether it counts as "visible marker" for repo policy.

## Scale

2 parallel researchers:
- R-A: UWB/Nearby Interaction + non-visual ranging (evidence-focused)
- R-B: Peer-relative architectures + marker bootstrap deep-dive

## Task ledger

- [ ] R-A evidence
- [ ] R-B evidence
- [ ] Synthesis: is there a scan-free path worth an ADR?
- [ ] Feasibility vs current codebase (DuelFrame seam, worker relay, 4-player)
