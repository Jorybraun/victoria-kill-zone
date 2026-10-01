# Spatial Alignment Between Co-located iPhones Without Environment Scanning

Research question: can device-to-device ranging (UWB Nearby Interaction, acoustic, optical, RF) seed or replace ARKit collaborative-session world-map merging for a 4-player co-located iOS AR shooter?

Date: research compiled from Apple developer docs, WWDC sessions, academic literature, developer forums, and patents. Source types flagged per claim.

---

## Executive Summary

**Yes — this approach is viable and is well-precedented in the research literature.** Three independent academic systems (LocAR/Cappella, SynchronizAR, and a 4-DOF UWB/V-SLAM pose solver) demonstrate exactly the fusion proposed: UWB peer-to-peer ranges + each device's visual-inertial odometry → relative coordinate transform between independent SLAM frames, with no shared field of view and no environment scanning [16][17][18][19].

Key findings:

1. **UWB Nearby Interaction gives distance (~10–20 cm error) plus, when geometry cooperates, a 3D direction vector or 1D azimuth to each peer** [1][2][9]. It is bidirectional and explicitly supports the 4-player topology: WWDC20 documents four devices each running three parallel `NISession`s [2].
2. **Fusion math closes.** With `.gravity` world alignment, the inter-frame transform has 4 DOF (3D translation + yaw). A *single* bidirectional distance+direction measurement plus both devices' ARKit camera poses is sufficient to solve it in closed form (derivation below). Distance-only needs relative motion and ≥5–6 range measurements [19], or a particle filter [16].
3. **Major caveats**: direction is only available inside a narrow cone behind each iPhone (~ultra-wide camera FoV); direction is `nil` when peers face away [1][5]. On U2-chip iPhones (15/16 Pro) multiple developers report `direction` is never delivered with third-party accessories and possibly not at all without camera assistance [12][14]. Camera-assisted NI (iOS 16+) widens the FoV but requires the shared ARSession to run `.gravity` alignment with **collaboration disabled** — so camera assistance and ARKit collaboration cannot run concurrently in one session [1][34].
4. **Best fallback/compliment**: the "optical handshake" — one phone shows a QR/pattern on screen, the peer's camera solves PnP on it → full 6-DOF relative pose in one shot, no environment features needed. Documented in a granted Snap patent and multiple implementations [21][22][23][24].
5. **BLE RSSI (meter-scale error), GPS+compass (5m+ / 5–30° heading error), and acoustic ranging (research-grade only) are all inferior** for this use case [27][28][30][31][32][33].

Recommended architecture for the shooter: keep ARKit collaboration as a *refinement* path, but seed alignment via a short NI "rendezvous" phase (players face each other ~1–4 m apart), solve pairwise transforms to a host frame, and keep NI sessions running during play so remote-player positions are continuously known even if world maps never merge.

---

## Finding 1: UWB Nearby Interaction — capabilities and limits

### 1a. Measurements delivered and iOS version requirements

`NISession` delivers a stream of `NINearbyObject` updates containing [2][34]:

- `discoveryToken` — peer identity
- `distance` — scalar meters, **nullable** (nil when out of range/LOS-failed)
- `direction` — `simd_float3` unit vector "pointing at the other device, relative to the local device itself," **nullable** (nil outside the directional field of view)
- iOS 16+ with camera assistance additionally yields `horizontalAngle` (1D azimuth in radians) and `verticalDirectionEstimate` (qualitative enum: above/below/same-level) [1]

Version timeline (vendor docs + press) [1][5][6][35]:

| iOS | Capability |
|---|---|
| 14 | NI introduced; iPhone 11+ (U1); **distance + direction** for iPhone-to-iPhone sessions |
| 15 | Apple Watch + third-party accessory support; NI permission prompt added |
| 16 | `deviceCapabilities` flags (`supportsPreciseDistanceMeasurement`, `supportsDirectionMeasurement`); **camera assistance** (`isCameraAssistanceEnabled`, `setARSession`); `horizontalAngle`/`verticalDirectionEstimate`; background NI for accessories |
| 17 | Extended Distance Measurement (EDM) on second-gen UWB (iPhone 15+); `activeExtendedDistanceSessionsLimitExceeded` error added [8] |

Note on the question's premise: direction was *not* iOS-16-only for iPhone↔iPhone — it shipped with iOS 14/U1 [2][35]. What iOS 16 added is camera-*assisted* direction (wider FoV) and the capability flags. However, developer reports indicate U2-chip iPhones may withhold direction without camera assistance (see 1c).

### 1b. Accuracy

- **Vendor/press claim**: cm-level; chipset makers advertise <±10 cm [9].
- **Independent measurement (academic)**: Heinrich et al. (arXiv 2303.11220) built a gimbal testbed and evaluated iPhone 12 Pro, Pixel 6 Pro, Galaxy S21 Ultra: **average distance error < 20 cm**, independent of orientation — but reliability (not accuracy) is the binding constraint: highly directional antennas + internal shielding caused the Pixel to fail ranging at 37.8% of tested orientations at 5 m [9].
- **Independent measurement (thesis)**: an Uppsala thesis on NI-constrained UWB for transit fare gates reports "single-digit centimeter mean absolute error under controlled placement," with device placement/body blocking as the real-world limiters [10].
- **AoA**: secondary technical reporting puts iPhone AoA accuracy around ±15° [28].
- **Range**: Apple docs say NI works best within **9 m**, portrait, back cameras facing [5]. Forum reports: ~5–10 m indoor to Qorvo/NXP accessories, 30–40 m to Estimote DW3000 beacons, 2–3 m through a car [11]. iPhone 15's U2 chip is claimed ~3× range with other gen-2 devices [11]; EDM (iOS 17) formalizes longer-range operation [8].

Assessment for a 4-player arena: ~10–20 cm distance noise and ±15°-class azimuth are **adequate to seed** an inter-device transform (error budget below), and NI keeps delivering peer positions continuously as a live fallback.

### 1c. Field-of-view and U2-chip caveats (important)

- Apple's own guidance: NI "works best when peer iPhone devices are within 9 meters, in portrait orientation, facing each other with their back camera" [5]. The direction FoV is a cone out of the back of the phone, "roughly correspond[ing] with the Ultra Wide camera's field of view" [2]. Outside it: `direction == nil` (distance may still update) [5].
- Qorvo forum testing with Apple's NI sample: iPhones stop reporting azimuth beyond roughly ±55°, and azimuth can wrap front-to-back (a sensor at 150° reads as 30°) — front/back ambiguity is only partially resolved by the z-sign [13].
- **U2 regression reports (self-reported, unresolved)**: on iPhone 15/16 Pro with third-party accessories, `direction` is *always* nil while distance works; capabilities report `supportsDirection: false` on U2 vs `true` on U1 iPhone 12 [12]. A separate thread claims that "for iPhones later than 15, the NI framework returns null for direction" and points to camera assistance as Apple's recommended path; iOS 27 adds Bluetooth Channel Sounding as a new finding mechanism [14]. **Treat direction on U2 devices as unverified until tested on your target hardware.** Camera assistance is the documented workaround.
- Camera assistance (iOS 16+) widens the effective FoV but only provides direction outside the narrow cone **after an initial encounter inside the narrow cone** [5] — i.e., players still must face each other once. It also requires `NSCameraUsageDescription` and imposes ARSession config constraints (see §3) [1][34].

### 1d. Session mechanics and multi-device limits

- Transport-agnostic bootstrap: exchange `NIDiscoveryToken`s over MultipeerConnectivity (Apple samples), Core Bluetooth, WatchConnectivity, or any custom server [8][35]. Apple's sample MPC layer is configured for up to 7–8 peers [15].
- **One `NISession` per peer** is the documented model: "One session represents an interaction between the user and a single nearby object. To interact with multiple nearby objects, create a separate session for each" [6]. WWDC20 explicitly diagrams **four devices each running three parallel sessions** — exactly the 4-player fully-connected topology [2].
- There is a hard cap surfaced as `NIError.activeSessionsLimitExceeded` (and `activeExtendedDistanceSessionsLimitExceeded` in iOS 17) [8]. The documented limit value is not published; WWDC20's 4×3 topology confirms ≥3 sessions/device is supported. A Stack Overflow report shows naively duplicating the one-peer sample invalidates both sessions — sessions must be managed per-peer in a dictionary [15].
- Peer-to-peer NI requires the app in the foreground (background mode exists only for BLE accessories, iOS 16+) [34]. Fine for a game.
- NI permission: one-time prompt on first `run()`; denial invalidates sessions with `NIError.userDidNotAllow` [5][7].

---

## Finding 2: Fusion feasibility — can UWB + ARKit pose derive the transform?

**Yes. This is solved in the literature and reduces to clean geometry under `.gravity` alignment.**

### 2a. Prior art (all read directly / from official abstracts)

- **LocAR / Cappella** (arXiv 2111.00174; NSF PAR 10346517): infrastructure-free 6-DOF relative localization for multi-user AR combining VIO with UWB ranges via a collaborative particle filter over sporadic peer messages. Explicitly works "even if users do not share the same field of view" — the exact failure mode of ARKit collaboration. Median 3D geometric error < 1 m across **5 users over 30,000 sq ft / 3 floors**; open-source UWB firmware + reference phone app [16][17].
- **SynchronizAR** (UIST 2019): "distance-based indirect registration" resolving transforms between independent SLAM frames by correlating each device's local trajectory with inter-device UWB distances — no maps, no infrastructure, designed for *spontaneous* AR collaboration precisely because map-sharing "requires the users to start roughly at the same position with common views" [18].
- **MDPI Sensors 19-04366** (ETHZ-adjacent UWB/V-SLAM work): a **linear solver for the 4-DOF relative pose** (x, y, z + yaw under shared gravity) needing a minimum of **six distance measurements** in 3D (five in 2D), vs ten for general 6-DOF; validated on HoloLens + Decawave UWB [19].
- **LUVI** (Ad Hoc Networks 2023): lightweight UWB-VIO relative positioning for AR-IoT using virtual anchors [20].

### 2b. The math — why one distance+direction sample suffices

Assume both devices run `.gravity` alignment (gravity-aligned y-axis, arbitrary yaw, arbitrary origin). The unknown transform T: W_A → W_B is then **4-DOF**: yaw θ + 3D translation t.

NI is bidirectional: A measures distance d and unit vector u_A (direction to B, in A's device frame); B measures d and u_B (direction to A, in B's device frame). Each device knows its own ARKit camera pose in its own world frame.

1. **Peer positions in each world frame**:
   - B's position in W_A: `p_B^A = camPos_A + camRot_A · (d · u_A)`
   - A's position in W_B: `p_A^B = camPos_B + camRot_B · (d · u_B)`
2. **Rotation**: the inter-device vector r = p_B − p_A is known in both frames (r^A from step 1, r^B = p_B^B − p_A^B). Since r^B = R(θ)·r^A and yaw preserves the vertical component, the horizontal components uniquely determine θ — **as long as the devices aren't vertically stacked** (horizontal component of r ≈ 0 is the single degenerate case; moving solves it).
3. **Translation**: t = p_A^B − R(θ)·p_A^A. Done. Closed-form, one instant.

(*Analysis — derivation from documented API semantics [2][5], consistent with the 4-DOF formulation in [19].*)

Distance-only variant: each range constrains the peer to a sphere; collecting ranges while players move gives the classic multilateration problem — the MDPI solver needs ≥6 ranges for a unique 4-DOF solution [19], and LocAR's particle filter handles it continuously [16]. `horizontalAngle`+distance+`verticalDirectionEstimate` (camera-assisted mode) is a middle tier: azimuth + qualitative elevation is enough for a coarse seed if full `direction` is unavailable.

### 2c. Error budget

With ~15 cm ranging noise and a peer baseline of ~3 m, the single-shot yaw error is roughly atan(0.15/3) ≈ 3°; translation error ~15–30 cm, plus ARKit drift and a small unknown constant offset between the NI antenna frame and the camera frame (calibrate once per device model). For a shooter rendering remote players this is acceptable as a seed; averaging a second or two of updates and cross-checking the 6 pairwise links shrinks it further. (*Inference from [9][10] error figures.*)

### 2d. The camera-assistance conflict (architectural gotcha)

To use camera-assisted NI with your own ARSession, Apple requires: `worldAlignment = .gravity`, **`isCollaborationEnabled = false`**, `userFaceTracking` off, nil `initialWorldMap`, and `sessionShouldAttemptRelocalization` returning false [1]. Only one ARSession can run per app [34]. Consequence: **camera-assisted NI and ARKit collaboration cannot coexist in the same session** — use camera assistance only during a bootstrap phase, or run plain NI (no ARSession dependency) concurrently with the collaborative ARSession.

---

## Finding 3: Non-visual (and minimal-visual) alternatives, ranked

| Rank | Method | Precision | Transform info | Verdict |
|---|---|---|---|---|
| 1 | **UWB NI distance+direction** | ~10–20 cm [9][10] | 4-DOF closed-form per §2b | Best all-around; built-in; continuous during play |
| 2 | **Optical handshake (QR on peer screen + PnP)** | cm-class at 1–3 m | **Full 6-DOF in one shot** | Excellent bootstrap fallback; see below |
| 3 | **UWB distance-only + motion** | ~10–20 cm | 4-DOF after ≥6 ranges or particle filter [16][19] | Fallback for direction-less (U2?) devices |
| 4 | **Acoustic chirp ToF** | 3–5 cm ranging @5 m (BeepBeep); ~1 m multi-device positioning [25] | ranges only → same as row 3 | Works but research-grade; audible/ultrasonic UX issues; no production precedent found |
| 5 | **BLE RSSI** | meter-scale; "not sufficient in real scenarios" [27] | none | Coarse presence check only [26][28] |
| 6 | **GPS + compass / `.gravityAndHeading`** | GPS ~5 m outdoors, useless indoors; compass 5–30°+ [30][31][32] | shared yaw only, erratic (90°/180° flips reported [30]) | Not viable for game-scale precision |

**Optical handshake detail** (the question's hint — confirmed): displaying a machine-readable code on device B's screen and detecting it in A's camera solves PnP on the screen corners → full 6-DOF pose of B's screen in A's camera frame. Since B's camera-to-screen transform is fixed and known, chaining with both devices' VIO poses yields the complete W_A↔W_B transform in one capture — no environment features needed at all. Evidence: **granted Snap patent US12243266** describes exactly this (QR encodes B's VIO pose; A decodes + aligns coordinate frames) [21]; a Taylor & Francis chapter synchronizes multi-device AR sessions via QR on the host screen [24]; GitHub implementations include chenditc/ARKit-Multiplayer (Vision + OpenCV QR pose for multiplayer ARKit) [22] and Philomath88/PnPQRCode (pure-Swift 6-DOF PnP on QR corners) [23]. Caveats: needs camera↔screen line of sight at ~1–3 m, screen-size/brightness bound range, and the Snap patent is a **legal flag** if shipping this verbatim (patent covers pose-encoded QR pairing; plain marker-pose bootstrap is older art — get counsel if concerned).

**Acoustic**: UW dissertation demonstrates software-only multi-pair acoustic ranging (Gold-coded chirps over speakers/mics + RF for timing) with few-cm range errors to 60 m and ~1 m positioning across 8 phones [25]; BeepBeep-style two-way ranging hits 3–5 cm at 5 m but doesn't scale past one pair [25]. MDPI's RATBILS shows 0.23–1.26 m indoor positioning [26]. Viable fallback ranging layer, but adds DSP work, audio UX, and still yields ranges only (→ same multilateration path as distance-only UWB).

**BLE RSSI**: measurement studies confirm distance estimates are unreliable under body shielding/NLOS; UWB strictly dominates [27][28]. Useful only as the token-exchange/discovery transport (which NI already supports via MPC or BLE).

**GPS/compass**: outdoor GPS gives meter-scale position and compass heading is erratic (IEEE/PMC studies report multi-degree MAE for magnetometer alignment; Stack Overflow reports 90°/180° world-axis flips under `.gravityAndHeading`) [30][31][32][33]. Cannot reach shooter-grade alignment; at best a coarse outdoor hint.

---

## Recommendation for the 4-player co-located shooter

**Architecture: NI-seeded transforms + ARKit collaboration as opportunistic refinement + live NI peer tracking.**

1. **Lobby/rendezvous phase (~3–5 s)**: all 4 players stand ~1–4 m apart and aim back cameras at each other (existing player-facing ritual: "point at your squad"). Each device runs 3 `NISession`s (the WWDC20-documented 4×3 topology [2]), exchanges `NIDiscoveryToken`s + camera poses over the existing MPC/transport layer.
2. **Solve**: each device computes peer positions in its world frame (§2b); share them; every device solves its transform to the elected host frame (or solves all 6 pairwise transforms and picks the median/consistent subset). Require ≥1 direction-bearing sample per pair; retry prompt otherwise.
3. **Runtime**: keep NI sessions running. Even before/if ARKit map merge completes, each device knows every peer's position in its own frame each update — remote players can be rendered immediately, and `ARParticipantAnchor` merges become a refinement rather than a prerequisite. Collaboration stays enabled in the game's own ARSession (NI peer sessions don't need it).
4. **U2 hedging**: test direction delivery on iPhone 15/16-class hardware early [12][14]. If `direction` is nil, two paths: (a) enable `isCameraAssistanceEnabled` during bootstrap only — but this forces `isCollaborationEnabled = false` on the shared ARSession, so sequence it *before* collaboration starts [1]; or (b) distance-only bootstrap: players take a few steps while ranging, then solve via ≥6-range least squares [19] or a LocAR-style particle filter [16].
5. **Fallback ritual**: optical QR handshake — instant 6-DOF solve, immune to UWB FoV/U2 issues, needs only screen↔camera LOS [21][23][24]. Cheap to implement with Vision barcode detection + PnP [22][23].
6. **Reject** for this use case: BLE RSSI alignment, GPS/compass seeding (indoors), acoustic ranging (unproven in production, adds DSP surface area).

Residual risks: unpublished max-session count (3/peer is documented-safe), the U2 direction regression, the small camera↔UWB-antenna extrinsic (calibrate per device class), and NI permission flow in onboarding.

---

## Coverage Status

- **Checked directly**: Apple NI docs (NISession, NINearbyPeerConfiguration, session lifecycle, precision-finding sample), WWDC19/20/21/22 transcripts, arXiv 2303.11220, LocAR/Cappella abstracts, SynchronizAR abstract, MDPI 19-04366 abstract, Snap patent claims, dev-forum/SO/Qorvo threads, gravityAndHeading docs.
- **Inferred (labeled above)**: closed-form 4-DOF derivation (my own math from documented API semantics); error-budget figures extrapolated from [9][10]; acoustic/BLE comparative ranking.
- **Unresolved / needs device testing**: exact `activeSessionsLimitExceeded` value; whether U2 iPhones deliver `direction` to peer *iPhones* (not just accessories) without camera assistance; NI-antenna↔camera extrinsic magnitude; whether single NISession running multiple configs is officially supported (docs still say one-session-per-peer [6]).
- **Not completed**: no production co-located AR *game* using NI was found — usage appears limited to accessory demos (NXP Trimensions AR [37], Qorvo NI app) and research prototypes; treat "proven in production" as unestablished.

---

## References

### Vendor documentation / WWDC (primary, vendor claims)

1. Apple — WWDC22, "What's new in Nearby Interaction" (camera assistance, horizontalAngle, verticalDirectionEstimate, ARSession config constraints) — https://developer.apple.com/videos/play/wwdc2022/10008/
2. Apple — WWDC20, "Meet Nearby Interaction" (distance+direction semantics, FoV cone, 4 devices × 3 sessions) — https://developer.apple.com/videos/play/wwdc2020/10668/
3. Apple — WWDC21, "Explore Nearby Interaction with third-party accessories" — https://developer.apple.com/videos/play/wwdc2021/10165/
4. Apple — WWDC19, "Building Collaborative AR Experiences" (collaboration/merge mechanics) — https://developer.apple.com/videos/play/wwdc2019/610/
5. Apple — "Initiating and maintaining a session" (9 m/portrait/back-camera guidance, nil semantics, camera-assist LOS rule, capability flags) — mirror: https://apple-docs.everest.mt/docs/nearbyinteraction/initiating-and-maintaining-a-session/
6. Apple — NISession documentation ("one session … a single nearby object … create a separate session for each") — https://developer.apple.com/documentation/nearbyinteraction/nisession
7. Apple — NINearbyPeerConfiguration documentation (isCameraAssistanceEnabled, EDM, setARSession) — https://developer.apple.com/documentation/nearbyinteraction/ninearbypeerconfiguration
8. Apple — Sample code: "Finding devices with precision" (ARKit+NI ranging, EDM, MPC token exchange, error enums) — https://developer.apple.com/documentation/nearbyinteraction/finding-devices-with-precision
34. WWDCNotes — "What's new in Nearby Interaction" summary (single-ARSession constraint, background mode keys) — https://wwdcnotes.com/documentation/wwdc22-10008-whats-new-in-nearby-interaction/
36. Apple — "Creating a collaborative session" (collaboration data, world-map merging requirements) — mirror: https://apple-docs.everest.mt/docs/arkit/creating-a-collaborative-session/

### Independent measurements / academic (primary research)

9. Heinrich et al. — "Smartphones with UWB: Evaluating the Accuracy and Reliability of UWB Ranging" (arXiv 2303.11220; <20 cm error, orientation-dependent failures) — https://arxiv.org/pdf/2303.11220
10. Jutterström — Uppsala Univ. thesis, "UWB Fare Validation Under Apple Nearby Interaction Constraints" (single-digit-cm under controlled placement; body/placement limits) — https://uu.diva-portal.org/smash/get/diva2:2069308/FULLTEXT01.pdf
16. LocAR — "Multi-User Augmented Reality with Infrastructure-free Collaborative Localization" (arXiv 2111.00174; VIO+UWB particle filter, <1 m median error, 5 users/3 floors) — https://doi.org/10.48550/arxiv.2111.00174
17. Cappella — same system, NSF public-access version — https://par.nsf.gov/servlets/purl/10346517
18. SynchronizAR — "Instant Synchronization for Spontaneous and Spatial Collaborations in AR" (distance-based registration of independent SLAM frames) — https://scispace.com/pdf/synchronizar-instant-synchronization-for-spontaneous-and-2nhaha8uzd.pdf
19. MDPI Sensors 19-04366 — "Unique 4-DOF Relative Pose Estimation with Six Distances for UWB/V-SLAM-Based Devices" — https://mdpi-res.com/d_attachment/sensors/sensors-19-04366/article_deploy/sensors-19-04366-v2.pdf
20. LUVI — "Lightweight UWB-VIO based relative positioning for AR-IoT applications" (Ad Hoc Networks 2023) — https://doi.org/10.1016/j.adhoc.2023.103132
25. UW dissertation — "Toward an Accurate Acoustic Localization System" (Gold-coded chirps; few-cm ranging to 60 m; ~1 m positioning; BeepBeep 3–5 cm @5 m) — http://hdl.handle.net/1773/44688
26. MDPI Sensors 24-6332 — RATBILS acoustic chirp positioning (0.23–1.26 m indoor error) — https://www.mdpi.com/1424-8220/24/19/6332
27. arXiv 2101.09075 — "Distance Estimation for Contact Tracing: BLE vs UWB" (BLE insufficient in real scenarios) — https://arxiv.org/html/2101.09075v1
31. IEEE Sensors Letters — "Fast-Alignment of AR Headset From Local to Geodetic Coordinate Frame" (magnetometer alignment MAE ~4–5× worse than proposed method) — https://doi.org/10.1109/lsens.2025.3526597
32. PMC10893312 — outdoor LAR anchor precision (GPS+compass insufficient for precise AR anchors) — https://pmc.ncbi.nlm.nih.gov/articles/PMC10893312/
39. Remote Sensing 15-3709 — rotation-invariant outdoor AR geo-registration (RTK+VIO heading) — https://doi.org/10.3390/rs15153709

### Optical handshake (patent + implementations)

21. Snap Inc. — US Patent 12,243,266, "Device pairing using machine-readable optical label" (QR encodes VIO pose; PnP-based frame alignment) — https://patents.us/US12243266
22. GitHub — chenditc/ARKit-Multiplayer (Vision QR tracking + pose for multiplayer ARKit) — https://github.com/chenditc/ARKit-Multiplayer/
23. GitHub — Philomath88/PnPQRCode (pure-Swift 6-DOF PnP on QR corners) — https://github.com/Philomath88/PnPQRCode
24. Taylor & Francis chapter — QR code as shared reference point for multi-device AR session sync — https://api.taylorfrancis.com/content/chapters/oa-edit/download?identifierName=doi&identifierValue=10.1201%2F9781003559085-110&type=chapterpdf

### Developer reports (self-reported / secondary)

11. Apple Dev Forums #744326 — NI range reports (5–10 m indoor accessories, 30–40 m Estimote, U2 3× claim) — https://developer.apple.com/forums/thread/744326
12. Apple Dev Forums #802948 — direction always nil on U2 iPhones w/ accessories; capability dumps U1 vs U2 — https://origin-devforums.apple.com/forums/thread/802948
13. Qorvo forum — front-back azimuth ambiguity; azimuth drops beyond ~±55° — https://forum.qorvo.com/t/front-back-ambiguity-in-azimuth-estimates-on-the-nearby-interaction-app-with-dwm3001cdk/23661
14. Apple Dev Forums #834696 — post-iPhone-15 direction null reports; BT Channel Sounding (iOS 27) — https://developer.apple.com/forums/thread/834696
15. Stack Overflow — multiple simultaneous NISessions (per-peer session management) — https://stackoverflow.com/questions/66287186/how-to-connect-multiple-devices-implement-multiple-ongoing-sessions-using-appl
28. newly.app — UWB mobile-apps field guide (<30 cm, ±15° AoA, ~10 m indoor, 1–3 Hz cadence) — https://newly.app/sensors/uwb-mobile-apps
29. Apple — ARConfiguration.WorldAlignment.gravityAndHeading doc — mirror: https://apple-docs.everest.mt/docs/arkit/arconfiguration/worldalignment-swift.enum/gravityandheading/
30. Stack Overflow — erratic gravityAndHeading origins (90°/180° flips) — https://stackoverflow.com/questions/44896627/erratic-world-origin-alignment-for-arsessionconfiguration-worldalignment-grav
33. Niantic Spatial community — compass API unreliability for AR alignment — https://community.nianticspatial.com/t/proper-way-to-get-compass-heading/2156
35. Medium (itsmeichigo) — SwiftUI NI peer-location tutorial (transport options, API flow) — https://levelup.gitconnected.com/swiftui-locate-peers-with-nearby-interaction-framework-4b799e0dbf39
37. App Store — NXP Trimensions AR (NI + UWB accessory locator demo) — https://apps.apple.com/us/app/nxp-trimensions-ar/id1606143205
38. CEUR Vol-3248 paper15 — BLE RSSI vs UWB range as training data (RSSI path-loss limits) — https://ceur-ws.org/Vol-3248/paper15.pdf
