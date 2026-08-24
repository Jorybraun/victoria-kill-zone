# Shared phone-proxy hit registration requirements

Status: proposed baseline for KIL-18 review

## Outcome

Two players can calibrate one shared arena, see each phone as a deliberate game target, fire one frame-aligned shot, and receive one understandable predicted, confirmed, missed, rejected, degraded, or recovered result. Persistent projectiles and personal time are excluded.

## Baseline product decisions

| Decision | Baseline |
|---|---|
| Target shape | Sphere centred on the target phone |
| Target meaning | Deliberate game objective around the phone, not the player's body |
| Proxy radius | 0.35 m |
| Minimum player separation | 3 m |
| Maximum shot range | 15 m |
| Maximum rewind window | 250 ms |
| Pose age allowed for a verdict | 100 ms |
| Tracking required to fire | Both phones aligned to the Shared Arena Frame with normal tracking |
| Tracking failure | Input locks immediately; stale transforms are never reused |
| Initial authority | Host produces a provisional Spatial Verdict; Convex records the authoritative state transition |

These values are prototype limits to measure, not marketing claims. Changing target meaning, shape, authority, or safety limits requires an accepted update before implementation.

## Player-observable flow

1. **Entry:** Both players enter the existing duel and reach the spatial setup step.
2. **Calibration:** The host defines the arena; the guest joins it. Both see alignment progress and a clear stop state if tracking is inadequate.
3. **Ready:** Both phones show `SPATIAL LOCK READY`, target distance, tracking state, and the 3 m minimum-distance rule.
4. **Firing:** A trigger press captures one Frame-Aligned Shot. Firing is unavailable outside 3–15 m or while either phone is unaligned, stale, or degraded.
5. **Predicted:** The shooter gets immediate local feedback labelled `SHOT PREDICTED`. Health and score do not change yet.
6. **Confirmed hit:** Both players receive one `HIT CONFIRMED` state from authoritative match data. Damage, ammunition, health, and event feed reconcile as one state change.
7. **Confirmed miss:** Both players receive `MISS CONFIRMED`. No damage is applied.
8. **Rejected:** The shooter sees one fixed reason such as `TRACKING LOST`, `TARGET TOO CLOSE`, `TARGET OUT OF RANGE`, `POSE TOO OLD`, or `SHOT TOO LATE`. A rejected shot never produces damage.
9. **Degraded:** Spatial input locks. Last trusted positions remain visible only as dimmed diagnostics and are labelled stale.
10. **Recovery:** Both phones must establish a fresh shared lock. The UI says `SPATIAL LOCK RESTORED`; old shot animations are not replayed.

## Role-specific feedback

### Shooter

- Crosshair and target-proxy ring are neutral cyan while valid.
- Trigger press produces one short amber ray and `SHOT PREDICTED`.
- Confirmed hit changes the terminal point and result label to green.
- Confirmed miss fades the ray to muted grey.
- Rejection changes the result panel to red and names the corrective action.

### Target

- The phone proxy is not drawn as a body outline.
- A confirmed hit produces one haptic and one accessible announcement.
- A predicted remote shot does not change health or announce a hit.
- Tracking loss locks combat instead of leaving an invisible vulnerable target.

### Spectator

- Shows current trusted phone proxies, the shot ray, and the confirmed terminal result.
- Labels historical evaluation as `REWIND 0–250 MS` rather than pretending it is current position.
- Never exposes precise historical coordinates in a public payload.
- Never displays a predicted shot as authoritative damage.

## Copy

| Condition | Copy |
|---|---|
| Calibration in progress | `ALIGNING SHARED ARENA…` |
| Ready | `SPATIAL LOCK READY` |
| Predicted | `SHOT PREDICTED` |
| Hit | `HIT CONFIRMED` |
| Miss | `MISS CONFIRMED` |
| Tracking failure | `TRACKING LOST — FIRE LOCKED` |
| Too close | `MOVE APART — 3 M MINIMUM` |
| Out of range | `TARGET OUT OF RANGE — 15 M MAXIMUM` |
| Stale pose | `TARGET POSITION TOO OLD` |
| Rewind rejected | `SHOT ARRIVED TOO LATE` |
| Recovery | `SPATIAL LOCK RESTORED` |

## Safety and privacy

- Use only in a controlled, authorized area with a clear 3–15 m lane.
- Stop play near roads, stairs, obstacles, bystanders, or an untracked player.
- Do not use realistic gun-shaped props.
- Players look where they move; the app never encourages backward running.
- Precise transforms stay match-scoped and expire with prototype telemetry.
- Public spectator data contains only the minimum reconstruction data and no reusable location history.

## Excluded from this slice

- Persistent projectile identity or travel time.
- Personal time, bullet time, dodge windows, or time fields.
- Body-zone collision or claims that the proxy represents anatomy.
- Three or more players.
- Production anti-cheat claims.
