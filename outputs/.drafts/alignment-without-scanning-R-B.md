# Alignment Without Environment Scanning — Research R-B

Scope: game architectures that avoid shared-world-map alignment entirely + deep-dive on the transient marker bootstrap, for the 4-player iOS AR shooter that currently fails on ARKit collaborative-session map merges.

## Executive Summary

- **A shared world frame is NOT required for a body-shooter.** Three shipped precedents prove hit-detection works without any merged map: (a) **camera-space detection** — shoot the person visible in your camera (RealTag, LegitLaser, Light Wars AR, Vision Tag OSS) [9][10][11][12]; (b) **peer ranging** — UWB Nearby Interaction streams distance + direction to each peer expressed in YOUR local frame, no shared frame involved [13][14]; (c) **peer-pose exchange** — which *does* need one bootstrap transform per device pair, cheapest via a transient marker [1][2][3].
- **The camera-space approach has an identity problem at >2 players.** ARKit tracks only ONE body and cannot tell *which* person was hit [16][17]. RealTag's own users report exactly this bug: shooting any bystander damages the playing peer [9]. For 4 players, camera detection must be combined with peer identity (pose exchange or ranging).
- **The transient marker bootstrap is fully implemented in OSS.** HoloKit's `holokit-image-tracking-relocalization` package contains the complete host-screen-marker flow, including the fused-pose math (NTP-style clock sync + timestamped pose pairs + least-squares yaw solve + std-dev gates) — read directly, math extracted below [1][4][5][6].
- **Post-bootstrap drift is simply accepted.** HoloKit does no continuous drift correction after marker sync — no ARWorldMap/collab code exists in the marker path; a manual "Resync" button re-runs the ritual [1][2][7]. Meta's equivalent (World Lock Colocation) uses a single shared anchor + SDK drift compensation, and documents drift past ~3 m from the anchor [22][23].
- **Compass is too noisy to seed orientation.** Peer-reviewed indoor heading error is ~17° RMSE *after* mitigation; raw e-compass is "erratic" inside buildings [25][26]. Use it only as a hint, never as the alignment source.

---

## Finding 1 — Peer-relative architecture viability for a shooter

### What spatial information is actually required?

For "aim at and shoot the other player's body," the only required datum is: **where is the peer relative to my camera right now?** Nothing about walls, floor, or environment geometry is needed for hit registration (environment only matters for occlusion realism). Three architectural families deliver that datum:

**Option A — Camera-space hit detection (no shared frame at all).**
The camera IS the sensor: if a person is at the crosshair when you fire, it's a hit. Shipped precedent:

| App | Mechanism | Source |
|---|---|---|
| RealTag (iOS/Android) | "Shoot other players that are in the camera, the game detects when you've hit someone" — phone only, same Wi-Fi | [9] |
| LegitLaser (iOS) | "Advanced computer vision, your phone's camera becomes the sensor… real-time AR hit detection with no specialized vest or hardware" | [10] |
| Light Wars AR | "Your phone handles the blaster, match systems, and hit detection" — up to 6 players, no extra gear | [11] |
| Flash Tag AR (iOS) | Uses the phone **flash** to shoot friends' phones; "proprietary flash tracking technology"; no extra hardware | [12] |
| Vision Tag (OSS, nickofca) | Camera frames → FastAPI server → Mask R-CNN segmentation → person in center of frame = hit; displays health bar over the aimed person | [15] |

**Why Father.IO needed hardware (answering the brief):** the Inceptor is an IR emitter+receiver dongle because software alone couldn't provide reliable hit *registration* at 50 m — IR gives physical shot→target confirmation independent of CV accuracy and lighting [8][20]. Without the Inceptor, Father.IO's app limited users to GPS-based resource collection — "you will also be unable to participate in the first-person shooter aspect" [21]. The software-only successors accepted CV-based detection as the trade-off [9][10][11].

**The identity limitation (critical for 4 players).** ARKit body tracking tracks only ONE body — `ARBodyAnchor` is "an anchor that tracks the position and movement of **a** human body" (singular) [16]; Unity's ARHumanBodyManager discussion confirms "ARKit can only track one body at a time… you have no control over which body in the frame is tracked if multiple people are present" [17]. `personSegmentation(WithDepth)` gives a per-pixel "is a person" mask for ALL people in frame but carries **no identity** — it cannot distinguish peer A from peer B from a bystander [18]. Real-world confirmation: a RealTag user reports "you can shoot any other person and the person you are playing with will get damage"; the developer's contemplated fix was a per-player "scanner" (i.e., identity bootstrap) [9]. Vision Tag avoids the problem entirely by being **1v1** — center-of-frame person detection is unambiguous with one opponent [15].

*Inference:* for this 4-player shooter, pure camera-space detection is insufficient alone — a hit on "a person" must be resolved to a specific peer. It can still serve as a cheap hit-confirm layer (person mask ∩ crosshair) *combined* with identity from pose exchange or ranging.

**Option B — UWB Nearby Interaction ranging (frame-free peer positions).**
`NISession` + `NINearbyPeerConfiguration` streams **distance and direction** to each opted-in peer, expressed relative to the local device [13][14]. This is the only architecture where peer positions arrive *already in your frame* — no bootstrap, no shared map, no markers:
- Requires U1/U2 chip → iPhone 11+ (all-modern iPhones qualify) [13].
- iOS 16+ `isCameraAssistanceEnabled` fuses ARKit trajectory with UWB ("Precision Finding" tech) making direction consistently available even outside UWB field-of-view [13][14].
- Design: each of the 3 other peers is a `(distance, direction)` vector in my frame → render hitbox/indicator at that vector; hit = crosshair ray vs peer sphere ± dead-reckoning between updates. Fully peer-relative; nothing is shared.

Caveats (inference): first-gen UWB direction coverage is limited without camera assistance; ranging gives the phone position, not the body — a peer's body extends ~±0.3 m around the device, so hitboxes must be generous; Apple requires a Nearby Interaction permission prompt per peer session [14].

**Option C — Peer-pose exchange in a bootstrapped shared frame.**
HoloKit's model: after a one-time transform sync, each device streams its local camera pose and renders peers as avatars at exchanged poses (`PlayerPoseSynchronizer` simply copies `ARCameraManager` pose into a networked transform every frame) [5]. Pose exchange is only meaningful *after* devices share a frame — which is why it needs a bootstrap (Finding 2). Convention needed if poses are exchanged WITHOUT a shared frame (analysis): a raw device pose is meaningless in another frame; a "device-relative + gravity-aligned" convention (origin at session start, y-up from gravity) still leaves a yaw ambiguity that only compass (noisy [25][26]) or a bootstrap ritual can resolve — i.e., you always end up needing one bootstrap transform per pair regardless; the question is only how cheap it is.

### Ranking for this game

1. **UWB ranging** — truly frame-free, pairwise identity, no scanning ritual; best UX if all devices are iPhone 11+.
2. **Marker bootstrap + pose exchange** — proven OSS, works on any ARKit-capable iPhone; one ~2 s ritual.
3. **Camera-space detection** — free hit-confirm layer / fallback when a peer is visually centered; insufficient alone for identity at 4 players (but perfect as the *hit validator* layered on A or B: person-mask ∩ crosshair prevents shooting empty air).

---

## Finding 2 — Transient marker bootstrap: implementation detail (HoloKit OSS, read directly)

Source: `holokit/holokit-image-tracking-relocalization` (MIT license, cloned and read) [1], plus `holokit-colocated-multiplayer-boilerplate` [2] and HoloKit docs [3].

### Architecture of the dynamically-rendered (host-screen) marker variant

1. **Host renders a physical-size marker on its own screen** (`MarkerRenderer.SpawnMarker()`) [4]:
   - `MARKER_WIDTH = 0.04f` meters — a 4 cm marker drawn via a Unity `MarkerCanvas`.
   - The marker's pixel size is computed as `0.04 m × 39.3701 in/m × screenDpi` using a **per-phone-model database** (`PhoneModelList`) that stores each iPhone model's `ScreenDpi`, `ScreenResolution`, and `CameraOffset` — because the physical on-screen size must match the `XRReferenceImageLibrary` declared `physicalSize`, and the marker's true offset from the device camera must be known [4][2].
   - `BACKGROUND_RATIO = 0.4` — marker shown on a dedicated background covering 40% of screen height.
   - Returns `cameraToMarkerOffset` and `cameraToScreenCenterOffset` (camera→marker center and camera→screen center, in meters, using the model's stored camera-to-body offset).
2. **Clock sync first** (`NetworkImageTrackingStablizer`, client side) [6]: client ping-pongs `GetSystemUptime()` with the host (NTP-style: `offset = hostTs + (now−sent)/2 − now`), collecting ≥10 samples until std-dev < 0.01 s, so both devices can reference *the same instant*.
3. **Timestamped pose-pair collection** [6][7]:
   - Client ARKit tracks the host's screen marker → sends `(clientTimestamp, clientImagePosition, clientImageRotation)` to host.
   - Host keeps a rolling queue of its own camera poses (600 ms window); on each client request it finds its camera pose within **34 ms** of the client's timestamp, computes the marker's pose in the HOST frame as `hostCamPose · cameraToMarkerOffset` (position) and `hostCamRot · Rot(-90°,0,0)` (rotation — screen-normal convention), and replies with the `ImagePosePair` [7].
4. **Fused pose = least-squares yaw solve over ~50 pairs** (`CalculateClientSyncResult`) [6]:
   - Centers both position sets, then accumulates `a = px·qx + pz·qz + K·(r00 + r22)` and `b = −px·qz + pz·qx + K·(−r20 + r02)` per pair (`K = m_OptimizationPenaltyConstant = 10` couples rotation terms into the position solve), and solves `θ = atan2(Σb, Σa)` — a **yaw-only** alignment around world-up (gravity already aligns pitch/roll on both devices).
   - `translate = −R(θ)·(hostImagePosCenter − clientImagePosCenter)`; a SyncResult is produced per new pair; only when **30 consecutive results show θ std-dev < 0.1°** is the sync accepted.
5. **Apply** [6]: `ARKitNativeProvider.ResetWorldOrigin(translate, RotY(θ))` — the client's AR world origin is reset so both frames coincide; then an "alignment marker" is spawned parented to the host's player object at `cameraToScreenCenterOffset` for **manual visual verification** — the user sees a virtual marker floating where the host's screen is and can Accept / Deny / Resync.
6. **Simpler external-marker variant** (same package): `ImageTrackingStablizer` queues tracked poses, requires ≥50 samples within 1.5 s with position std-dev ≤ 2 cm and rotation std-dev ≤ 36°, then `WorldTransformResetter`/`TrackedImagePoseTransformer` reset the world origin to the marker's position + yaw-only of `imageRot · RotX(90°)` — the yaw extracted via `atan2(−r20+r02, r00+r22)` on the corrected rotation [28][29][30].

### Answers to the deep-dive questions

- **Single detection vs fused:** HoloKit's README states single-shot detections produce "significant deviations" — the whole package exists to stabilize via sequences of consecutive poses [1][2]. Direct answer: a single `ARImageAnchor` detection is usable but jittery; fusing 30–50 samples with std-dev gates is what makes it production-viable.
- **Host-screen specifics:** the marker must be rendered at a true physical size (4 cm) — HoloKit carries a per-model DPI/resolution/camera-offset table for this [4]. Apple's own image-detection sample explicitly suggests displaying the reference image full-screen on a spare device and pointing the other camera at it — screen-as-marker is a documented workflow [31]. Apple's guidance (quoted verbatim in a Unity forums answer): *"If an image is printed on glossy paper or displayed on a device screen, reflections on those surfaces can interfere with detection"* — mitigations: matte/high-contrast marker, white marker on dark background, max brightness during the ritual [32]. Physical `physicalSize` accuracy is mandatory — wrong size → wrong distance → wrong transform [31][32].
- **Runtime-added reference images:** `ARImageTrackingConfiguration.trackingImages` accepts `ARReferenceImage` objects created at runtime (CVPixelBuffer/CGImage + `physicalSize`), and `ARWorldTrackingConfiguration.detectionImages` likewise — no asset-catalog entry needed [33]. Note: world-tracking continues tracking the anchor after the image leaves view, which is actually useful for a transient marker.
- **Post-bootstrap drift:** **no continuous correction exists in HoloKit's marker path** — the boilerplate has zero ARWorldMap/collaboration code; `StopTrackingMarker()` runs after sync and the only remedy is a manual `ResyncPose()` button that re-displays the host marker and re-runs the whole flow [1][2][6][7]. Drift is accepted. Cross-platform check: Meta's single-anchor "World Lock Colocation" similarly needs "a single shared spatial anchor, with no need to scan your room," but MRUK compensates drift afterward [22]; Meta documents anchor drift growing when >3 m from the anchor [23]. *Inference:* for a shooter where peers move and hitboxes are ~0.5 m, accepting drift is reasonable for match-length sessions; periodic re-scan of the host screen is the cheapest correction and is already built into the ritual.

---

## Finding 3 — Other bootstrap methods, ranked

| # | Method | Mechanism | Verdict |
|---|---|---|---|
| 1 | **Host-screen ARReferenceImage** (HoloKit variant b) | `detectionImages`/`trackingImages` on the marker drawn at true physical size on host screen; fused-pose handshake above | **Strongest.** Shipped OSS, no printout, ~1–2 s ritual, works on any ARKit iPhone [1][3][31]. Fits the repo's "no visible target markers" rule if the marker is transient (shown only during join) — flagged in R2 |
| 2 | **UWB Nearby Interaction** | Distance + direction per peer in local frame; ARKit camera assistance | Not a bootstrap but removes the need for one entirely; iPhone 11+ required [13][14] |
| 3 | **Peer-screen rectangle + PnP** | `VNDetectRectanglesRequest` finds the phone screen quadrilateral → 4 corners → hit-test/PnP pose | Viable but strictly weaker than (1): rectangle detection is notoriously imprecise ("the result… is not good", bounding-box vs true corners confusion), and you must fuse the corners yourself; ARImageTracking already does this internally [34][35] |
| 4 | **Detect the physical phone itself** | Vision rectangle on device edges | Same class as (3) but worse: phone bezels have low contrast and variable aspect; not recommended |
| 5 | **Shared physical point + compass** | Both tap the same spot → common translation; gravity fixes pitch/roll; compass resolves yaw | Insufficient alone: one point gives position but leaves yaw; indoor heading error ~17° RMSE after mitigation and raw compass is "erratic" in buildings — too noisy to seed a frame [25][26]. Usable only as a coarse hint combined with another method |
| 6 | **Manual "tap same spot" ritual** | Single-point anchor exchange | Position only; needs #5's compass or a second point — weakest |

(A single shared point resolves translation; with gravity-aligned frames only yaw remains — one point + compass is the minimal theoretical bootstrap, but #5 shows compass can't deliver it reliably.)

---

## Recommendation

1. **Primary:** adopt HoloKit's host-screen marker bootstrap, ported to native Swift: host renders a 4 cm high-contrast marker (runtime `ARReferenceImage` with correct `physicalSize`, per-model DPI/offset table), clients detect it via `configuration.detectionImages`, and the pair computes the transform with the fused-pose handshake (clock-sync + timestamped pose pairs + yaw least-squares + std-dev gates) — all math available in MIT-licensed code [1][4][6][7]. Then keep the existing pose-exchange layer exactly as HoloKit does (local camera pose → networked transform) [5]. **Drop collaborative sessions entirely for this flow** — HoloKit ships with zero drift correction and manual resync; for a shooter with sub-meter hitboxes this is acceptable, and it eliminates the failing merge path.
2. **Strong alternative / future:** prototype UWB Nearby Interaction — it is the only architecture that needs *no* shared frame and no ritual at all [13][14]; for iPhone 11+ fleets it could replace bootstrap + pose exchange entirely for the targeting layer.
3. **Hit validation layer (independent of bootstrap choice):** use `personSegmentation`/`bodyDetection` as a cheap "is the crosshair on a human" check to prevent wall-shots [16][18], but never for identity — ARKit can't distinguish persons [17]; identity comes from pose exchange or ranging.
4. **Do not use compass** for alignment seeding [25][26]; keep the host-screen marker transient (join-time only) to respect the repo's "no visible target markers" constraint.

---

## Coverage Status

- **Read directly (cloned source):** `holokit-image-tracking-relocalization` — `ImageTrackingStablizer.cs`, `WorldTransformResetter.cs`, `MarkerRenderer.cs`, `NetworkImageTrackingStablizer_Host.cs`, `NetworkImageTrackingStablizer_Client.cs`, `PlayerPoseSynchronizer.cs` [1][4][5][6][7][28][29]; `holokit-colocated-multiplayer-boilerplate` — `TrackedImagePoseTransformer.cs` + grep-verified absence of collab/ARWorldMap/drift code [2][30].
- **Read via docs/snippets:** Apple developer docs (ARKit image detection, NI, body anchor, CLHeading, Vision rectangles), Meta developer docs, app-store listings, Stack Overflow, HoloKit tutorial.
- **Uncertain / not verified:** real-world accuracy numbers of the host-screen handshake on physical devices (no published benchmarks found — only the std-dev thresholds in code); RealTag/LegitLaser internal implementations (inferred from listings + reviews, not source); `PhoneModelList` asset contents (file is a Unity `.asset`, referenced but not parsed); whether `detectionImages` in world-tracking has any cap affecting a transient marker (Apple documents no practical limit for a single image).
- **Blocked:** none.

---

## References

### Marker bootstrap & colocation
1. HoloKit — `holokit-image-tracking-relocalization` (repo; source read directly) — https://github.com/holokit/holokit-image-tracking-relocalization
2. HoloKit — `holokit-colocated-multiplayer-boilerplate` (repo; source read directly) — https://github.com/holokit/holokit-colocated-multiplayer-boilerplate
3. HoloKit Docs — Tutorial 5: Multiplayer AR — https://docs.holokit.io/creators/tutorials/tutorial-5-multiplayer-ar
4. `MarkerRenderer.cs` (in repo [1], `Runtime/iOS/`) — https://github.com/holokit/holokit-image-tracking-relocalization/blob/main/Runtime/iOS/MarkerRenderer.cs
5. `PlayerPoseSynchronizer.cs` (in repo [1]) — https://github.com/holokit/holokit-image-tracking-relocalization/blob/main/Runtime/iOS/PlayerPoseSynchronizer.cs
6. `NetworkImageTrackingStablizer_Client.cs` (in repo [1]) — https://github.com/holokit/holokit-image-tracking-relocalization/blob/main/Runtime/iOS/NetworkImageTrackingStablizer_Client.cs
7. `NetworkImageTrackingStablizer_Host.cs` (in repo [1]) — https://github.com/holokit/holokit-image-tracking-relocalization/blob/main/Runtime/iOS/NetworkImageTrackingStablizer_Host.cs
28. `ImageTrackingStablizer.cs` (in repo [1]) — https://github.com/holokit/holokit-image-tracking-relocalization/blob/main/Runtime/ImageTrackingStablizer.cs
29. `WorldTransformResetter.cs` (in repo [1]) — https://github.com/holokit/holokit-image-tracking-relocalization/blob/main/Runtime/WorldTransformResetter.cs
30. `TrackedImagePoseTransformer.cs` (in repo [2]) — https://github.com/holokit/holokit-colocated-multiplayer-boilerplate/blob/main/Assets/Scripts/TrackedImagePoseTransformer.cs
22. Meta — MRUK World Lock Colocation ("single shared spatial anchor, no need to scan your room") — https://developers.meta.com/horizon/documentation/unity/unity-mr-utility-kit-world-lock-colocation/
23. Meta — Colocation tips/FAQ (anchor drift >3 m) — https://developers.meta.com/horizon/documentation/unity/unity-colocation-tips-tricks-faq/

### Apple platform primitives
31. Apple — Detecting Images in an AR Experience (full-screen image on a spare device workflow; physicalSize accuracy) — https://developer.apple.com/documentation/arkit/detecting-images-in-an-ar-experience
32. Unity Forums — "ARCore tracks consistently and ARKit doesn't" (verbatim Apple guidance incl. device-screen reflection caveat) — https://discussions.unity.com/t/arcore-tracks-consistently-and-arkit-doesnt/1713039
33. Apple — `ARImageTrackingConfiguration` (runtime `trackingImages`, 6DOF) — https://developer.apple.com/documentation/arkit/arimagetrackingconfiguration
34. Apple — `DetectRectanglesRequest` (Vision rectangle detection) — https://developer.apple.com/documentation/vision/detectrectanglesrequest
35. Stack Overflow — Vision→ARKit coordinate transform + corner hit-test — https://stackoverflow.com/questions/44944581/how-to-transform-vision-framework-coordinate-system-into-arkit
36. Stack Overflow — VNDetectRectanglesRequest imprecision (bounding box vs corners) — https://stackoverflow.com/questions/46095984/ios-11-using-vision-framework-vndetectrectanglesrequest-to-do-object-detection-n
16. Apple — `ARBodyAnchor` (single tracked body) — https://developer.apple.com/documentation/arkit/arbodyanchor
17. Unity Forums — "ARHumanBodyManager cannot distinguish different human bodies" (one body, no identity control) — https://discussions.unity.com/t/arhumanbodymanager-in-ios-cannot-distinguish-different-human-bodies/1659422
18. Apple — Occluding virtual content with people (`personSegmentation`/`WithDepth` mask) — https://developer.apple.com/documentation/ARKit/occluding-virtual-content-with-people
19. Apple — `ARBodyTrackingConfiguration` (`bodyDetection` → `frame.detectedBody`, singular) — https://developer.apple.com/documentation/arkit/arbodytrackingconfiguration
13. Apple — `NINearbyPeerConfiguration` (UWB distance+direction; `isCameraAssistanceEnabled`) — https://developer.apple.com/documentation/nearbyinteraction/ninearbypeerconfiguration
14. Apple — WWDC20 "Meet Nearby Interaction" + Finding devices with precision — https://developer.apple.com/videos/play/wwdc2020/10668/ — https://developer.apple.com/documentation/nearbyinteraction/finding-devices-with-precision

### Laser-tag precedent
8. Father.IO — Inceptor (IR emitter+receiver dongle spec) — https://father.io/inceptor.html
20. WIRED — "Father i.o game release uses augmented reality to play laser tag" (IR → 50 m laser weapon) — https://www.wired.com/story/father-io-multiplayer-game/
21. Mashable — "New app turns the entire world into a giant game of laser tag" (without Inceptor: no FPS mode) — https://mashable.com/archive/father-io-smartphone-game
9. RealTag — Google Play listing + user review (camera hit detection; identity bug report) — https://play.google.com/store/apps/details?id=com.arfps.android
10. LegitLaser — App Store listing (CV hit detection, no hardware) — https://apps.apple.com/lc/app/legitlaser-ar-laser-tag/id6756782953
11. Light Wars AR — official site (phone handles hit detection, ≤6 players) — https://lightwarsar.com/
12. Flash Tag AR — App Store listing (flash-tracking shooting, no hardware) — https://apps.apple.com/us/app/flash-tag-ar/id1343499972
15. nickofca/vision_tag — GitHub (Mask R-CNN server hit detection; person in center = hit) — https://github.com/nickofca/vision_tag/

### Compass / manual bootstrap
25. ION NAVIGATION — "Robust Determination of Smartphone Heading by Mitigation of Magnetic Anomalies" (17.4° RMSE indoors post-mitigation) — https://navi.ion.org/content/71/1/navi.632
26. MIT Media Lab — "Indoor location sensing using geo-magnetism" (e-compasses erratic inside buildings) — https://www.media.mit.edu/speech/papers/2011/positioning.systems.pdf
27. Apple — `CLHeading` (`headingAccuracy` = max deviation; negative = invalid) — https://developer.apple.com/documentation/corelocation/clheading
