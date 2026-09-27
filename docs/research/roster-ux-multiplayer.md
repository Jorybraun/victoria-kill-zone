# Roster UX for 2–4 player Quick Duel: product model, identity cues and terminology removal (BIO-37)

Status: Research complete — 2026-09-27. Read-only spike for [BIO-37](https://linear.app/biossphere/issue/BIO-37). Builds on — does not repeat — [zero-step-architecture-synthesis.md](zero-step-architecture-synthesis.md) and its seven BIO-36 briefs (especially [zero-step-play-product-model.md](zero-step-play-product-model.md), whose §3 route audit this document re-runs against the newer `main`), and [ADR 0013](../decisions/0013-quick-play-sighting-hits.md).
Method: one source audit of Home, Join, Lobby/WaitingRoom, the realtime controller/presentation/view, Convex match admission/preparation, and the combat protocol/simulation on `main` at `3d89b7f` (clean, 2026-09-27; #134 merged, #135 open and **not** on `main` — its branch diff was read separately); one primary-documentation pass (Apple Vision, ARKit, HIG). No code was changed, no build or test was run, and no device was used.

Evidence labels used throughout: **[repo]** = confirmed by reading source on `main`; **[Apple n]** = primary documentation; **[BIO-36 n]** = a source already established by a predecessor brief and reused, not re-fetched; **Inference** = reasoning from the above; **Proposal** = product/engineering recommendation, not an observed behaviour; **Unverified on device** = nothing in the repository or this sprint shows it on physical phones.

## 1. The question

The product owner removes the shared-frame / Saved Arena concept entirely and makes Quick Duel (ADR 0013 camera body-sighting, each phone in its own AR frame, the match Durable Object as authority) the only play mode, for **2–4 players with zero setup**. What must every player-facing surface say and show so that a 3- or 4-player match feels as immediate as today's 2-player duel, while being honest about the one thing a body sighting cannot tell by itself — **which** opponent is in the reticle?

This brief defines the user-facing contract. It deliberately does **not** choose the identity mechanism for 3–4 players (UWB bearing, pose exchange, appearance, etc.); ADR 0013 point 8 names that as separate work. The contract below is written so it holds for any identity source that reports a per-shot `targetPlayerId` with a confidence, and so that the product remains playable if that source is weak or absent on some phones.

## 2. Verified repository facts

| Premise from the assignment | Verdict | Evidence |
|---|---|---|
| Fire carries origin/direction + optional `BodyObservation{targetPlayerId, colliders…}` chosen client-side by `RealtimeAssociationPolicy.associateSighting`; 2-player = the only opponent | **Confirmed.** | [repo] `packages/combat-protocol/src/index.ts` `fire` command `{shotId, poseSequence, origin, direction, observation?}`; `BodyObservation` = `targetPlayerId, capturedAtMs, associationConfidence, uncertaintyMeters, colliders`. `Features/Realtime/RealtimeBodyAssociation.swift` `associateSighting` returns nil unless the roster minus the local player has **exactly one** member; that member is the target. |
| Vision body pose drives skeleton detection in `ios/**/Targeting/**` | **Confirmed, with a qualification that matters for 3–4 players.** | [repo] `Targeting/TargetingSession.swift` holds a `VNDetectHumanBodyPoseRequest`; when ARKit body tracking is active it prefers `frame.anchors … ARBodyAnchor … .first(where: \.isTracked)`, otherwise it maps all Vision results to candidates and keeps only `.max(by: score)`. **At most one body per frame reaches the match controller.** |
| Convex owns lobby/match prep; `CombatRoom` DO runs `packages/combat-simulation`; wire types in `packages/combat-protocol` | **Confirmed in source; runtime not re-verified here** (BIO-36 covered deployment). | [repo] `convex/functions/matches.ts`, `convex/functions/combat.ts` (`prepare`), `services/combat-worker`, `packages/combat-simulation/src/index.ts`. |
| iOS 17 target; any mix of LiDAR/non-LiDAR, UWB/no-UWB | **Taken as given** (predecessor briefs verified the project setting). Relevant here only as a UX constraint: the product must not require a capability some phones lack. | [BIO-36] zero-step-play-product-model.md §2. |
| Lobby already knows roster, host, ready | **Confirmed; colour is absent.** | [repo] `convex/functions/schema.ts` `players` = `displayName, role (host/guest), ready, connected, lifeState, health, ammo, kills, deaths …`; no colour, slot or badge field. `CombatPlayerState` (protocol) likewise has no colour. |

### 2.1 The two-player cap is enforced in four independent places

| Layer | Rule | Evidence |
|---|---|---|
| iOS lobby | `QuickDuel.maxPlayers = 2`; unsaved DO matches are created with `geometry: "sighting"`, `maxPlayers: 2`; saved arenas use `trackedBody`, 4 | [repo] `Domain/LobbyModels.swift`, `Features/Lobby/LobbyStore.swift` |
| Convex admission | `QUICK_DUEL_MAX_PLAYERS = 2`; `create` pins sighting capacity to 2; `join` fails `QUICK_DUEL_FULL` at 2; `prepare` fails `QUICK_DUEL_FULL` above 2, and otherwise requires **every** player connected (seen ≤ 15 s) and ready | [repo] `convex/functions/combat.ts` L27, L56–60; `convex/functions/matches.ts` L99, L149 |
| Authority | sighting `fire` is refused `ambiguousTarget` whenever `opponents.length !== 1` — i.e. by **roster size**, before looking at the observation; the observation's `targetPlayerId` must equal the single opponent or `invalidInput`; `associationConfidence < 0.8`, `uncertaintyMeters > 0.1` or no colliders → `noSighting` | [repo] `packages/combat-simulation/src/index.ts` L281–290 |
| iOS association | `associateSighting` exactly-one-opponent (above) | [repo] |

**Finding:** "remove the cap" is not a copy change. Lifting it in the lobby alone would produce a 3-player match in which every sighting shot is refused `ambiguousTarget` by the authority. The UX work in this brief is only shippable together with (a) an identity source and (b) an authority rule that accepts a per-shot `targetPlayerId` from a roster of up to four. That dependency is the single most important sequencing constraint (see §9).

**Finding (copy accuracy):** the iOS explanation for `ambiguousTarget` is "Too many players in view." [repo] `Features/Realtime/RealtimeCommandState.swift` L71. The authority actually emits it because of roster size, not because of what the camera saw. Today it is unreachable in a 2-player sighting match, but it would be wrong the moment a 3rd player is admitted.

### 2.2 Platform facts that bound the identity UX

- Vision: `VNDetectHumanBodyPoseRequest` "returns a unique observation for each detected human body pose", each with recognized points and a confidence [Apple 1][Apple 2]. So multiple people **can** be detected per image; the single-body limit in §2 is this app's choice, not Vision's.
- ARKit: `ARBodyAnchor` "tracks the movement of a single person" [Apple 4]; `ARFrame.detectedBody` is a single optional `ARBody2D` [Apple 5]; `ARBodyTrackingConfiguration` reports "a person" [Apple 3]. **Inference:** the ARKit 3D body path cannot supply multiple simultaneous candidates; Vision can.
- Neither Vision nor ARKit identifies **who** a person is. No Apple API in this pass maps a detected body to a peer device. This is an absence, stated as such; ADR 0013 point 8 and [BIO-36] shared-arena-frame-options §C already document Nearby Interaction as the named (unproven) candidate for per-peer bearing, with direction only inside a narrow rear cone and best within ~9 m [Apple 8].
- HIG: "Convey information with more than color alone … Offer visual indicators, like distinct shapes or icons" [Apple 6]; "Avoid relying solely on color to differentiate between objects … provide the same information in alternative ways" [Apple 7].

## 3. Surface audit on `main` (post-#134; #135 noted)

### 3.1 Routes

[repo] `App/RootView.swift` routes `.home → .join | .waiting(WaitingRoom) → .active`. Home still opens two Saved-Arena sheets: `onSavedArenas → showArenaLibrary(.scanLab)` (Map Lab) and `onUseSavedArena → showArenaLibrary(.createMatch)` (Saved Arena library → `pendingSavedArena` → create). #134 moved the Quick Duel vs Saved Arena decision into the lobby (`RealtimeArenaMode.select`) so a Quick Duel never constructs shared-frame services [repo, PR #134 description]. #135 (open) mirrors Convex's `phoneProxy → sighting` normalization in that selector and adds one terminal copy string: "This match's combat rules don't match this mode. Leave and start a new match." [PR #135 branch diff].

### 3.2 Home — `Features/Home/HomeView.swift`

| Element | Current | Assessment |
|---|---|---|
| Tagline | "Your world. The arena." | Brand line; "arena" is the removed mode's noun. Proposal: retire. |
| Subtitle | "Two players, one room. Start a Quick Duel or join a friend's code. Saved Arenas are the 2–4 player mode." | Wrong twice after the decision (player count; Saved Arenas). |
| Mode facts | `Label("2 players")`, `Label("Same room")` | Player count must become "2–4 players". |
| Primary | `QUICK DUEL` / `STARTING QUICK DUEL…`; `JOIN DUEL` | Keep. |
| Secondary section | `Label("SAVED ARENAS", "map")`, "Create a 2–4 player match in a saved arena.", "Saved Arena tools", `SCAN & SAVE A PLAY AREA` | Delete entirely. |
| Safety footer | "Find a clear play area. Stay aware of the world around you." | Safety intent is right; "play area" collides with the removed "shared play area" vocabulary. Proposal: "Find a clear, open space. Stay aware of the world around you." |

Delta vs BIO-36's audit: BIO-36 saw `CREATE ARENA` / `JOIN ARENA` / `SCAN & SAVE`; #125 renamed the primaries, but the Saved Arena block and the 2-player framing remain.

### 3.3 Join — `Features/Lobby/JoinDuelView.swift`, `LobbyStore.swift`

- `LobbyStore.joinButtonLabel` = `JOINING DUEL…` / **`JOIN ARENA`** — inconsistent with Home's `JOIN DUEL`. Delete "arena".
- "SCAN QR CODE" / "QR SCANNING UNAVAILABLE ON THIS DEVICE — ENTER THE CODE INSTEAD" — "scan" here means QR scanning, not room scanning. **Keep.**
- `BackendErrorCode.quickDuelFull` → `QuickDuel.rosterFullMessage` = "Quick Duel is 2 players; use a Saved Arena for 3–4". Must become a 4-player "match is full" message with no alternative mode.

### 3.4 Lobby — `Features/Lobby/WaitingRoomView.swift`, `WaitingRoomCopy` in `Domain/LobbyModels.swift`

| Element | Current | Assessment |
|---|---|---|
| Capacity | "`n` / `maxPlayers`" plus open-slot rows | Good foundation; becomes n/4. |
| Player row | display name; YOU / HOST / PLAYER; READY / NOT READY / DISCONNECTED pill | Covers name/host/ready/connection. **No colour or slot identity.** |
| Rules summary | savedArena: "2–n players · Shared play area"; quickDuel: "`n` players · Quick Duel"; classic: "`n` players · Classic mode" | Delete the savedArena branch. |
| `WaitingRoomCopy.Mode` | `.classic, .quickDuel, .savedArena`; `matchName(.savedArena)` "Arena"; `hostStartTitle(.savedArena)` "Align arena"; `allReadyGuidance(.savedArena)` "All players ready. Next, align your shared play area."; `waitingForHostGuidance(.savedArena)` "You're ready. Waiting for the host to begin alignment." | Delete `.savedArena` and its four strings. |
| Quick Duel ready copy | "Both players ready. Start when you are." | Two-player wording; becomes count-aware. |
| Invite | code + QR share | Keep; it is the only "setup" and it precedes the lobby, not the start. |

### 3.5 Active match — `RealtimeArenaView.swift`, `RealtimeArenaPresentation.swift`, `RealtimeArenaPolicy.swift`, `RealtimeCommandState.swift`

**Live HUD** [repo]: `telemetry` = local health capsule, round time, menu button; then action feedback and combat controls while running. Opponents appear in the live HUD **only** as the `targetCue` — a dashed rectangle around the projected skeleton labelled with the associated player's `displayName` (falls back to "Target") when `worldReady` and `associatedBody` exist. The `RealtimeRosterStrip` (name, "· YOU", kills/deaths, health bar, connected/respawning status) exists but is shown **only inside the match menu sheet** (L311), not on the live camera view.

**Hit feedback** [repo]: `receiveEvents` turns authoritative `projectileTerminal` (`reason == "bodyHit"`, `damage > 0`) into `RealtimeHitFeedback{targetPlayerID, zone, damage, incoming}`. The view flashes a hit marker and skeleton highlight (`fx.confirmHit`) or a red damage border for incoming hits. **The target's name is available in the event but is never shown.** Incoming hits do not name the shooter (`renderIncomingLaser(from: nil …)`).

**Refusal feedback** [repo]: `RealtimeCommandState.explanation` maps refusal reasons to one 4-second notice, also posted as a VoiceOver announcement. Relevant strings: `noSighting` "No target in view."; `ambiguousTarget` "Too many players in view."; `notReady/trackingLost/poseStale/poseMismatch` "Tracking needs a fresh view of players and the arena reference."; default "The action was not accepted. Try again when the arena is ready." The last two are reachable in Quick Duel today and contain removed vocabulary.

**Kill feed / scoreboard** [repo]: no kill feed. No dedicated kill event exists: `applyBodyHit` emits `playerChanged(shooter)` with `kills++`, then `projectileTerminal(bodyHit, targetPlayerId, zone, damage)`, then `playerChanged(target)` with `health == 0`, `deaths++`, `respawnAtMs` (`packages/combat-simulation/src/flight.ts` L124–137). **Inference:** a client can derive "A eliminated B" from one event batch without a protocol change. `finishedPanel` shows ranked players sorted by kills desc, deaths asc.

**Sighting stage copy** [repo] `RealtimeArenaPresentation.Sighting`: "Connecting to match", "Waiting for opponent", "Live match", "Camera paused" / "Stabilizing connection", "Reconnecting", "Eliminated", "Match complete", "Body tracking unavailable"; guidance "Keep your opponent in view…", "Point your camera at your opponent. The host can start once both players are ready." Neutral of shared-frame terms but **singular-opponent/two-player** throughout. Map/frame stages map to "Getting ready" as unreachable placeholders.

**Shared-frame copy still compiled into the active view** — see §8 for the complete list.

## 4. Product model once Saved Arena is gone (Proposal)

One mode, one noun. The mode is **Quick Duel**; a running instance is a **match**; the people are **players**; a lobby is identified by its **code**. There is no "arena", "play area", "scan", "align", "reference", "map", "frame" or "sync" in any player-visible string. "Duel" is kept as the brand name even at 3–4 players (Proposal; see open decision O1).

```
Home ──QUICK DUEL──▶ Lobby (host, code+QR, 1/4) ──friends join──▶ Lobby (n/4, ready pills)
  └──JOIN DUEL──▶ Join (code / QR) ──▶ Lobby
Lobby ──all n≥2 ready + host taps START──▶ Countdown 3-2-1 ──▶ Live match ──▶ Results ──▶ Rematch / Home
```

Home contains exactly: title, one-line subtitle, `QUICK DUEL`, `JOIN DUEL`, mode facts ("2–4 players", "Same room"), safety footer, credits. No sheets for Saved Arenas or Map Lab (developer tooling, if kept, moves out of the player build — open decision O2).

## 5. Lobby roster for 2–4 (Proposal unless marked)

**5.1 Row content.** Each occupied slot shows, left to right: colour swatch **with a slot glyph** (e.g. ●1 ▲2 ■3 ◆4 — shape + number, not colour alone [Apple 6][Apple 7]), display name, role tag (`HOST` / `YOU`), state pill (`READY` / `NOT READY` / `DISCONNECTED`). Open slots show "Waiting for player…" with the invite affordance. Header: "Players 3/4".

**5.2 Colour assignment.** Colour is a lobby fact, not a client preference:
- Assigned by Convex at join as the lowest free slot 1–4, stored on the player record, and carried into the combat roster so every phone renders the same colour for the same person. Today neither `players` nor `CombatPlayerState` has such a field [repo] — this is new data.
- Slot is stable for the match; a rejoin with the same session keeps it. A leaver frees the slot only while in lobby.
- Palette of four hues chosen for colour-vision-deficiency separation and legibility over camera video, always paired with the glyph and name. **Unverified on device:** legibility over outdoor camera feeds.

**5.3 Ready and start.** Convex `prepare` already requires every player connected and ready and ≥2 players [repo]. Copy becomes count-aware: "3 of 4 ready", host button `START` enabled only when all present players are ready; non-host sees "You're ready. Waiting for Maya to start." A 4th slot being empty never blocks start.

**5.4 Identity capability badge (only if the chosen identity source is device-dependent).** If the identity mechanism needs hardware some phones lack (e.g. UWB), the row shows a small neutral badge such as "Limited targeting" on that player, with an info sheet. It **never** blocks ready or start (owner decision: start is never gated). Proposal; depends on O3.

## 6. In-match UX for multiple opponents (Proposal unless marked)

### 6.1 Target cue — "who am I aiming at?"

The cue is driven by a per-frame **identity state** for the body under/near the reticle:

| State | Condition (abstract; mechanism-agnostic) | Cue | Fire |
|---|---|---|---|
| **Identified** | association to one roster member with confidence ≥ authority threshold (today 0.8 [repo]) | Frame in that player's colour + glyph + name label ("▲ Maya"); reticle tints to the colour | Enabled; shot carries that `targetPlayerId` |
| **Unidentified** | a body is detected but no single roster member passes the threshold (two candidates too close, identity source missing/stale) | Neutral grey frame, label "?" / "Can't tell who", reticle neutral | **Fail-closed (Proposal):** trigger gives an immediate local "Can't tell who that is — get a clearer look" and does not send a shot the authority would refuse; see O4 |
| **No body** | nothing detected | No frame | Trigger yields "No one in your sights" |
| **Teammate/self** | n/a in free-for-all | — | — |

Today's cue already implements the Identified row's name label for the single-opponent case; the Unidentified row does not exist because `associateSighting` returns nil (no cue) rather than "unknown" [repo]. **Inference:** because targeting currently forwards only the single best-scored body (§2), two opponents side by side will show one cue for whichever scores higher; the UX must not imply the other person is untargetable, and the cue must follow the reticle-nearest body once multi-candidate detection exists (engineering dependency, O5).

### 6.2 HUD for 2–4 players

- Top bar keeps local health and round time. Add an **opponent strip** beneath it: one compact chip per opponent (glyph+colour, short name, health pip bar, state icon: live / respawning countdown / disconnected). Max three chips, so it fits one row in portrait at default Dynamic Type; at accessibility sizes it collapses to glyph + health (full detail stays in the menu sheet). The existing `RealtimeRosterStrip` becomes the menu's detailed view.
- The chip of the currently Identified target is highlighted, so the name on the cue and the strip agree.
- Incoming damage: keep the red border and add the shooter's name + glyph for ~1.5 s ("Hit by ◆ Sam") — the authority's `projectileTerminal.shooterId` is authoritative [repo]. No directional arrow is proposed: each phone has its own AR frame and there is no shared frame to compute direction from (Inference).

### 6.3 Kill feed and scoreboard

- **Kill feed:** top-right, last 3 entries, 4 s each, derived from the event batch in §3.5: "● You eliminated ▲ Maya", "◆ Sam eliminated ● You". Uses the authority's shooter/target ids only. VoiceOver announces only entries involving the local player (avoid announcement spam in 4-player matches).
- **Live score:** kills shown in each opponent chip; a leader glyph on the chip with most kills. Tie-break for "leader" = kills desc, deaths asc (same as the existing finished ordering [repo]).
- **Results:** existing `finishedPanel` ranking, plus colour/glyph per row, "YOU" marker, and a per-player "hits landed" count if the client has retained them. Rematch keeps the same lobby and colours (Proposal; lobby rematch mechanics not audited here).

### 6.4 Ambiguity feedback — "who did I hit?"

The answer must always come from the authority's accepted event, never from the client's local guess at render time:
- On an accepted hit: hit marker + short toast in the victim's colour: "Hit ▲ Maya · torso −25" (target id, zone and damage are all in `projectileTerminal` [repo]).
- On an elimination: the toast upgrades to the kill-feed line.
- On a refused shot, the notice explains why in player language: `noSighting` → "No one in your sights"; `ambiguousTarget` → "Can't tell who that is — get a clearer look" (replacing "Too many players in view.", which misdescribes the authority rule, §2.1).
- **Honesty caveat (Inference):** under sighting the authority *trusts* the shooter's claimed `targetPlayerId` and validates only freshness, confidence and geometry [repo]. So "Hit Maya" means "the authority accepted your phone's claim it was Maya". If the identity source misattributes, the toast will be confidently wrong, and Maya's own phone will show an incoming hit she may dispute. Victim-side feedback naming the shooter ("Hit by ● Alex") is the product's main defence: it makes misattribution visible to the people in the room. Quantifying misattribution is a device-trial item (§9).

### 6.5 3–4 player start with zero setup

What the host and joiners do, end to end: host taps `QUICK DUEL` → lobby with code/QR → up to three friends `JOIN DUEL` (code or QR) → each taps READY → host taps `START` → 3-2-1 countdown on every phone → live. There is no step between START and live other than the existing connection/clock stabilisation ("Connecting to match" / "Stabilizing connection" [repo]). No screen asks anyone to point at anything, stand anywhere, face anyone or wait for anyone else's camera. The live HUD shows opponent chips immediately; target cues appear as soon as a body is detected, Identified or not.

"Zero setup" does not promise zero *permissions*: if the identity source requires one (e.g. Nearby Interaction's permission prompt), it is requested in the lobby on READY, and denial degrades to §7 rather than blocking (Proposal; ADR 0013 rejected a permission step **in front of PLAY** — asking at READY is a judgement call, O3).

## 7. Degraded identity states (explicit and playable)

| Degraded condition | What the player sees | What still works |
|---|---|---|
| Two+ opponents close together in view | Cue "?" / "Can't tell who"; trigger feedback per §6.4 | Move, shield, reload; firing resumes when one body is Identified |
| Identity source unavailable on *my* phone (permission denied, hardware absent) | Persistent small HUD tag "Limited targeting — hits need a clear view of one player"; lobby badge (§5.4) | Everything; shots Identified only when a single opponent is the only candidate (Inference; depends on O3/O4) |
| Identity source unavailable on *an opponent's* phone | Nothing different, unless the mechanism is pairwise (then that opponent's cue may stay "?" more often) | Everything |
| Identity source briefly stale | Cue falls back to "?" within ≤ the observation freshness window; no toast | Everything |
| Opponent disconnected | Chip greys with "Disconnected"; their body, if seen, is never Identified as them | Everything |
| Camera/tracking paused (existing) | "Camera paused … Keep players in view." (neutral, plural) | Match continues; local fire gated (existing behaviour [repo]) |
| Bystander in view (non-player) | Should be Unidentified. **Known risk:** in a 2-player match today any body is attributed to the opponent (ADR 0013 "RealTag bystander" consequence [repo]) | — |

Principle (Proposal): uncertainty removes **attribution**, never the match. No degraded state pauses the match, returns anyone to the lobby, or shows a setup instruction.

## 8. Terminology to delete (complete audit of player-visible strings)

Method: `rg -i` for `scan|align|arena|relocaliz|calibrat|linking|squad|play area|shared frame|reference|map` inside string literals under `ios/VictoriaKillZone/VictoriaKillZone/{App,Features,Domain,DesignSystem,Services}`, comment-only lines excluded, then each hit classified by hand [repo]. Internal type/identifier names (`RealtimeArenaView`, `arenaState`, `arenaRadiusMeters`, wire keys) are not player-visible and are out of scope for this copy list.

**A. Reachable from the normal Quick Duel path today — delete or rewrite first**

| File | String(s) |
|---|---|
| `Features/Home/HomeView.swift` | "Your world. The arena."; "Two players, one room. … Saved Arenas are the 2–4 player mode."; "SAVED ARENAS" (+ `map` icon); "Create a 2–4 player match in a saved arena."; "Saved Arena tools"; "SCAN & SAVE A PLAY AREA"; "2 players"; "Find a clear play area." (rewrite) |
| `Domain/LobbyModels.swift` | `QuickDuel.rosterFullMessage` "Quick Duel is 2 players; use a Saved Arena for 3–4"; `WaitingRoomCopy` "Arena", "Align arena", "All players ready. Next, align your shared play area.", "You're ready. Waiting for the host to begin alignment."; two-player "Both players ready. Start when you are." (rewrite) |
| `Features/Lobby/WaitingRoomView.swift` | "… players · Shared play area" |
| `Features/Lobby/LobbyStore.swift` | "JOIN ARENA" |
| `Features/Realtime/RealtimeCommandState.swift` | "Tracking needs a fresh view of players and the arena reference."; "The action was not accepted. Try again when the arena is ready."; "Too many players in view." (rewrite, §6.4) |
| `Services/Realtime/RealtimeCombatSession.swift` | "This match is no longer available. Leave and join a new arena." |
| `Features/Realtime/RealtimeArenaPresentation.swift` (`Sighting`) | singular/two-player: "Waiting for opponent", "Keep your opponent in view…", "Point your camera at your opponent. The host can start once both players are ready."; placeholder "Getting ready" for unreachable map stages (delete with the stages) |

**B. Saved-Arena / shared-frame only — deleted with the feature (no rewrite needed)**

| File | String(s) |
|---|---|
| `Features/Realtime/RealtimeArenaPolicy.swift` / `RealtimeArenaPresentation.swift` stage titles | "Scan the play area", "Arena scan ready", "Waiting for the host's scan", "Sharing the arena", "Find the same area", "Align the arena" (×2), "Waiting for players to align", "Alignment lost", "Tracking paused", "Arena unavailable"; pause guidance "Keep the shared play area…", "Point at the shared play area to recover alignment…" |
| `Features/Realtime/RealtimeArenaView.swift` | menu: "Aligned by Nearby Interaction + live peer merge", "Aligned by live peer merge", "Aligned by shared scan (approximate)"; "Reference: %.0f cm · %.2f°"; "SHARE ARENA"; "Sends the scan so the other phones can align with this play area"; "Scan again", "Restart scan", "Re-align", "Retry alignment"; "Hold still while the reference is measured."; "Loading … Point at the fixed objects you scanned…"; "Couldn't map this area — try somewhere with more detail"; "The camera couldn't find enough stable detail…restart the scan."; "Move slowly around the play area…"; "Ready to share. Send the scan…"; "Reference captured. Share the scan…"; "Ready to capture. Choose a reference below…"; "Waiting for the host's arena scan…"; "Keep this screen open while the shared arena scan transfers."; "Look at the area you scanned" / "…the host scanned"; "Point at the same fixed objects the host scanned…"; "This older arena scan has no shared reference…"; "Point at the reference shown below…"; "Aligned — waiting for players (a/t)"; "…everyone has finished alignment."; "Hold steady — re-aligning"; "Couldn't align — move closer to where the host scanned"; "Alignment lost. Re-align to rejoin the shared play area."; "the saved arena"; "Couldn't recognize … objects you scanned…"; "…checking the shared arena before input resumes."; "Joining the shared arena and synchronizing the match clock."; "Set up play area"; "Scan the area"; "Re-aligning"; "Alignment lost"; "Scan needs another try"; "Align with saved arena"; roster "Aligning" / accessibility "aligning" |
| `Features/Realtime/RealtimeReferencePanel.swift` | "The shared scene reference", "Arena reference", "Share arena scan", "Choose another reference", "Use a fixed picture or sign…", "Measuring reference…", "Capture reference", "Scan the surrounding surface slowly…" |
| `Features/Arenas/*` (`ArenaSetupView`, `ArenaScanPresentation`, `SavedArenaLibraryView`, `ArenaSetupController`, `SavedArenaLibrary`), `Domain/SavedArenaModels.swift`, `Services/SavedArenaStore.swift` | whole feature (≈ 68 matching lines) |
| `Features/MapLab/*`, `Domain/MapLabModels.swift`, `Services/MapLabStore.swift` | Map Lab developer tool (≈ 42 matching lines) — player-facing only because Home opens it; see O2 |
| `Features/Realtime/RealtimeArenaController.swift` | env flag `VKZ_QUICKPLAY_MAP_FALLBACK` (not player-visible; dies with the fallback) |
| #135 (open) | "This match's combat rules don't match this mode. Leave and start a new match." — only meaningful while two modes exist; becomes a generic "outdated server/app" message once Saved Arena is gone |

**C. Classic (non-DO) mode — outside this decision, flagged**
`Features/Game/DuelSession.swift` "RETURN TO THE ARENA"; `Domain/GameSessionModels.swift` `OUT_OF_ARENA`, `INVALID_ARENA`. These belong to the geofenced classic mode, not the shared frame. Whether classic mode remains player-reachable is not settled here (O6).

**D. Keep**
"SCAN QR CODE", "QR SCANNING UNAVAILABLE…" (QR, not room scanning); `hitscan` (wire value).

## 9. Dependencies and sequencing

1. **Authority rule** (combat-simulation/protocol): accept a sighting `fire` with `targetPlayerId` ∈ roster \ {shooter}, alive and connected, instead of `opponents.length !== 1 → ambiguousTarget`. Without this, no 3–4-player UX can ship (§2.1).
2. **Admission** (Convex + iOS `QuickDuel`): cap 4 for sighting; `QUICK_DUEL_FULL` at 4.
3. **Identity source + client association** (Targeting + `RealtimeBodyAssociation`): multi-candidate detection (Vision already returns multiple observations [Apple 2]; the app keeps one) and a per-candidate roster assignment with confidence. Mechanism is out of scope (ADR 0013 point 8).
4. **Roster colour/slot field** (Convex `players` → combat roster → iOS models).
5. **Copy and HUD** (this brief §4–§8).
6. **Device trial** — nothing in §6–§7 has device evidence. Minimum: 3- and 4-player matches recording Identified/Unidentified rates at 3/5/8 m, two opponents within ~1 m of each other, a bystander walk-through, misattributed-hit count confirmed by the victim, and chip/cue legibility outdoors. Extends BIO-36 trial rows A2 and ADR 0013 validation item 5.

Steps 1–3 can ship dark behind the current 2-player cap; step 2 is the switch.

## 10. User-facing acceptance criteria

All are **targets**. Criteria marked (device) cannot be satisfied by code review or unit tests and require physical-phone evidence.

1. Home shows exactly `QUICK DUEL` and `JOIN DUEL` as play actions, states "2–4 players", and contains no Saved Arena, Map Lab, scan or arena entry.
2. No player-visible string on Home, Join, Lobby, the live match, the match menu, results, errors or VoiceOver announcements contains "arena", "scan" (except QR), "align", "relocaliz", "reference", "map", "play area", "shared", "frame" or "sync". Verifiable by a string-table test over §8 categories A and B.
3. A lobby admits 2, 3 or 4 players; a 5th joiner sees "This match is full (4 players)." with no suggestion of another mode.
4. Every lobby row shows name, a colour **and** a distinct slot glyph, HOST/YOU tags, and READY / NOT READY / DISCONNECTED; the same player has the same colour and glyph on every phone and in every in-match surface.
5. With 3 or 4 players all ready, the host's single `START` tap leads to a countdown and a live match on every phone with no intermediate screen or instruction (code-tier); median START-to-live ≤ 5 s over ≥ 10 trials (device).
6. Start is never blocked by any player's hardware capability, permission choice or camera view.
7. While a single opponent is Identified, the target cue shows that opponent's name, colour and glyph, and the highlighted opponent chip matches it.
8. When a body is detected but not Identified, the cue shows an explicit unknown state ("?"), never a name and never another player's colour.
9. The live HUD shows every opponent's name/glyph, health and live/respawning/disconnected state without opening a menu, at default and accessibility text sizes.
10. Every accepted hit by me shows the victim's name from the authority event within one event batch; every hit on me names the shooter.
11. Every elimination produces a kill-feed line naming both players; the results screen ranks all players by kills desc, deaths asc, with colour/glyph and a YOU marker.
12. A refused shot always shows a reason in player language; `ambiguousTarget` never says "Too many players in view" and `noSighting` says "No one in your sights".
13. No identity-degraded state pauses the match, returns anyone to the lobby, or shows a setup instruction; the affected player can still move, shield and reload.
14. Colour is never the only carrier of identity (glyph + name always present) [Apple 6][Apple 7]; VoiceOver labels include name, glyph word, health and state.
15. (device) In a 3-player trial, a shot on a non-player bystander is recorded as refused/Unidentified rather than attributed; misattributed accepted hits (victim disputes) are counted and reported, with a pass threshold set after the first trial (O7).

## 11. Open decisions

- **O1** Keep the name "Quick Duel" for 3–4 players, or rename (e.g. "Quick Match")? Brief assumes keep.
- **O2** Remove Map Lab from the player build, or keep it behind a developer flag?
- **O3** Which identity source for 3–4 players, and is its permission (if any) requested at READY? Determines whether §5.4/§7 "Limited targeting" exists at all.
- **O4** Unidentified trigger policy: fail-closed locally (recommended; matches the authority's fail-closed refusals), or send a best-guess target and accept misattribution?
- **O5** Multi-candidate detection: switch from "best single body" to Vision multi-observation, which may change ARKit 3D body-anchor use on LiDAR phones.
- **O6** Is classic (non-DO, geofenced) mode still player-reachable? If yes, its "arena" copy needs its own decision.
- **O7** Acceptable misattribution rate for release.

## 12. Absences (stated, not converted into claims)

- No physical-device evidence exists for any sighting match, 2-player or otherwise, in the repository or this sprint.
- No Apple API found that identifies which detected person corresponds to which peer device.
- No colour/slot field exists in Convex or the combat protocol.
- No kill event, kill feed or shooter-name UI exists; kill attribution is derivable from existing events.
- No Cloudflare documentation was needed or consulted in this round: all authority facts here are repository facts; runtime/deploy behaviour was covered by BIO-36.
- #135 lifecycle beyond "open" was not tracked.

## Sources

1. Apple — VNDetectHumanBodyPoseRequest ("A request that detects a human body pose"; results as `VNHumanBodyPoseObservation`) — https://developer.apple.com/documentation/vision/vndetecthumanbodyposerequest
2. Apple — Detecting Human Body Poses in Images ("returns a unique observation for each detected human body pose"; up to 19 body points; iOS 14+) — https://developer.apple.com/documentation/vision/detecting-human-body-poses-in-images
3. Apple — ARBodyTrackingConfiguration ("When ARKit identifies a person in the rear camera's feed…") — https://developer.apple.com/documentation/arkit/arbodytrackingconfiguration
4. Apple — ARBodyAnchor ("tracks the movement of a single person") — https://developer.apple.com/documentation/arkit/arbodyanchor
5. Apple — ARFrame.detectedBody (`ARBody2D?`, a single optional body) — https://developer.apple.com/documentation/arkit/arframe/detectedbody
6. Apple HIG — Accessibility ("Convey information with more than color alone … distinct shapes or icons") — https://developer.apple.com/design/human-interface-guidelines/accessibility
7. Apple HIG — Color ("Avoid relying solely on color to differentiate between objects…") — https://developer.apple.com/design/human-interface-guidelines/color
8. Apple — Nearby Interaction: Initiating and maintaining a session (best within ~9 m; direction only in rear cone) — reused from shared-arena-frame-options.md source 23, not re-fetched — https://developer.apple.com/documentation/nearbyinteraction/initiating-and-maintaining-a-session

Repository evidence (cited inline by path, `main` @ `3d89b7f`): `ios/VictoriaKillZone/VictoriaKillZone/{App/RootView.swift, Features/Home/HomeView.swift, Features/Lobby/{JoinDuelView,WaitingRoomView,LobbyStore}.swift, Domain/{LobbyModels,GameSessionModels}.swift, Features/Realtime/{RealtimeArenaView,RealtimeArenaPresentation,RealtimeArenaPolicy,RealtimeArenaController,RealtimeBodyAssociation,RealtimeCommandState,RealtimeReferencePanel}.swift, Services/Realtime/RealtimeCombatSession.swift, Targeting/TargetingSession.swift}`; `convex/functions/{schema,matches,combat}.ts`; `packages/combat-protocol/src/index.ts`; `packages/combat-simulation/src/{index,flight}.ts`; `docs/decisions/0013-quick-play-sighting-hits.md`; `AGENTS.md` (Phase 1 cap 4); PR #134 (merged) and #135 (open) descriptions; `origin/devin/1790480685-quick-duel-review-fixes` diff.
