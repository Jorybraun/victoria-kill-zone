# Room scanning and playable multiplayer checkpoint

Owner: Integration / Codex local. Issue: [KIL-46](https://linear.app/kill-victoria/issue/KIL-46/resolve-creator-phone-room-scanning-on-iphone-14-before-multiplayer).
Updated: 2026-09-07. User report: the arena creator's iPhone 14 never registered
the room; multiplayer, bullets, and the new engine have not been observed working.
Exact variant, iOS version, and installed build are not yet confirmed.

## Goal and evidence rule

Keep the existing full M0–M6 goal. The next acceptance result is a playable match
on two physical phones, including the reported iPhone 14. Code, a PR, simulator
success, server health, and a TestFlight upload are intermediate evidence only.
The app goal's automatic continuation is currently usage-limited; this tracked
execution plan does not reset its state or claim the goal is complete.

## Ordered checklist

- [x] Separate room mapping, reference capture, shared alignment, and combat.
- [x] Inspect initial mapping for an unintended LiDAR requirement: none found.
- [x] Preserve PR #69's extending-map readiness and bounded restart repair.
- [x] Repair misleading failed-scan presentation and expose live camera guidance.
- [ ] Verify and publish the next dependent draft PR above #70.
- [ ] On the iPhone 14, prove camera start → usable map → reference capture → save.
- [ ] On the same signed build, two phones join and align in one arena.
- [ ] Expose host boundary selection and prove its enforcement separately from AR coverage.
- [ ] Validate freely moving outdoor alignment without continuously aiming at one reference.
- [ ] Both phones see the other player's accepted shots at the same world location.
- [ ] Both agree on damage, ammunition, reload, death/respawn, and departures.
- [ ] Physically demonstrate shield and slowed projectile/dodge behavior.
- [ ] Finish remaining M0–M6 performance, durability, accessibility and release gates.

## Failure breakdown

| Stage | Evidence needed | Known state |
|---|---|---|
| Camera startup | Permission and AR session active on the named phone | No captured device state yet |
| Room map | Normal tracking and usable extending/mapped world data | PR #69 fixes strict mapped-only gating and adds a 30-second deadline |
| Reference capture | A fixed textured rectangle is detected and its corners measured | Separate operation; a room map does not prove it passed |
| Shared alignment | Both phones relocalize into identical map bytes and measure fresh residuals | Physical acceptance pending |
| Combat | Remote worldlines rendered, server-confirmed damage, lifecycle convergence | Owner has not observed it working; remains open |

The scanner uses ARWorldTrackingConfiguration with horizontal/vertical plane
detection, not RoomPlan or scene reconstruction. Do not diagnose the reported
failure as missing LiDAR. Preserve runtime support checks. The saved-arena UI
previously handled mapping timeout but not other terminal frame failures, so an
interrupted camera could misleadingly retain `Scan the play area`.

## Delivery and stop conditions

Existing chain: main → #69 scan recovery → #70 saved arenas → next scan-guidance
repair. Preserve existing branch names; integration uses the required codex/
prefix for the new branch. Review each changed layer independently and rerun its
checks after propagation. Native Devin/GitHub grouping is not established by
these branch links; group and merge via the repository's native-stack release
process. No native grouping/merge capability is exposed in this session, so no
merge is attempted or claimed. No production release is part of this repair.

Stop at a failing required check or unavailable physical evidence. Never bypass
alignment to make bullets appear. Record phone model/iOS, exact build and SHA,
screen stage/recovery result, and two-phone observations without device IDs,
camera images, map data, credentials, or precise location in public logs.

First implementation checkpoint: within 30 minutes of 2026-09-07 14:24 UTC;
then bounded verification and draft PR publication. If device evidence is missing,
publish the tested repair and explicit remaining phone trial instead of endlessly
refactoring unrelated systems.

## Outdoor arenas: boundary is not the scan

The owner asks how a wall-free outdoor area gets a size and boundary. The existing
spec defines a host-selected center and 30 m default radius, selectable from 20–60 m.
The current native create request hard-codes 30 m; the host size selector is not
implemented by this scan-feedback PR and must not be described as available UI.
That circle is coarse play eligibility, not bullet collision geometry or a promise
of camera coverage. Preserve uncertain-location behavior rather than drawing a
falsely precise GPS edge. A perimeter/polygon editor is a future independent UI
and contract change, not needed to diagnose room mapping.

AR world tracking depends on stable visual detail; it does not need enclosing
walls. Apple's [world tracking guidance](https://developer.apple.com/documentation/arkit/understanding-world-tracking)
explains the effects of low detail and lighting. A shared world map supplies a
common coordinate frame; it does not automatically define a playable boundary.

The deeper blocker is ADR 0009: the current residual gate requires the natural
reference to remain actively visible during combat. Reference capture also needs
all rectangle corners on the same detected plane geometry. Neither condition is
an iPhone 14 LiDAR requirement. They do constrain free movement and wall-free
venues. Before promising outdoor gameplay, evaluate a shared-frame alternative
with measured drift and multi-player body coverage, record an accepted decision,
and demonstrate walking/turning/ducking on both phones. Do not turn off the gate
or extend stale evidence to fabricate a playable result.
