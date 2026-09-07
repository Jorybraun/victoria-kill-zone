# Room scanning — accepted recovery slice

Status: Ready, 2026-09-07. Integration accepted for KIL-46 and the owner's
iPhone 14 report. Parent: saved arenas PR #70, above scan recovery PR #69.

## Outcome and frozen behavior

Room mapping, reference capture, and multiplayer alignment are separate steps.
A failed camera session must never continue asking the user to scan. During
mapping, use the camera's actual reason to guide the user: wait for startup,
move more slowly, find more detail, or continue mapping. Do not invent a scan
percentage, require LiDAR, or equate a usable map with multiplayer readiness.

Standalone setup uses these steps: `1 · Scan surroundings`, `2 · Choose reference`,
`3 · Save arena`. The camera remains visible. Use the existing palette, adaptive
text, labelled controls, and 44-point actions. No debug buttons or raw telemetry
on the play screen. Keep the existing Restart scan and Cancel actions.

Terminal camera interruption, timeout, unavailable tracking, and unsupported
hardware have specific recovery copy. A live limited-tracking condition gives
guidance while the existing deadline runs. On timeout or session failure, the
screen asks for restart; it cannot save, capture, or arm combat from failed state.
Background teardown and explicit restart retain their current ownership rules.

## Local contract and ownership

Targeting owns `DuelFrameScanFeedback` with waitingForCamera, initializing,
movingTooFast, insufficientDetail, trackingLimited, trackingUnavailable,
relocalizing, mapping, ready. A snapshot starts waitingForCamera; an observation
may supply feedback. Only a fresh, correctly scoped mapping observation updates
it. Missing feedback uses existing tracking/map state, preserving fake-driver
compatibility. It never changes readiness, timing thresholds, or a wire DTO.

Integration owns `ArenaScanPresentation`, setup and initial host-scan UI, Xcode
membership, UI regressions, and documentation. Targeting owns the AR adapter,
local frame models/policy/helper, and their existing policy test file. No backend,
projectile engine, transport, or multiplayer gate changes in this slice.

## Acceptance

- Camera interruption replaces scanning copy and blocks capture/save.
- Restart returns to mapping, rejects old state, and permits a new valid capture.
- Excessive motion and insufficient features produce different actionable copy.
- Wrong-epoch, wrong-phase, and stale observations cannot replace current feedback.
- Existing extending-map eligibility, timeout, relocalization, and fire gates pass.
- `pnpm verify`, affected Swift tests, and iOS compile pass on the PR head.
- The owner's iPhone 14 must actually reach reference capture and save; a second
  phone must align before any multiplayer success claim. Device evidence pending.

Outdoor clarification: initial mapping should point at nearby ground and fixed
objects, with no enclosing-wall requirement. Boundary size remains a separate
host-selected geofence. This feedback slice does not claim to remove ADR 0009's
continuous-reference limitation or establish freely moving outdoor gameplay.
