# Slice 002: Shared phone-proxy hit registration

| Field | Value |
|---|---|
| Status | Proposed baseline for KIL-18 review |
| Parent | KIL-17 |
| Design owner | `design/**` |
| Scope | Calibration through one confirmed phone-proxy hitscan verdict |

## Outcome

A player can understand whether shared spatial play is ready, fire one valid shot, distinguish prediction from authority, and recover safely from tracking failure.

## Frozen candidate rules

- Target: 0.35 m radius sphere centred on the target phone.
- Meaning: deliberate game objective, not player anatomy.
- Play lane: 3–15 m.
- Rewind cap: 250 ms.
- Maximum pose age: 100 ms.
- Fire requires both phones aligned with normal tracking.
- Host verdict is provisional; Convex state is authoritative.

## Required phone frames

1. `01 / Calibration`
2. `02 / Ready`
3. `03 / Firing · Predicted`
4. `04 / Result · Hit Confirmed`
5. `05 / Result · Miss Confirmed`
6. `06 / Result · Rejected`
7. `07 / Tracking · Degraded`
8. `08 / Tracking · Recovery`

Baseline viewport is 390 × 844 pt. Existing VKZ theme variables, text styles, Button, Status Chip, and Telemetry components remain the source design system.

## First small win: Firing · Predicted

### Hierarchy

- Top HUD: health, `SPATIAL LOCK`, ammunition.
- Arena view: live camera surface, neutral phone-proxy ring, target distance, crosshair, one short amber predicted ray.
- Result panel: `SHOT PREDICTED`, `AWAITING VERDICT`, and disabled repeat fire while the logical shot is pending.
- Safety footer: `CONTROLLED AREA • 3–15 M`.

### Behavior

- Trigger press creates one local prediction.
- No health, score, or hit announcement changes before authoritative match state arrives.
- Confirmed result replaces the predicted panel; it does not stack a second event.
- Loss of tracking immediately routes to the degraded frame and locks fire.

### Accessibility

- VoiceOver: `Shot predicted. Awaiting authoritative verdict.`
- Proxy ring has a text-equivalent target and distance label.
- Amber indicates pending only when paired with the two result labels.
- Reduce Motion uses a static ray and opacity change instead of projectile travel.

## State transitions

```text
Calibration → Ready → Predicted → Hit Confirmed
                              ↘ Miss Confirmed
                              ↘ Rejected
Any spatial state → Degraded → Recovery → Ready
```

## Out of scope

- Persistent projectile travel, speed, lifetime, or dodge mechanics.
- Personal time.
- Body-zone collision.
- Shared contract or production code changes.
