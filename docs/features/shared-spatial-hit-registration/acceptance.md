# Shared phone-proxy hit registration acceptance

Status: proposed baseline for KIL-18 review

## Documentation gate

- [ ] The glossary uses each spatial term once and without implementation detail.
- [ ] Requirements and design use the same target meaning, dimensions, range, rewind, and tracking rules.
- [ ] Persistent projectiles and personal time remain excluded.
- [ ] No current `phase0.v1` shared contract is changed.

## Deterministic prototype evidence

- [ ] Sphere radius is exactly 0.35 m in every test vector.
- [ ] Shots below 3 m and above 15 m fail closed.
- [ ] Rewind is capped at 250 ms.
- [ ] A target pose older than 100 ms cannot produce a hit.
- [ ] Non-finite values, non-invertible transforms, missing history, stale tracking, and impossible clock estimates fail closed.
- [ ] Known vectors include one hit, one miss, one too-close rejection, one out-of-range rejection, one stale-pose rejection, and one late-shot rejection.
- [ ] A repeated logical shot produces one Spatial Verdict.

## Figma/design evidence

- [ ] 390 × 844 portrait frames show calibration, ready, predicted, confirmed hit, confirmed miss, rejected, degraded, and recovery states.
- [ ] Predicted feedback never changes health or score.
- [ ] Confirmed and rejected states include text, not colour alone.
- [ ] Fire is visibly locked during degraded tracking.
- [ ] The phone proxy is presented as a game objective, not a body outline.
- [ ] Minimum touch targets remain 48 × 48 pt.
- [ ] VoiceOver copy distinguishes predicted from confirmed outcomes.
- [ ] Reduce Motion removes pulsing and travel animations without hiding state.

## Physical-device evidence

Required before claiming live shared-3D hit registration:

- [ ] Two named iPhone models and iOS versions relocalize into one arena.
- [ ] Three non-collinear anchors are compared on both devices.
- [ ] Measurements are recorded at 3 m, 8 m, and 15 m.
- [ ] Tracking interruption locks fire and fresh relocalization restores it.
- [ ] Five known hit vectors and five known miss vectors are repeated at each distance.
- [ ] One late packet beyond 250 ms is rejected without damage.
- [ ] One stale pose beyond 100 ms is rejected without damage.
- [ ] Convex records one authoritative transition for one accepted shot.
- [ ] No simulator or compile result is described as physical evidence.

## Exit

KIL-18 can close when Integration accepts the terminology, product limits, eight-state design packet, and evidence plan. KIL-19 remains blocked until that acceptance.
