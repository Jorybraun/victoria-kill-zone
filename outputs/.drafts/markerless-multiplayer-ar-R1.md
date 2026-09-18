# ARKit Collaborative Sessions — Research Round 1 (markerless multiplayer AR alignment)

Scope: whether `ARWorldTrackingConfiguration.isCollaborationEnabled` + relayed `ARSession.CollaborationData` + `session.update(with:)` is a sound alignment architecture for a 4-player co-located iOS AR game, and why real devices may report "constantly re-aligning / never merges" (no `ARParticipantAnchor`).

Note on URLs: `apple-docs.everest.mt` results below are a mirror of Apple Developer documentation; canonical developer.apple.com paths are listed in Sources. Content quoted is from Apple's documentation text as surfaced through the mirror and WWDC transcript pages.

## Evidence Table

| # | Source | URL | Key claim | Type | Confidence |
|---|--------|-----|-----------|------|------------|
| 1 | Apple Docs — Creating a collaborative session | https://developer.apple.com/documentation/arkit/creating_a_collaborative_session | Collaboration requires visual overlap between users' world maps; sample tells users to hold phones side by side; ARParticipantAnchor signals merge; enabling collaboration after peers join is unsupported | primary | high |
| 2 | Apple Docs — isCollaborationEnabled | https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/iscollaborationenabled | Flag opts in to P2P multiuser AR; CollaborationData = surfaces + device position + created anchors; same OS version recommended; unarchive may fail across versions | primary | high |
| 3 | Apple Docs — ARSession.CollaborationData | https://developer.apple.com/documentation/arkit/arsession/collaborationdata | ARKit regularly outputs CollaborationData to share; has `priority` hint for network sending | primary | high |
| 4 | Apple Docs — ARSession.update(with:) | https://developer.apple.com/documentation/arkit/arsession/update(with:) | Feeds peer-collected environment info into local session; world-tracking configs only | primary | high |
| 5 | Apple Docs — ARParticipantAnchor | https://developer.apple.com/documentation/arkit/arparticipantanchor | Added via session(_:didAdd:) for each detected peer once collaboration is enabled; carries peer world position | primary | high |
| 6 | WWDC19 Session 610 — Building Collaborative AR Experiences | https://developer.apple.com/videos/play/wwdc2019/610/ | Decentralized, no host; CollaborationData pushes chunks of ARWorldMap stored as "external maps"; merge only when a device sees area another user saw; ARParticipantAnchor = localization succeeded; practical advice: side-by-side same-direction viewing + one user at .mapped status; app must retransmit failed sends; transport can be MultipeerConnectivity "or any other alternative solution that provides reliable communication" | primary | high |
| 7 | WWDC19 Session 604 — Introducing ARKit 3 | https://developer.apple.com/videos/play/wwdc2019/604/ | Continuous map sharing vs ARKit 2 one-time map load; feature-point maps merge into one when overlap found; anchors shared automatically with session IDs | primary | high |
| 8 | WWDC19 Session 605 — Building Apps with RealityKit | https://developer.apple.com/videos/play/wwdc2019/605/ | RealityKit integration: set flag, run config, use synchronized anchor; synchronization service handles networking | primary | high |
| 9 | Apple Docs — ARFrame.worldMappingStatus | https://developer.apple.com/documentation/arkit/arframe/worldmappingstatus-swift.property | States notAvailable/limited/extending/mapped indicate whether session has enough mapped data | primary | high |
| 10 | Apple Docs — Managing session life cycle and tracking quality | https://developer.apple.com/documentation/arkit/managing-session-life-cycle-and-tracking-quality | Relocalization requires the device to revisit areas seen before the map was made; if map can't be reconciled, session stays in .relocalizing indefinitely | primary | high |
| 11 | Apple Docs — Creating a multiuser AR experience | https://developer.apple.com/documentation/arkit/creating_a_multiuser_ar_experience | Host-guest ARWorldMap alternative; best results need thorough sender scan and receiver placed next to sender seeing same view | primary | high |
| 12 | GitHub — MultipeerHelper issue #8 | https://github.com/maxxfrazer/MultipeerHelper/issues/8 | Apple's own collaborative-session sample reported broken on iOS 14 betas; "A peer wants to join…" then "A peer has left" without merging; cross-version device pairs behaved inconsistently | secondary (community-reported) | medium |
| 13 | TRUETECH engineering blog — multi-user AR with Collaborative Session | https://truetech.dev/mobile-apps-development/services/ar/collaborative-ar-shared-experience.html | Real deployment: maps take 10–30 s to merge; CollaborationData ~50–100 KB/s per device (~400 KB/s at 4); MultipeerConnectivity drops peers; WebSocket/GameKit listed as valid transports; "maps didn't merge, objects jumped" pitfalls | secondary (vendor engineering blog) | medium |
| 14 | GitHub — arfoundation-samples issue #486 | https://github.com/Unity-Technologies/arfoundation-samples/issues/486 | Collaboration sample failing: no participant transforms, "CMMapNotAvailable" errors, GCKSession "not in connected state" spam | secondary (community-reported) | medium |
| 15 | Stack Overflow — Collaborative sessions with ARFaceAnchor/ARBodyAnchor | https://stackoverflow.com/questions/74963491/collaborative-sessions-with-arfaceanchor-and-arbodyanchor | Working collaboration over a custom (non-MultipeerConnectivity) transport protocol — confirms transport is app-chosen; only world-tracking config supports the flag | secondary | medium |
| 16 | objc2_ar_kit Rust bindings (mirrors Apple headers) — ARCollaborationDataPriority | https://docs.rs/objc2-ar-kit/latest/aarch64-apple-ios-macabi/objc2_ar_kit/struct.ARCollaborationDataPriority.html | .critical = important for establishing/continuing session, send reliably; .optional = time-sensitive, can be lost | secondary (header mirror) | high |
| 17 | Unity AR Foundation docs — Collaboration data sample | https://docs.unity.cn/Packages/com.unity.xr.arfoundation@6.5/manual/samples/arkit/collaboration-data.html | Critical data periodic (send reliably); Optional data nearly every frame (device location); planes/trackables not shared | secondary | high |
| 18 | Apple Forums — addedlayer profile (RealityKit collaborative session thread) | https://developer.apple.com/forums/profile/addedlayer | "[GCKSession] Not in connected state, so giving up for participant" — devices connect but RealityKit sync fails | secondary (community-reported) | low–medium |
| 19 | WWDCNotes — WWDC19-610 community notes | https://wwdcnotes.com/documentation/wwdc19-610-building-collaborative-ar-experiences/ | Point-cloud overlap is the merge trigger; ARAnchors auto-translate between devices; keep content near anchors | secondary | medium |

---

## Q1 — What does `isCollaborationEnabled` do; what data is emitted; what does `update(with:)` do?

**Documented facts**

- `isCollaborationEnabled` is a flag on `ARWorldTrackingConfiguration` only ("Collaboration is supported for world tracking configurations only" [4]); default `false`. Enabling it makes ARKit invoke `session(_:didOutputCollaborationData:)` **periodically** [1][2].
- Emitted `CollaborationData` contains: "information about the real-world surfaces ARKit detects, your position in relation to them, and any anchors you may have created" [2]. It is a serialized chunk of the device's `ARWorldMap` — Apple describes it as "a piece of your ARWorldMap information" pushed to other users and stored by them as "external maps" [6].
- Each instance carries a `priority` hint [3]: `.critical` = "important for establishing or continuing a collaborative session" — must be sent **reliably**; `.optional` = time-sensitive, loss-tolerant [16]. Unity's wrapper docs quantify this: critical data arrives periodically; optional data arrives "nearly every frame" and carries the device location [17].
- Send path: archive with `NSKeyedArchiver` (`requiringSecureCoding: true`) and transmit with the app's own networking [1]. Base64 wrapping on top (as in the app under research) is an app-level choice — nothing in the API requires or forbids it; it only inflates payload size ~33%.
- Receive path: `NSKeyedUnarchiver.unarchivedObject(ofClass: ARSession.CollaborationData.self, from:)` then `session.update(with:)` [2]. `update(with:)` hands the peer's environment data to the local session, which stores it as an external map and attempts localization against it [4][6].
- **Retransmission duty is on the app**: "If your networking solution replies a failure to transmit this data, then it is your app's responsibility to transmit this data again to make sure the data is delivered" [6].
- It's safe to drop outgoing data when no peers exist — ARKit re-emits later. But enabling collaboration only after peers join "is not supported, because doing so restarts the session" — the flag must be set before `session.run` [1].
- What is shared: user-created `ARAnchor`s (with originating `sessionIdentifier`), the participant pose, and world-map features. Subclassed anchors (ARImageAnchor, ARPlaneAnchor, ARObjectAnchor, custom ARAnchor subclasses) and detected planes/trackables are NOT shared [6][17].

## Q2 — Documented requirements for a successful merge

1. **Visual overlap is the hard requirement.** "For ARKit to know where two users are with respect to each other, it has to recognize overlap across their respective world maps… a user must point their device near an area that another user has viewed. The sample app accomplishes this by asking the users to hold their devices side by side" [1].
2. **Camera perspective matters.** WWDC 610's practical advice: two users viewing the same table "in cross direction… it's not likely for ARKit to localize." Users standing "side-by-side and looking at the same direction" makes localization "more likely" [6].
3. **Mapping quality matters.** Apple's second recommendation: keep one user in `ARFrame.WorldMappingStatus.mapped` so they are actually seeing the 3D landmarks stored in the shared map when the other user approaches [6][9].
4. **OS version parity is recommended, not required.** "For optimum performance, it's helpful if the participants in a collaborative session are on the same OS version. Unarchiving ARSession.CollaborationData received from a device running a different OS version may fail" [2]. Failure mode is a silent unarchive failure → data never reaches `update(with:)`.
5. **No host, no ordering role.** Decentralized design; "each user can start their own AR experiences before they start receiving each other" [6].
6. **Transport-agnostic.** MultipeerConnectivity "or any other alternative solution that provides reliable communication" [6]; community sources confirm WebSocket transports work [13][15]. There is no documented requirement that devices share a LAN — but the transport must actually deliver critical data.
7. **Merge is not instantaneous.** Apple gives no timing guarantee; a vendor deployment reports 10–30 s to merge [13]. The same physical-view requirement as map relocalization applies: a session whose map can't be reconciled with the environment "remains in the relocalizing state indefinitely" [10] — the closest documented analogue to the reported "constantly re-aligning" symptom.

## Q3 — Why merges fail in practice (documented + community-reported)

Documented causes:

- **No shared visual features** — the dominant documented cause. Players spread around a room, facing inward at each other, or each facing a different wall produce non-overlapping point clouds; cross-direction views of even the same surface are called out by Apple as unlikely to localize [1][6].
- **No device ever reaches `.mapped`** — poor lighting, featureless/blank surfaces, or insufficient device motion keep `worldMappingStatus` at `.limited`/`.notAvailable`, so there are no stable 3D landmarks to match [6][9].
- **Unarchive failure across OS versions** — data arrives but `NSKeyedUnarchiver` returns nil; if the app doesn't log this branch it looks exactly like "data exchanged but never merges" [2].
- **Critical data lost in transit** — critical CollaborationData requires reliable delivery and the app owns retransmission [6][16]. A WebSocket room that drops oversized messages, sends while the socket is reconnecting, or silently discards failures will starve peers of map data. (Inference, grounded in [6][16]: with base64-wrapped payloads and ~50–100 KB/s per device reported [13], server message-size limits are a concrete check.)
- **Echo-back to sender** — not addressed in Apple docs (unresolved), but a relay that returns a device's own CollaborationData is outside Apple's tested pattern.

Community-reported failures:

- Apple's own collaborative sample reported broken on iOS 14 betas: peers connect, "hold phones next to each other" shows, then "peer has left" — never merges; behavior differed by iOS version pairing [12].
- RealityKit/Unity collaboration failures with `[GCKSession] Not in connected state` and `CMMapNotAvailable` errors — session-layer sync failing despite connectivity [14][18].
- "MultipeerConnectivity periodically lost connection, maps didn't merge, and objects jumped" in a production deployment; merge took 10–30 s even when working [13].
- Working collaboration over a custom non-MultipeerConnectivity protocol [15] — confirms transport is not the constraint; map overlap is.

## Q4 — Is there a "first exchange" bootstrap problem?

**No handshake ordering is required.** The design is decentralized: devices may start sessions and begin emitting data before peers exist; data emitted with no peers is safely dropped and ARKit re-emits later [1][6]. A late-joining device can still merge because the map data it missed is resent.

**But there IS a spatial bootstrap requirement**: exchanging data alone never merges anything. Receiving CollaborationData only gives a device an "external map"; merge happens only when that device's camera later sees an area the sender saw [1][6]. So the effective bootstrap is: (a) exchange at least one round of critical map data, AND (b) give both devices a co-viewed physical region. Without (b), the system waits indefinitely — consistent with "constantly re-aligning."

**One ordering constraint exists**: `isCollaborationEnabled` must be set before the session runs; toggling it after peers join restarts the session [1]. (The app under research already does this correctly.)

## Q5 — What the WWDC sessions demonstrate and recommend

- **WWDC19-610 (the authoritative session)** [6]: demonstrates two users each mapping a room, placing anchors, then merging once they view common area. Recommends: (1) bring users to the same camera perspective — side-by-side, same direction; (2) keep one user at `.mapped` status during join; (3) use ARAnchors for all shared content (they translate between coordinate systems automatically); (4) treat ARParticipantAnchor as the merge signal; (5) retransmit failed sends; (6) note each device keeps its own world coordinate origin even after merge — anchors, not raw transforms, are the shared truth.
- **WWDC19-604** [7]: shows internal point-cloud maps (red/green per device) merging into one map only after feature overlap; positions collaboration as continuous sharing vs ARKit 2's one-time map handoff; RealityKit path = MultipeerConnectivity session + `synchronizationService` + flag.
- **WWDC19-605** [8]: RealityKit game walkthrough — flag on, run, then a "synchronized anchor" for shared content; entity synchronization components handle game state on top.
- Apple's shipped demo game is SwiftStrike (RealityKit); the ARKit-only sample app is "Creating a collaborative session" which onboards users with "Hold the phones next to each other" [1].

## Synthesis for the alignment architecture decision

1. The mechanism the app implements (flag → archive → relay → `update(with:)` → ARParticipantAnchor) is the documented, correct pipeline, and WebSocket relay is a legitimate transport [6][13][15]. The architecture is not inherently wrong.
2. The failure is almost certainly **spatial, not networking**: ARKit collaboration is a *visual-map-merging* system, not a coordinate-negotiation protocol. If the four devices never co-view a textured region (or never reach `.mapped`), no amount of CollaborationData will merge them — matching the reported symptom [1][6][10].
3. Cheap instrumentation before redesigning: log (a) `worldMappingStatus` per device, (b) unarchive failures on receipt (would reveal OS-mismatch drops [2]), (c) CollaborationData sizes/priority vs. WebSocket delivery success (would reveal lost critical data [6][16]), (d) whether the relay echoes a device's own data back to it.
4. If the game design has players facing different directions, add an explicit "calibration huddle" (all devices pointed at the same surface) — Apple itself onboards this way [1][6] — or use a deterministic bootstrap: host `ARWorldMap` handoff + relocalization [11], or a shared detected image/object anchor as the common reference (would require an ADR-level design change since visible markers are currently excluded).

## Coverage Status

- Checked directly: Apple docs pages (via mirror of developer.apple.com text) for `isCollaborationEnabled`, `CollaborationData`, `update(with:)`, `ARParticipantAnchor`, `worldMappingStatus`, both sample-article pages; WWDC 2019 transcripts for 610, 604, 605; community failure reports on GitHub/Unity/SO/forums.
- Uncertain: whether echoing a device's own CollaborationData back to its session is harmful (undocumented); whether specific iOS 17/18 releases have collaboration regressions (iOS 14 beta breakage is community-reported [12], not officially acknowledged); exact CollaborationData cadence/sizes (Apple doesn't quantify; [13][17] are third-party numbers).
- Not found: an Apple forums thread exactly matching "ARParticipantAnchor never appears over WebSocket" — no source claims WebSocket transport itself is the problem.

## Sources

1. Apple — Creating a collaborative session — https://developer.apple.com/documentation/arkit/creating_a_collaborative_session (content via https://apple-docs.everest.mt/docs/arkit/creating-a-collaborative-session/)
2. Apple — isCollaborationEnabled — https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/iscollaborationenabled
3. Apple — ARSession.CollaborationData — https://developer.apple.com/documentation/arkit/arsession/collaborationdata
4. Apple — ARSession.update(with:) — https://developer.apple.com/documentation/arkit/arsession/update(with:) (mirror: https://apple-docs.everest.mt/docs/arkit/arsession/update(with:)/)
5. Apple — ARParticipantAnchor — https://developer.apple.com/documentation/arkit/arparticipantanchor
6. Apple — WWDC19 Session 610, Building Collaborative AR Experiences — https://developer.apple.com/videos/play/wwdc2019/610/
7. Apple — WWDC19 Session 604, Introducing ARKit 3 — https://developer.apple.com/videos/play/wwdc2019/604/
8. Apple — WWDC19 Session 605, Building Apps with RealityKit — https://developer.apple.com/videos/play/wwdc2019/605/
9. Apple — ARFrame.worldMappingStatus — https://developer.apple.com/documentation/arkit/arframe/worldmappingstatus-swift.property
10. Apple — Managing Session Life Cycle and Tracking Quality — https://developer.apple.com/documentation/arkit/managing-session-life-cycle-and-tracking-quality (mirror: https://apple-docs.everest.mt/docs/arkit/managing-session-life-cycle-and-tracking-quality/)
11. Apple — Creating a multiuser AR experience — https://developer.apple.com/documentation/arkit/creating_a_multiuser_ar_experience (mirror: https://apple-docs.everest.mt/docs/arkit/creating-a-multiuser-ar-experience/)
12. MultipeerHelper issue #8, "Example project not working" — https://github.com/maxxfrazer/MultipeerHelper/issues/8
13. TRUETECH — Building Multi-User AR on iOS with Collaborative Session — https://truetech.dev/mobile-apps-development/services/ar/collaborative-ar-shared-experience.html
14. Unity arfoundation-samples issue #486 — https://github.com/Unity-Technologies/arfoundation-samples/issues/486
15. Stack Overflow — Collaborative sessions with ARFaceAnchor and ARBodyAnchor — https://stackoverflow.com/questions/74963491/collaborative-sessions-with-arfaceanchor-and-arbodyanchor
16. objc2_ar_kit docs — ARCollaborationDataPriority (mirrors Apple header doc comments) — https://docs.rs/objc2-ar-kit/latest/aarch64-apple-ios-macabi/objc2_ar_kit/struct.ARCollaborationDataPriority.html
17. Unity AR Foundation manual — Collaboration data sample — https://docs.unity.cn/Packages/com.unity.xr.arfoundation@6.5/manual/samples/arkit/collaboration-data.html
18. Apple Developer Forums — addedlayer profile (RealityKit Collaborative Session thread) — https://developer.apple.com/forums/profile/addedlayer
19. WWDCNotes — WWDC19-610 Building Collaborative AR Experiences — https://wwdcnotes.com/documentation/wwdc19-610-building-collaborative-ar-experiences/
20. Medium (Grant Jarvis) — Multiplayer AR with RealityKit: What Went Wrong — https://realitydev.medium.com/multiplayer-ar-with-realitykit-what-went-wrong-36e8f90f8b70
