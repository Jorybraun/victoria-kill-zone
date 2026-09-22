# Markerless Multiplayer AR — Architecture Verdict & Fix Plan

**Date:** 2026-09-17 · **Trigger:** physical two-phone trial of collaborative
Quick Play reported "room scanning definitely not working."

## Executive summary

The collaborative-sessions architecture is **correct and should be kept** — it
is Apple's documented mechanism, the only option that continuously corrects
drift, and the transport (WebSocket relay) is a legitimate choice [1][6][13].
The on-device failure is almost certainly **spatial, not networking**: ARKit
merges maps only when devices visually co-view the same region, and Apple's own
onboarding for this feature is "hold the phones side by side" [1][6]. Our UX
("Move toward the play area") never asked players to do that.

Evidence-backed fix: keep collab as the continuous layer and add a deterministic
bootstrap ritual — explicit "everyone point at the same spot/object" guidance
(Pokémon GO does exactly this [24]) — plus the engineering fixes already shipped
for silent delta loss. A transient host-screen image marker is the stronger
fallback if the ritual still fails on bad rooms [11].

## Q1 — Is the architecture sound?

Yes. `isCollaborationEnabled` → `NSKeyedArchiver` → relay → `update(with:)` →
`ARParticipantAnchor` is exactly the documented pipeline [1][2][3][4][5].
CollaborationData carries world-map chunks + device position + user anchors; it
has a `priority` hint — `.critical` must be delivered reliably (app owns
retransmission), `.optional` is per-frame and loss-tolerant [3][16][17].
Transport is app-chosen; WebSocket rooms are used by working deployments
[6][13][15]. Code audit: our implementation matches the model — flag set before
`run`, ordered apply, no echo-back (worker sends `other !== connection`),
386 KB message cap vs ~50–100 KB/s real-world traffic [13].

## Q2 — Why did the merge fail on device?

Ranked hypotheses, per evidence:

1. **No shared visual features (dominant).** Merge requires map overlap: "a
   user must point their device near an area that another user has viewed"
   [1]. WWDC 610 warns cross-direction views of the same surface are unlikely
   to localize and recommends side-by-side, same-direction viewing plus one
   device at `.mapped` status [6]. Players facing different directions or
   different walls produce disjoint point clouds — the system waits
   indefinitely, matching "constantly re-aligning" [1][6][10].
2. **Poor mapping status.** Featureless/dim rooms keep `worldMappingStatus`
   below `.mapped` — no stable landmarks to match [6][9].
3. **Lost critical deltas (fixed).** Pre-connect sends were silently dropped
   client-side; inbound bursts could drop queued deltas. Fixed in PR #104
   (bounded FIFO backlog + unbounded inbound). Worker budget (256 KB/s) can
   also shed under sustained 4-player load — watch `collab outbound dropped`
   in the combat log.
4. **iOS version mismatch.** Unarchiving CollaborationData across OS versions
   can fail silently [2] — our `apply-failed` log line covers this; check it.

## Q3 — What do shipped products do?

Nobody ships world-map share+relocalize for live play [R2]. The field splits:

- **SLAM-overlap merge** — Apple SwiftStrike (collab + Multipeer) [4];
  Pokémon GO shared AR: all players sweep phones around the *same physical
  object* until maps merge [24][25]. Same mechanism as ours — with an explicit
  co-view ritual we don't have.
- **Marker/anchor reference** — HADO (court-side printed patterns) [26],
  HoloKit (printed or host-screen image marker; fuses consecutive detections)
  [10][11], XRoom (multiple QRs — single anchor caused rescans) [28], Quest
  Shared Spatial Anchors [31], Niantic same-room mode (image tracking) [13].
- **Hybrid is the dominant production answer:** deterministic bootstrap +
  continuous correction [10][11][26][28].

Lightship is Unity-only/marker-based — dependency conflict [19]. Cloud Anchors
adds a Google dependency for no local benefit [33]. ARWorldMap share is
confirmed-fragile — do not revive [1][4].

## Q4 — Report/diagnostics gaps (R3)

The pipeline matches industry patterns; top additions by value/effort [R3]:

1. **MetricKit** (~50 lines): crash call-stacks, hangs, CPU/disk exceptions
   forwarded through the worker — covers failures our own logging can't see
   [11m][12m][13m].
2. **Voice audio upload + Workers AI Whisper fallback** — on-device Speech
   fails with *empty transcripts*, not errors [21m-26m]; whisper-turbo costs
   ~$0.0005/min [27m].
3. **matchId-keyed server event log** — authoritative event trail linked from
   each report [18m-20m].
4. Screenshot now; ReplayKit rolling clip later (iOS 27 deprecation caveat)
   [29m].
5. Defer Sentry/Crashlytics — MetricKit + persisted logs cover the beta need
   [14m-17m].

## Decision

**Keep collaborative sessions.** The fix is not a new architecture — it's the
missing bootstrap UX plus the delta-loss fixes already shipped:

1. **Shipped:** PR #103 (record/send on device), PR #104 (delta backlog +
   ordered apply).
2. **Next (design + code):** change the aligning-stage guidance to a co-view
   ritual — "Everyone point at the same spot" — and gate "aligned" display on
   `peers≥1` as it already does. Optionally add a huddle hint after ~10 s with
   no merge ("stand side by side, look at the same object") [1][6][24].
3. **If rituals still fail:** transient host-screen image marker (HoloKit's
   anywhere-variant — native `detectionImages`, no printout) as bootstrap, with
   collab kept for drift [11]. Requires ADR since visible markers are excluded.
4. **Verification:** export setup logs from both phones after the next trial —
   `collab emitted/applied` counters + `peers=N` + `tracking ... mapped=` will
   confirm which hypothesis held.
5. **Follow-ups (R3):** MetricKit, audio upload + Whisper fallback, match event
   log.

## Sources

R1 sources (Apple docs/WWDC/community):
1. https://developer.apple.com/documentation/arkit/creating_a_collaborative_session
2. https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/iscollaborationenabled
3. https://developer.apple.com/documentation/arkit/arsession/collaborationdata
4. https://developer.apple.com/documentation/arkit/arsession/update(with:)
5. https://developer.apple.com/documentation/arkit/arparticipantanchor
6. https://developer.apple.com/videos/play/wwdc2019/610/
7. https://developer.apple.com/videos/play/wwdc2019/604/
8. https://developer.apple.com/videos/play/wwdc2019/605/
9. https://developer.apple.com/documentation/arkit/arframe/worldmappingstatus-swift.property
10. https://developer.apple.com/documentation/arkit/managing-session-life-cycle-and-tracking-quality
11. https://developer.apple.com/documentation/arkit/creating_a_multiuser_ar_experience
12. https://github.com/maxxfrazer/MultipeerHelper/issues/8
13. https://truetech.dev/mobile-apps-development/services/ar/collaborative-ar-shared-experience.html
14. https://github.com/Unity-Technologies/arfoundation-samples/issues/486
15. https://stackoverflow.com/questions/74963491/collaborative-sessions-with-arfaceanchor-and-arbodyanchor
16. https://docs.rs/objc2-ar-kit/latest/aarch64-apple-ios-macabi/objc2_ar_kit/struct.ARCollaborationDataPriority.html
17. https://docs.unity.cn/Packages/com.unity.xr.arfoundation@6.5/manual/samples/arkit/collaboration-data.html

R2 sources (products/alternatives) — see outputs/.drafts/markerless-multiplayer-ar-R2.md
for the full 38-source list; key: HoloKit boilerplate [11], Pokémon GO shared AR
[24][25], HADO [26], XRoom postmortem [28], Meta Shared Spatial Anchors [31].

R3 sources (report pipelines) — see outputs/.drafts/markerless-multiplayer-ar-R3.md
for the full 32-source list; key: MetricKit [11m-13m], Speech limits [21m-26m],
Workers AI Whisper [27m], ReplayKit [29m].
