# Quick Play setup (relocalized frame)

Frozen scope under accepted [ADR 0010](../../docs/decisions/0010-quick-play-relocalized-frame-and-phone-proxy.md). Covers the pregame surface of Home → CREATE ARENA and the recovery states during a match. Existing combat HUD (ammo, reload, hold-to-fire, shield, slow field, health, round time, menu) from slice 009 is unchanged. The saved-arena flow keeps its current measured setup (reference thumbnail, capture retry) and is not covered here.

**Post-freeze amendment (ADR 0012, accepted 2026-09-18).** For unsaved Quick Play matches the setup ritual is now the [NI rendezvous](#ni-rendezvous-adr-0012) below: it replaces the collaborative co-view guidance of [slice 011](011-quick-play-collaborative-setup.md) ("Linking play area" / "Move toward the play area…") *during setup*. The relocalized-frame states in the tables that follow remain the record for the saved-arena share path and for the recovery copy carried into the rendezvous flow; nothing below the amendment changes. Because this alters a setup acceptance condition after freeze, it requires integration approval and a handoff to the integration (token relay, rendezvous client flow) and targeting (NI session manager, transform solver, DuelFrame policy branch) owners per AGENTS.md.

## NI rendezvous (ADR 0012)

### Ordering

Connecting → *Nearby Interaction permission (first run only)* → **Rendezvous** → Aligned / waiting (ready roster) → PLAY → Running. Rendezvous sits where slice 011's Aligning stage sat: after every participant's socket is up and discovery tokens have been exchanged, and before the ready roster. The host's PLAY is enabled only when every connected participant reports a solved transform ("aligned"); joiners see the roster read-only. A participant who joins after PLAY runs the permission prompt (if needed) and the rendezvous against the players already in the match and cannot fire until solved.

Collaborative mapping (ADR 0011) starts at Connecting and stays enabled for the life of the match, but it is a background refinement: no setup state waits on an `ARParticipantAnchor` merge, and no setup copy asks players to co-view a spot or move toward the play area. When a merge does occur the match-menu status detail upgrades silently (see copy); the player is never asked to do anything for it.

### User states

| Stage | All participants (host and joiner identical unless noted) | Primary action |
|---|---|---|
| Connecting | "Connecting players (n/m)" | none |
| NI permission (first run) | System Nearby Interaction prompt over a pre-prompt card: title "Find your squad", body "Pew Pew uses Nearby Interaction to sense how far away the other phones are and which way they're facing. Nothing is stored or shared." | **Continue** (presents the system prompt) |
| NI denied | Blocker: "Nearby Interaction is off" / "Quick Play needs it to find the other players. Turn it on in Settings, then come back." | **Open Settings**, Leave (menu) |
| NI unavailable | Blocker: "This phone can't run Quick Play" / "Quick Play needs an iPhone 11 or later (not SE)." | Leave |
| Rendezvous | "Point at your squad" / "Stand 1–4 m apart and aim your camera at the other players. Hold for a moment." A 3 s hold ring fills while ≥1 direction-bearing sample per peer is being collected; the roster shows a per-player *found* mark as each pair solves. | none — automatic |
| Rendezvous retry | "Turn to face each other" / "We can see the distance but not the direction. Point your cameras straight at each other." Ring resets; per-player marks name who is missing. | none — automatic (no skip-player action) |
| Rendezvous failed | "Couldn't find your squad — try again" / "Stand closer (within 4 m), face each other and keep the phones steady." | **Try again**, Leave (menu) |
| Aligned / waiting | "Aligned — waiting for players (n/m)" roster with per-player aligned/aligning marks | host: PLAY when all aligned |
| Running | combat HUD (slice 009) | fire etc. |
| Re-aligning (degraded) | "Hold steady — re-aligning" banner; fire disabled (existing treatment) | none; auto-clears |
| Lost | "Alignment lost" blocker | **Re-align** (re-runs Rendezvous), Leave |

### Interaction behaviour

- The pre-prompt card is shown once per install, immediately before the first `NISession.run()`. If the system prompt was already answered the card is skipped. Granting proceeds straight to Rendezvous.
- Denial (sessions invalidated with `NIError.userDidNotAllow`) shows the *NI denied* blocker. Open Settings deep-links to the app's Settings page; returning to the app re-checks permission and, if granted, resumes at Rendezvous without re-showing the card. The blocker is a full-screen state over the live camera, not a sheet. The host is blocked from PLAY while any connected participant is in *NI denied* or *NI unavailable*; that participant appears in the roster as "needs Nearby Interaction" / "unsupported phone".
- *NI unavailable* (`NISession.deviceCapabilities.supportsPreciseDistanceMeasurement == false`) is terminal for this match. It is not a route to the collab-only flow: setup does not fall back to co-view guidance.
- Rendezvous starts as soon as tokens for every connected peer have been received. The ring is a 3 s hold, not a countdown: it fills at the rate direction-bearing samples arrive and resets on a lost direction. It completes when every pair has ≥1 direction-bearing sample and the transform cross-check accepts a consistent subset (ADR 0012 §3).
- *Rendezvous retry* replaces the prompt after 5 s of distance-only samples (direction nil) for any pair. It reverts to *Rendezvous* the moment direction returns. Retry is silent on haptics; success posts one light impact.
- *Rendezvous failed* appears after 30 s without a solve, or if a peer's NI session invalidates for any reason other than denial. **Try again** restarts sessions and returns to *Rendezvous*.
- If the U2 hedge (ADR 0012 §5a) is active, a bootstrap-only camera-assistance phase runs *inside* Rendezvous with the same copy; it is invisible to the player. If hedge (b) (distance-only solve) is active the Rendezvous body reads "Stand 1–4 m apart, face each other and take a few slow steps sideways." and the ring is a step-count fill; the retry state is not used.
- Rendezvous **replaces** slice 011's Aligning copy during setup. "Linking play area", "Move toward the play area…" and "Stand side by side and point at the same spot" do not appear in any setup or recovery state of this flow. The collab refinement stays on and its only surface is the match-menu status detail.
- Fire remains locked until the local transform is solved (existing disabled trigger treatment). `phoneProxy` verdicts use NI peer positions from the solve onward; a later `ARParticipantAnchor` merge is not required to fire.
- Degraded (direction lost mid-match while distance continues) does not tear down the session or change the HUD: peer markers hold their last direction-bearing position. The *Re-aligning* banner is used only when ARKit tracking itself is limited, as in the tables below. Lost (no NI sample from a peer for 15 s and no ARKit merge to fall back on) shows the blocker; **Re-align** re-runs Rendezvous with the connected peers.
- Backgrounding during Rendezvous returns to Rendezvous (NI peer sessions are foreground-only); backgrounding after solve returns to the last stage.
- Camera stays visible in every state; opaque backing only immediately behind legible text (slice 009 rule).

### Copy tokens

- `quickplay.ni.preprompt.title` "Find your squad"; `.body` "Pew Pew uses Nearby Interaction to sense how far away the other phones are and which way they're facing. Nothing is stored or shared."; `.action` "Continue"
- `quickplay.ni.denied.title` "Nearby Interaction is off"; `.body` "Quick Play needs it to find the other players. Turn it on in Settings, then come back."; `.action` "Open Settings"
- `quickplay.ni.unavailable.title` "This phone can't run Quick Play"; `.body` "Quick Play needs an iPhone 11 or later (not SE)."
- `quickplay.rendezvous.title` "Point at your squad"; `.hint` "Stand 1–4 m apart and aim your camera at the other players. Hold for a moment."; `.hint.stepping` "Stand 1–4 m apart, face each other and take a few slow steps sideways."
- `quickplay.rendezvous.retry.title` "Turn to face each other"; `.hint` "We can see the distance but not the direction. Point your cameras straight at each other."
- `quickplay.rendezvous.failed.title` "Couldn't find your squad — try again"; `.hint` "Stand closer (within 4 m), face each other and keep the phones steady."; `.action` "Try again"
- `quickplay.roster.found` "found"; `.needsNI` "needs Nearby Interaction"; `.unsupported` "unsupported phone"
- `quickplay.status.detail.ni` "Aligned by squad rendezvous (approximate)"; `.refined` "Aligned by squad rendezvous · refined by shared map"
- `NSNearbyInteractionUsageDescription` (Info.plist, integration-owned): "Pew Pew uses Nearby Interaction to find the other players' phones during a match."
- Unchanged: `quickplay.waiting`, `quickplay.play.action`, `quickplay.degraded`, `quickplay.lost.title`/`.action`.

### Accessibility

- The hold ring exposes its fill as an accessibility value and the per-player found marks as labels ("Alex — found"). Stage changes and the retry prompt post announcements. Reduce Motion replaces the ring animation with a static fill. All actions are at least 44 × 44 points.

### Acceptance evidence

Design accepts the rendezvous states on native renders of every state above (small and large phone, light and dark, camera visible behind each, including the pre-prompt card with the system prompt overlaid). Physical acceptance is recorded by integration in `docs/build-log.md` against ADR 0012's "Evidence to collect", two phones minimum (iPhone 14 U1, iPhone 16 U2), models, iOS versions and build named:

1. **U2 direction check** — the iPhone 16 reports `direction` to the peer at 1–4 m, back cameras facing, recorded per device; if nil, which hedge path (a or b) delivered and that the corresponding copy variant (`hint` vs `hint.stepping`) showed.
2. **Rendezvous** — time from match join to solved transforms and success rate across ≥5 attempts; the *retry* state observed at least once by deliberately turning a phone away and clearing on re-facing; transform residual vs a later `ARParticipantAnchor` merge and the status detail upgrading to `.refined`.
3. **Live ranging** — peer marker error vs visual estimation at ~3 m and ~8 m; behaviour on turning away (marker holds, no banner) and recovery time on re-facing.
4. **Permission** — grant flow (card → prompt → Rendezvous), deny flow (blocker → Open Settings → return → Rendezvous without re-showing the card), and the host roster showing "needs Nearby Interaction" while a peer is denied.
5. **Combat** — `phoneProxy` verdicts and health/ammo/K-D convergence under NI-seeded alignment before any map merge, same bar as ADR 0011.
6. **Setup-log export** — both phones export NI session state, direction-bearing sample counts and transform residuals via the PR #99 diagnostics for every run above.

Simulator renders establish layout only; none of the above is satisfiable in the simulator.

---

## Relocalized-frame states (ADR 0010, unchanged)

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
