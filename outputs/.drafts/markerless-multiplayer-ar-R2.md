# R2: Co-located Multiplayer AR Alignment Architectures — Evidence Review

**Question:** How do shipped multiplayer AR products align multiple phones into a shared coordinate frame in the same physical room? Evaluated for a native iOS game (Swift/SwiftUI + ARKit, ≤4 players, same room, markerless preferred).

**Status:** done (all 5 assigned sub-questions covered; see Coverage Status at bottom).

---

## Evidence Table

| # | Source | URL | Key claim | Type | Confidence |
|---|--------|-----|-----------|------|------------|
| 1 | Apple — "Creating a multiuser AR experience" (archived sample) | https://developer.apple.com/documentation/arkit/creating-a-multiuser-ar-experience | Host captures ARWorldMap → NSKeyedArchiver → MultipeerConnectivity → peer runs session with `initialWorldMap`; receiver must be "in an area that the first device visited... or has a similar view" | primary (official docs) | high |
| 2 | Apple — ARWorldMap | https://developer.apple.com/documentation/arkit/arworldmap | World map = snapshot of spatial mapping state; receiving device unarchives and runs new session with `initialWorldMap` | primary | high |
| 3 | Apple — "Creating a collaborative session" | https://developer.apple.com/documentation/arkit/creating-a-collaborative-session | `isCollaborationEnabled` → periodic CollaborationData the app must transport; ARKit merges maps only after devices view overlapping area — sample "asks the users to hold their devices side by side"; merge event surfaces `ARParticipantAnchor` | primary | high |
| 4 | Apple — WWDC19 Session 610, "Building Collaborative AR Experiences" | https://developer.apple.com/videos/play/wwdc2019/610/ | Collaboration is decentralized P2P, designed for live multiuser AR; works "with or without the map"; only user-created `ARAnchor`s sync — subclassed anchors (ARImageAnchor, ARPlaneAnchor, custom subclasses) are NOT shared; SwiftStrike used MPC + collaborative session | primary | high |
| 5 | Apple — "Detecting Images in an AR Experience" | https://developer.apple.com/documentation/arkit/detecting-images-in-an-ar-experience | `detectionImages` in a world-tracking config yields `ARImageAnchor` with real-world pose — the native mechanism for a known-image shared origin | primary | high |
| 6 | Apple Developer Forums — "ARKit device interoperability question" | https://developer.apple.com/forums/thread/726044 | World map created on iPad Pro 2nd gen never relocalized on 4th gen — reports possible cross-device-model incompatibility (unresolved) | self-reported | medium |
| 7 | Apple Developer Forums — "ARWorld loading works differently on iOS 14 and 15" | https://developer.apple.com/forums/thread/690668 | iOS 15 changed post-relocalization origin behavior vs iOS 14; workaround = restore via a saved ARAnchor / `setWorldOrigin` | self-reported | medium |
| 8 | Unity Discussions — "Collaborative Sessions limited to two devices?" | https://discussions.unity.com/t/collaborative-sessions-limited-to-two-devices/748035/1 | 2019 report: AR Foundation collaboration sample worked with 2 devices only; user wrote own networking for >2 (likely a sample/ARFoundation limitation, not a documented ARKit cap — inference) | self-reported | medium |
| 9 | Stack Overflow — "RealityKit Custom ARAnchor not syncing across devices" | https://stackoverflow.com/questions/64304557/realitykit-custom-aranchor-not-syncing-across-devices | Confirms in practice: subclassed/custom ARAnchors do not propagate through collaboration data | secondary | medium |
| 10 | HoloKit Docs — "Tutorial 5: Multiplayer AR" | https://docs.holokit.io/creators/tutorials/tutorial-5-multiplayer-ar | Engineering taxonomy: cold-start (SLAM) vs absolute-coordinate (pre-scan) sync; ARKit collab merge needs 3–15 s patient scanning of same area; marker relocalization faster but single-point → drift; shipped game "MOFA" uses Netcode + MultipeerConnectivity + external marker | primary (engineering docs) | high |
| 11 | HoloKit — holokit-colocated-multiplayer-boilerplate (README) | https://github.com/holokit/holokit-colocated-multiplayer-boilerplate | Three iOS boilerplates: external marker, dynamically-rendered-on-host-screen marker, Immersal map; improves marker accuracy by fusing multiple consecutive detected poses before resetting origin; recommends external marker for >3 devices | primary (code) | high |
| 12 | Grow (agency) — "Bring Multiplayer AR Alive with Interactive Physics" | https://thisisgrow.com/insights/bring-multiplayer-ar-alive-with-interactive-physics | Shipped experiment: multiplayer AR basketball used a printed wall marker as shared coordinate anchor + MultipeerConnectivity for state | secondary (engineering blog) | medium |
| 13 | Niantic Spatial — NSDK Sample Projects | https://www.nianticspatial.com/docs/nsdk/3.17.0/sample_projects/ | Shared AR samples ship in exactly two flavors: VPS colocalization (Wayspot) and Image Tracking colocalization (printed image ~9 cm wide as shared origin); requires Lightship API key | primary | high |
| 14 | Niantic Spatial — SharedSpaceManager API ref | https://www.nianticspatial.com/docs/nsdk/3.17.0/apiref/Niantic/Lightship/SharedAR/Colocalization/SharedSpaceManager/ | `ColocalizationType` enum = VpsColocalization, ImageTrackingColocalization, MockColocalization — no markerless/environment option | primary | high |
| 15 | Niantic Spatial — ISharedSpaceTrackingOptions API ref | https://www.nianticspatial.com/docs/nsdk/3.17.0/apiref/Niantic/Lightship/SharedAR/Colocalization/ISharedSpaceTrackingOptions/ | Tracking options creatable only from VPS payload/ARLocation or a target image + physical width | primary | high |
| 16 | Niantic Spatial — Lightship VPS feature doc | https://www.nianticspatial.com/docs/nsdk/features/lightship_vps/ | VPS is cloud-based; map built from user scans; location becomes "VPS-Activated" after enough scans; localization = point device at the real-world location | primary | high |
| 17 | Niantic Spatial — "Create a Public Location" criteria | https://nianticspatial.com/docs/nsdk/how-to/vps/tooling/create_vps_activated_location/ | VPS locations must be permanent, publicly accessible (indoor OR outdoor), focal point ≤10 m; moveable furniture areas "will not work well" | primary | high |
| 18 | Niantic community (staff reply) — "Shared location with Peer Pose" | https://community.nianticspatial.com/t/shared-location-with-peer-pose/4980 | Staff (Dec 2024): "the only methods available for Shared AR co location are VPS and Image tracking" — the old peer-shared-geometry approach was removed | primary (vendor forum) | high |
| 19 | Niantic community (staff reply) — "VPS Pricing Model and Costs" | https://community.nianticspatial.com/t/vps-pricing-model-and-costs/4294 | Jan 2024 staff: all Lightship services free <50,000 MAU | primary (vendor forum) | medium |
| 20 | Niantic community — "Pricing changes of Lightship" | https://community.nianticspatial.com/t/pricing-changes-of-lightship/5134 | Later pricing reports: ~$0.8–1 per MAU above a low free threshold (~100–5,000 MAU depending on era); devs with free/ad-supported games called it unaffordable; pricing in flux | secondary (community + staff) | medium |
| 21 | Niantic community — "Embedding Lightship in native iOS/Android apps" | https://community.nianticspatial.com/t/embedding-lightship-in-native-ios-android-apps/2486 | ARDK runs inside Unity; embedding via Unity-as-a-Library on iOS crashes/isn't officially supported | primary (vendor forum) | high |
| 22 | Niantic Spatial — SDK setup doc | https://www.nianticspatial.com/docs/nsdk/3.17.0/setup/ | NSDK requires Unity Hub + Unity LTS (6000.0.58f2 / 2022.3.62f2 at time of doc); no native Swift path | primary | high |
| 23 | Niantic Spatial — pricing page | https://www.nianticspatial.com/pricing | Current public pricing is Scaniverse-plan oriented (free/$20/$50 tiers, credits); SDK MAU pricing requires contacting sales past thresholds | primary | medium |
| 24 | Pokémon GO Hub — "How to AR: Group/Shared AR" | https://pokemongohub.net/post/ar/how-to-ar-group-shared-ar/ | Shipped PoGO Group AR: QR code joins lobby (not spatial alignment); alignment = all players "point towards the same 3D object in a flat, open area" and sweep side-to-side until sync checkmark; buggy in flat/featureless areas | secondary (fan site quoting Niantic guidance) | medium |
| 25 | Gamepur — "Shared AR Experience with friends in Pokémon Go" | https://www.gamepur.com/guides/how-to-use-shared-ar-experience-with-friends-in-pokemon-go | Corroborates: 3 players max, all walk left/right around a single object in ~180° arc to sync | secondary | medium |
| 26 | JapanGov — "A New AR Sport from Japan" (HADO/meleap) | https://www.japan.go.jp/topics/2026/07/new_ar_sport.html | Shipped AR sport (since 2016): "patterns that serve as positional reference markers decorate the walls"; headset cameras track position/facing in real time from the markers | primary (gov't feature) | high |
| 27 | HADO — "How the technology works" | https://www.hadoarsports.com/how-the-technology-works | Venue-grade: players wear iPhone headsets + wrist iPhones; banner sensors + external camera + manual calibration map the court; game server projects play onto the court | primary (vendor) | high |
| 28 | Feiyan Zhang — XRoom "Disco Arena" postmortem | https://www.feiyanzhang.com/xroom-ar-multiplayer-game | Room-scale co-located phone AR game: single QR anchor caused frequent tracking loss & rescans; fix = multiple QR anchors placed around the space | self-reported (designer postmortem) | medium |
| 29 | dmnshd.gg — "Shared Spaces in WebXR" | https://dmnshd.gg/blog/webxr-shared-spaces | Shipped WebXR games: once a shared reference space exists, the leader broadcasts ONE coordinate (track origin) — a single point is sufficient when underlying tracking shares a frame | primary (engineering blog) | medium |
| 30 | Meta — "Colocation tips, tricks, and FAQ" | https://developers.meta.com/horizon/documentation/unity/unity-colocation-tips-tricks-faq/ | Shared Spatial Anchors: anchors drift when device is >3 m from anchor; colocation needs unique visual cues in the playspace | primary (vendor docs) | high |
| 31 | Meta — "Colocation sample with Photon Fusion" | https://developers.meta.com/horizon/documentation/unity/unity-sample-colocation-fusion/ | Quest colocation lifecycle: Create → Save to Cloud → Share → Localize → Align (align = transform camera tracking space to shared anchor) | primary (vendor docs) | high |
| 32 | lawtancool/Cooked (GitHub) | https://github.com/lawtancool/Cooked | Shipped co-located Quest cooking game: Bluetooth local matchmaking + Shared Spatial Anchors + Photon Fusion | primary (code) | medium |
| 33 | Google — "Cloud Anchors developer guide for iOS" | https://developers.google.com/ar/develop/ios/cloud-anchors/developer-guide | ARCore SDK for iOS wraps ARKit: host() uploads visual data → Cloud Anchor ID; resolve() on peer devices returns anchor pose in local coordinates | primary | high |
| 34 | Google — Cloud Anchors overview | https://developers.google.com/ar/develop/cloud-anchors | TTL up to 365 days; designed for shared experiences incl. real-time collaborative | primary | high |
| 35 | Google — "ARCore 1.33 Cloud Anchor endpoint changes" | https://developers.google.com/ar/develop/cloud-anchors/endpoint-changes | Old Cloud Anchor API endpoint deprecated Aug 2022 → general ARCore API; service still operates (1-year deprecation-notice policy) | primary | high |
| 36 | MDPI Sensors 2025 — "AprilTags in Unity: A Local Alternative to Shared Spatial Anchors" | https://www.mdpi.com/1424-8220/25/14/4408 | Peer-reviewed: AprilTag calibration gives accurate multi-user sync as a fully local (no-cloud) alternative to spatial anchors | primary (academic) | high |
| 37 | Niantic Spatial — "Getting Started with VPS" | https://www.nianticspatial.com/docs/ardk/how-to/vps/adding_vps/ | VPS "Continuous Localization" mode keeps sending localization requests after initial lock specifically "to mitigate drift," with interpolation + temporal fusion options | primary | high |
| 38 | Niantic — Codename: Neon demo video | https://www.youtube.com/watch?v=dO1NpT2SSX4 | Niantic's 2018 cross-platform low-latency multiplayer AR demo (marketing video; no technical detail) | self-reported | low |

---

## Findings

### Option 1 — Niantic Lightship ARDK / Niantic Spatial SDK (NSDK)

**How Shared AR colocalization works.** NSDK's `SharedSpaceManager` supports exactly three colocalization types: `VpsColocalization`, `ImageTrackingColocalization`, and `MockColocalization` [14][15]. Niantic staff confirmed in Dec 2024 that "the only methods available for Shared AR co location are VPS and Image tracking" — the older peer-shared-geometry colocalization was removed [18]. In both modes, all devices that successfully track the same target join a networked "Room" whose root (`SharedAROrigin`) is anchored to the tracking target; Unity Netcode then keeps objects under that root synchronized [13][14].

- **VPS colocalization:** requires a VPS-Activated location. Locations are built from user scans; eligibility requires a permanent, publicly accessible place (indoor or outdoor allowed) with a focal point ≤10 m, and Niantic explicitly warns that areas with "moveable furniture will not work well" [16][17]. For an arbitrary living room you would need to scan and activate your own private location first — a heavy bootstrap for casual same-room play. VPS also offers "Continuous Localization," which keeps polling the cloud to correct drift [37].
- **Image-tracking colocalization:** the shipped same-room answer — all players point their cameras at the same printed reference image (the sample prints it 9 cm wide on a surface), which becomes the shared origin [13]. This is, in effect, Niantic's own endorsement of the marker-bootstrap pattern.

**Cost/dependency implications for a small indie native-iOS game:**
- **Unity is mandatory.** NSDK only supports Unity LTS [22]; Unity-as-a-Library embedding into a native Swift app is not officially supported and community reports describe crashes and unsupported workarounds [21]. Adopting Lightship means rebuilding the game in Unity — and per repo AGENTS.md, Unity is on the prohibited-dependency list.
- **Requires a Lightship API key** even for samples [13]; networked rooms run through Lightship's hosted service, adding a vendor dependency for a purely-local experience.
- **Pricing is unsettled.** Staff said (Jan 2024) services are free under 50,000 MAU [19], but later community threads report roughly $0.8–1 per MAU above a small free tier and describe pricing as actively changing; indie devs flagged it as unaffordable for free/ad-supported games [20]. The public pricing page now focuses on Scaniverse plans; SDK pricing past free thresholds is "contact us" [23]. **Confidence: medium — pricing must be re-verified at adoption time.**

**Verdict:** architecturally sound but a poor fit — Unity dependency and hosted-room requirement outweigh benefits for a 4-player native game. Its image-tracking mode does, however, validate the marker-bootstrap pattern (Option 4) [13][18].

### Option 2 — Apple ARWorldMap share + relocalize (the previous approach)

Apple's documented host-guest pattern: host calls `getCurrentWorldMap`, serializes via `NSKeyedArchiver`, sends over any transport (the sample uses MultipeerConnectivity); peers unarchive and `run` a new session with `initialWorldMap` [1][2]. Known reliability characteristics from the sources:

- The receiving device must already be "in an area that the first device visited... or has a similar view of the surrounding environment" — relocalization is visual feature matching against the frozen snapshot [1].
- Apple frames this feature as designed for **persistent AR** (save/resume later); WWDC19 explicitly positions collaborative sessions, not world maps, as the live-multiuser mechanism [4].
- Developer-forum evidence of fragility: a world map captured on one iPad model reportedly never relocalized on a different model (unresolved) [6]; iOS 15 silently changed post-relocalization origin behavior vs iOS 14, breaking apps that relied on the old behavior [7].
- The map is a point-in-time snapshot — nothing updates it after capture, so features that moved between capture and relocalization degrade or break matching. This matches the user's observed failure mode; the sources confirm it is inherent to the design, not a misuse [1][2][4].

**Verdict:** Apple still documents it, but it is the persistence mechanism being repurposed; every source points to collaboration or markers as the live-multiplayer answer [4][10].

### Option 3 — ARKit Collaborative Sessions (the current approach)

Mechanics per Apple: set `isCollaborationEnabled` on `ARWorldTrackingConfiguration`; the session periodically emits `CollaborationData` that **the app** must serialize and transport (any transport works — WebSocket is fine); ARKit stores peers' data as "external maps" and merges when a device views area another peer has already mapped [3][4]. The merge surfaces an `ARParticipantAnchor` per peer [3].

Key characteristics from sources:

- **Bootstrap is the weak point.** Merging requires visual overlap between maps; Apple's own sample instructs users to "hold their devices side by side" to aid the merge [3]. HoloKit's engineering writeup reports the scan-the-same-area process takes **3–15 seconds**, demands "both skill and patience," and calls the UX confusing [10].
- **Only user-created `ARAnchor`s sync** — subclassed anchors (`ARImageAnchor`, `ARPlaneAnchor`, custom subclasses) are excluded from collaboration data [4][9]. So you cannot smuggle a shared image anchor through the collaboration channel; a marker bootstrap would have to be wired manually (e.g., each device detects the same image locally and computes its own transform).
- **Version fragility:** unarchiving `CollaborationData` from a device on a different OS version can fail [3].
- **Peer count:** Apple's docs say "two or more devices" and specify no cap [3]; a 2019 AR Foundation report hit a 2-device limit in Unity's sample implementation (likely a sample limitation, not an ARKit cap — inference) [8]. For 4 players this wants physical-device verification.
- **Ongoing correctness is its strength:** because map data keeps flowing for the whole session, all devices keep benefiting from each other's mapping — Apple's stated rationale for live multiuser over frozen maps [4]. This directly addresses the drift/staleness problem that killed Option 2.

**Verdict:** right mechanism for continuous alignment; its cold-start merge UX is the documented pain point [3][10].

### Option 4 — Marker/anchor-based bootstrap (+ continuous tracking for drift)

The recurring industry pattern for fast same-room alignment:

- **HoloKit (shipped iOS AR product line, incl. game "MOFA")** ships three iOS colocation boilerplates: (a) external printed marker — every device detects the same image and resets its coordinate origin to it, recommended for **>3 devices**; (b) dynamically rendered marker shown on the host's screen for clients to scan — works anywhere without a printout, suited to 2–3 devices; (c) Immersal pre-scanned map [10][11]. Their accuracy trick: fuse **multiple consecutive marker pose detections** and only reset the origin once the sequence is stable, rather than trusting a single detection [11]. MOFA itself = Netcode + MultipeerConnectivity + external marker [10].
- **Grow agency** built a multiplayer AR basketball prototype on a printed wall marker + MultipeerConnectivity [12].
- **XRoom "Disco Arena"** postmortem: a *single* QR anchor caused frequent tracking loss and forced rescans; the shipped fix was **multiple QR codes placed around the space** as redundant anchors [28].
- **HADO** — arguably the most successful shipped co-located AR product (an AR sport running since 2016, World Cup, iPhones in headsets) — lines its courts with printed positional reference patterns that headset cameras track continuously; position fixes come from markers, not from map merging [26][27].
- **Academic support:** a peer-reviewed 2025 Sensors paper built AprilTag-based shared-space calibration as a fully local alternative to cloud spatial anchors and found it "accurate and works well for synchronizing multiple users" [36].
- **Cross-vendor convergence:** Niantic's same-room colocalization is literally image-tracking [13][18]; Meta's Quest colocation aligns every device to a shared spatial anchor (create→cloud-share→localize→align) [31]; a shipped Quest game ("Cooked") uses it [32]; Meta documents that anchors drift once the device is >3 m away, motivating periodic re-alignment [30]; a WebXR shipped-game writeup shows that once a shared reference space exists, broadcasting a single origin coordinate suffices [29].

**Known weakness (consistent across sources):** a single marker aligns one point — drift accumulates with session length and play-area size [10][30]. Mitigations seen in the wild: multiple markers (XRoom [28]), marker re-scan as instant relocalization (HoloKit [10][11]), continuous re-localization polling (Niantic VPS [37]), and periodic re-alignment (Meta ecosystem [30]).

**Native-iOS feasibility (inference, well-grounded):** `detectionImages`/`ARImageAnchor` gives the detection primitive natively [5]; each device can express its own origin relative to the shared image anchor without any SDK. Combining that with Option 3's collaboration channel for ongoing drift correction mirrors exactly what Niantic and HoloKit ship. Note: repo AGENTS.md prohibits "visible target markers" — a printed QR/AprilTag conflicts with that constraint unless the marker is transient (host-screen-rendered, HoloKit variant b) or the constraint is revisited via decision record.

### Option 5 — ARCore Cloud Anchors on iOS (cross-platform alternative)

The ARCore SDK for iOS wraps ARKit: `hostCloudAnchor` uploads local visual data and returns a Cloud Anchor ID; peers call `resolveCloudAnchorWithIdentifier` with the ID plus their own visual data and get the anchor's pose in their local frame [33]. TTL up to 365 days [34]. It works natively on iOS (no Unity required for the SDK itself), but adds a Google Cloud dependency: API key, network round-trips at join time, and the 2022 endpoint migration shows the operational surface area [35]. For a same-room game this buys cross-platform reach at the cost of cloud dependency — for an iPhone-only room it solves a problem the local options already solve.

### What shipped products actually use (summary)

| Product | Alignment mechanism |
|---|---|
| Pokémon GO Shared AR (Niantic) | QR code = lobby join only; spatial sync = all players sweep phones around the *same physical 3D object* until maps merge — i.e., SLAM-overlap bootstrap [24][25] |
| HADO (meleap) | Printed positional-reference markers on court walls, continuously tracked [26][27] |
| HoloKit MOFA | External printed image marker + MultipeerConnectivity [10][11] |
| XRoom Disco Arena | Multiple printed QR anchors [28] |
| Quest co-located games (Cooked etc.) | Shared Spatial Anchor (cloud) + periodic re-alignment [30][31][32] |
| Apple SwiftStrike (WWDC19) | Collaborative session + MultipeerConnectivity [4] |

**Pattern across shipped products (inference):** nobody ships world-map share+relocalize for live play. Shipping products split into (a) marker/anchor-reference designs (fast, deterministic bootstrap; needs a marker or anchor service) and (b) SLAM-overlap merge designs (ARKit collaboration, PoGO's "point at the same object" — markerless but slower and less deterministic). Hybrid — marker or anchor for bootstrap, continuous shared tracking for drift — is the dominant production answer.

### Comparison for this game (4 players, ordinary room, variable lighting)

| Criterion | ARWorldMap share | Collab sessions (current) | Marker bootstrap + collab | Lightship Shared AR | Cloud Anchors |
|---|---|---|---|---|---|
| Bootstrap speed | Slowest; fails on moved/low features [1][6] | 3–15 s side-by-side scan, skill-dependent [3][10] | Near-instant detection [10][11] | Image mode: near-instant; VPS: seconds but needs activated location [13][16] | Seconds; needs network + prior scan overlap [33] |
| Reliability in ordinary room | Poor (snapshot goes stale) [1][7] | Medium — needs overlapping views; feature-poor rooms stall merge [3][10] | High — deterministic fiducial; multi-marker adds redundancy [11][28][36] | High for image mode [13] | Medium-high but cloud-dependent [33] |
| Drift over session | Map frozen — no correction [2][4] | Continuous map merging corrects drift [4] | Single-point alignment drifts; mitigate with multi-marker/re-scan or collab [10][28][30] | Continuous Localization option [37] | Re-resolve on drift [34] |
| Recovery after tracking loss | Re-run relocalization (slow) | Re-merge on next overlap view [3] | Instant re-scan of marker [10][11] | Re-track image/VPS [13] | Re-resolve [33] |
| Dependencies/cost | None | None (any transport incl. WebSocket) | None (native ARKit image detection [5]) | Unity + API key + MAU pricing risk [19][20][22] | Google API key + network [33] |
| Fits repo constraints (no Unity, no visible markers) | Yes | Yes | Marker conflicts unless transient/host-screen variant or ADR change | No (Unity) | Yes, but adds cloud dep |

**Recommendation (inference from evidence):** keep collaborative sessions as the continuous-alignment layer — it is the only mechanism that keeps correcting drift after bootstrap [4]. Its weakness is purely the cold-start merge [3][10]. The evidence-backed fix is a deterministic bootstrap: have all devices view the *same small region* during join (formalize the "point at the same spot/object" ritual that Apple and Niantic both use [3][24]), and/or a transient shared reference (host-screen-rendered image marker — HoloKit's anywhere-variant, no printout needed [11]) to seed alignment before or alongside the collab merge. If repo constraints were relaxed, a printed/multi-marker design has the strongest shipped-product evidence (HADO, HoloKit, XRoom, Niantic image mode) [26][11][28][13]. ARWorldMap sharing should not be revived for live play [1][4].

---

## Coverage Status

- Checked directly (fetched/read): all 38 sources in the table; canonical Apple docs, Niantic docs/API refs/forums, HoloKit docs+repo, Grow, JapanGov/HADO, XRoom, Meta docs, Google docs verified live via HTTP 200 or retrieved content.
- Bot-blocked but real (search tool retrieved content; direct curl returned 403): StackOverflow [9], MDPI [36], Unity Discussions [8], Gamepur [25]. Marked medium confidence accordingly.
- Uncertain: Niantic SDK pricing is in flux — verify at adoption time [19][20][23]. Whether ARKit collaboration has a hard device cap at 4 peers — no documented cap found; one 2019 report of 2-device limit in Unity's AR Foundation sample [8]. Flagged for physical-device testing.
- Not found / did not exist: no public engineering postmortem for Pokémon GO's internal sync implementation beyond observable UX [24][25]; no evidence any shipped phone-AR product uses ARWorldMap-share for live multiplayer.
- `archive/` history not consulted (research task scoped to external evidence).

## Sources

1. Apple — Creating a multiuser AR experience — https://developer.apple.com/documentation/arkit/creating-a-multiuser-ar-experience
2. Apple — ARWorldMap — https://developer.apple.com/documentation/arkit/arworldmap
3. Apple — Creating a collaborative session — https://developer.apple.com/documentation/arkit/creating-a-collaborative-session
4. Apple — WWDC19 Session 610: Building Collaborative AR Experiences — https://developer.apple.com/videos/play/wwdc2019/610/
5. Apple — Detecting Images in an AR Experience — https://developer.apple.com/documentation/arkit/detecting-images-in-an-ar-experience
6. Apple Developer Forums — ARKit device interoperability question — https://developer.apple.com/forums/thread/726044
7. Apple Developer Forums — ARWorld loading works differently on iOS 14 and 15 — https://developer.apple.com/forums/thread/690668
8. Unity Discussions — Collaborative Sessions limited to two devices? — https://discussions.unity.com/t/collaborative-sessions-limited-to-two-devices/748035/1
9. Stack Overflow — RealityKit Custom ARAnchor not syncing across devices — https://stackoverflow.com/questions/64304557/realitykit-custom-aranchor-not-syncing-across-devices
10. HoloKit Docs — Tutorial 5: Multiplayer AR — https://docs.holokit.io/creators/tutorials/tutorial-5-multiplayer-ar
11. HoloKit — holokit-colocated-multiplayer-boilerplate — https://github.com/holokit/holokit-colocated-multiplayer-boilerplate
12. Grow — Bring Multiplayer AR Alive with Interactive Physics — https://thisisgrow.com/insights/bring-multiplayer-ar-alive-with-interactive-physics
13. Niantic Spatial — NSDK Sample Projects — https://www.nianticspatial.com/docs/nsdk/3.17.0/sample_projects/
14. Niantic Spatial — SharedSpaceManager API — https://www.nianticspatial.com/docs/nsdk/3.17.0/apiref/Niantic/Lightship/SharedAR/Colocalization/SharedSpaceManager/
15. Niantic Spatial — ISharedSpaceTrackingOptions API — https://www.nianticspatial.com/docs/nsdk/3.17.0/apiref/Niantic/Lightship/SharedAR/Colocalization/ISharedSpaceTrackingOptions/
16. Niantic Spatial — Visual Positioning System (VPS) — https://www.nianticspatial.com/docs/nsdk/features/lightship_vps/
17. Niantic Spatial — How to Create a Public Location — https://nianticspatial.com/docs/nsdk/how-to/vps/tooling/create_vps_activated_location/
18. Niantic Spatial Community — Shared location with Peer Pose — https://community.nianticspatial.com/t/shared-location-with-peer-pose/4980
19. Niantic Spatial Community — VPS Pricing Model and Costs — https://community.nianticspatial.com/t/vps-pricing-model-and-costs/4294
20. Niantic Spatial Community — Pricing changes of Lightship — https://community.nianticspatial.com/t/pricing-changes-of-lightship/5134
21. Niantic Spatial Community — Embedding Lightship in native iOS/Android apps — https://community.nianticspatial.com/t/embedding-lightship-in-native-ios-android-apps/2486
22. Niantic Spatial — Setting Up the Niantic SDK — https://www.nianticspatial.com/docs/nsdk/3.17.0/setup/
23. Niantic Spatial — Plans and Pricing — https://www.nianticspatial.com/pricing
24. Pokémon GO Hub — How to AR: Group/Shared AR — https://pokemongohub.net/post/ar/how-to-ar-group-shared-ar/
25. Gamepur — How to use the Shared AR Experience in Pokémon Go — https://www.gamepur.com/guides/how-to-use-shared-ar-experience-with-friends-in-pokemon-go
26. JapanGov — A New AR Sport from Japan (HADO) — https://www.japan.go.jp/topics/2026/07/new_ar_sport.html
27. HADO — How the technology works — https://www.hadoarsports.com/how-the-technology-works
28. Feiyan Zhang — XRoom AR Multiplayer Game (Disco Arena) — https://www.feiyanzhang.com/xroom-ar-multiplayer-game
29. dmnshd.gg — Shared Spaces in WebXR: Two Headsets, One Coordinate System — https://dmnshd.gg/blog/webxr-shared-spaces
30. Meta — Colocation tips, tricks, and FAQ — https://developers.meta.com/horizon/documentation/unity/unity-colocation-tips-tricks-faq/
31. Meta — Colocation sample with Photon Fusion — https://developers.meta.com/horizon/documentation/unity/unity-sample-colocation-fusion/
32. lawtancool — Cooked (co-located Quest game) — https://github.com/lawtancool/Cooked
33. Google — Cloud Anchors developer guide for iOS — https://developers.google.com/ar/develop/ios/cloud-anchors/developer-guide
34. Google — Cloud Anchors overview — https://developers.google.com/ar/develop/cloud-anchors
35. Google — ARCore 1.33 Cloud Anchor endpoint changes — https://developers.google.com/ar/develop/cloud-anchors/endpoint-changes
36. MDPI Sensors (2025) — AprilTags in Unity: A Local Alternative to Shared Spatial Anchors — https://www.mdpi.com/1424-8220/25/14/4408
37. Niantic Spatial — Getting Started with VPS — https://www.nianticspatial.com/docs/ardk/how-to/vps/adding_vps/
38. Niantic — Codename: Neon demo (YouTube) — https://www.youtube.com/watch?v=dO1NpT2SSX4
