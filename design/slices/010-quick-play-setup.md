# Quick Play setup (relocalized frame)

Proposed scope under [ADR 0010](../../docs/decisions/0010-quick-play-relocalized-frame-and-phone-proxy.md); frozen once that record is accepted. Covers the pregame surface of Home → CREATE ARENA and the recovery states during a match. Existing combat HUD (ammo, reload, hold-to-fire, shield, slow field, health, round time, menu) from slice 009 is unchanged. The saved-arena flow keeps its current measured setup (reference thumbnail, capture retry) and is not covered here.

## User states

| Stage | Host | Joiner | Primary action |
|---|---|---|---|
| Scanning | "Scan the area" — walk slowly and look around until the ring fills. Progress copy follows ARKit mapping status: "Starting tracking", "Mapping…", "Ready to share". | "Waiting for the host to scan" | none (host: SHARE ARENA becomes enabled at Ready) |
| Sharing | "Sharing arena…" with byte progress | "Receiving arena…" | none |
| Aligning | "Look at the area you scanned" | "Look at the area the host scanned" | none; countdown from 15 s shown after 5 s without alignment |
| Aligned / waiting | "Aligned — waiting for players (n/m)" roster with per-player aligned/aligning marks | same | host: PLAY when every connected player is aligned |
| Running | combat HUD (slice 009) | same | fire etc. |
| Re-aligning (degraded) | "Hold steady — re-aligning" banner over the camera; fire control disabled with the existing rejected-shot notice style | same | none; auto-clears |
| Lost | "Alignment lost" blocker with **Re-align** (reinstalls the shared map) and Leave in the menu | same | Re-align |
| Timed out (scan) | "Couldn't map this area — try somewhere with more detail" with **Scan again** | n/a | Scan again |
| Timed out (align) | "Couldn't align — move closer to where the host scanned" with **Re-align** | same | Re-align |

No reference panel, thumbnail, "hold the reference in view" copy or capture controls appear in Quick Play. No numeric residual or accuracy figure is shown; the match menu's status detail reads "Aligned by shared scan (approximate)".

## Interaction behaviour

- Scanning uses the existing 30 s mapping deadline; the ring maps `notAvailable → limited → extending → mapped` to 0/25/60/100 %.
- SHARE ARENA is a 44-point primary button enabled only at `mapped`; it captures the raw world map (no reference) and shares it once. A second tap is not possible until sharing fails.
- Alignment uses the existing 15 s relocalization window. Fire is locked until aligned; the trigger shows the existing disabled treatment, not a hidden control.
- PLAY (host) is enabled when every connected player reports aligned; joiners see the same roster read-only. Players who join after PLAY receive the map and align during the match; they cannot fire until aligned.
- Degraded (tracking limited while aligned) never tears down the session; it locks fire and shows the banner. Lost (relocalizing longer than 15 s) shows the blocker and requires an explicit Re-align.
- Backgrounding during setup returns to the last stage with a Re-align if the map was already installed.
- The setup surface keeps the camera visible at all times; controls are opaque only immediately behind legible text (slice 009 rule).

## Copy tokens

- `quickplay.scan.title` "Scan the area"; `.hint` "Walk slowly and look around until the ring fills."
- `quickplay.share.action` "SHARE ARENA"; `.progress` "Sharing arena…"; `.receiving` "Receiving arena…"
- `quickplay.align.host` "Look at the area you scanned"; `.joiner` "Look at the area the host scanned"
- `quickplay.waiting` "Aligned — waiting for players (%d/%d)"
- `quickplay.play.action` "PLAY"
- `quickplay.degraded` "Hold steady — re-aligning"
- `quickplay.lost.title` "Alignment lost"; `.action` "Re-align"
- `quickplay.timeout.scan` "Couldn't map this area — try somewhere with more detail"; `.action` "Scan again"
- `quickplay.timeout.align` "Couldn't align — move closer to where the host scanned"
- `quickplay.status.detail` "Aligned by shared scan (approximate)"

## Accessibility

- All actions are at least 44 × 44 points with descriptive labels; the progress ring exposes its percentage as an accessibility value; stage changes post an announcement.
- Banners and blockers are readable at accessibility text sizes; the roster collapses to one column.
- Reduce Motion replaces the ring animation with a static fill.

## Acceptance evidence

Design accepts this slice on native renders of every state above at a small and a large phone, in light and dark, with the camera visible behind each. Physical acceptance follows ADR 0010's evidence table and is recorded by integration in docs/build-log.md; simulator renders establish layout only.
