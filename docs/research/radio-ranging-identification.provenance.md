# Provenance: Radio ranging as an opponent-identity signal (BIO-37)

Companion to [radio-ranging-identification.md](radio-ranging-identification.md).

## Date, scope, mode

- Research date: 2026-09-27 (single sprint, read-only). Repository state: `main` @ `3d89b7f`, clean working tree. No code, branch, commit, PR, or deploy.
- Tracking: [BIO-37](https://linear.app/biossphere/issue/BIO-37). Predecessor: BIO-36 synthesis and seven briefs in `docs/research/` (read in full before starting; not repeated).
- Product decisions taken as given from the owner: shared-frame / Saved Arena / rendezvous removed entirely; Quick Duel (ADR 0013) is the only mode; start is never gated; target roster 2–4.

## Rounds

1. **Predecessor and style read** — `zero-step-architecture-synthesis.md`, `shared-arena-frame-options.md` (+ provenance) for format, and the NI Option C section so its shared-frame framing could be explicitly superseded rather than repeated.
2. **Repository verification** — identity path (`RealtimeBodyAssociation.swift` `associateSighting` and legacy `associate`), authority gates (`combat-simulation/src/index.ts` `ambiguousTarget`, `noSighting`, `COVER_OBSERVATION_MS`), wire types (`combat-protocol` `BodyObservation`, `niToken`, `niTokenBytes`), Worker token relay (`room.ts` `niTokens`), targeting session AR configuration choice (`TargetingSession.swift` `usesBodyTracking`, `ARBodyTrackingConfiguration` vs `ARWorldTrackingConfiguration` + `VNDetectHumanBodyPoseRequest`), existing NI stack (`NearbySessionManager.swift`, `NearbyRendezvousPolicy.swift`, `NearbyRendezvous.swift`, `RealtimeArenaController.swift` `usesNearbyRendezvous`), `Info.plist` usage strings, Convex `GAMEPLAY.maxPlayers = 2`, `docs/build-log.md` for NI device evidence (none).
3. **Apple primary re-read** — NI articles and API reference pages listed as sources 1–15 and 19–21, fetched 2026-09-27; WWDC20 10668 and WWDC22 10008 transcripts read from Apple's video pages.
4. **Secondary check** — academic/practitioner figures for update rate and ranging error carried over from the predecessor's accepted list (sources 16–18), re-labelled and re-scoped: none measure moving-phone *direction* accuracy.
5. **Synthesis** — camera-ray + device-relative UWB bearing association in the shooter's own frame; Camera Assistance conflict with `ARBodyTrackingConfiguration`; RSSI rejection; non-UWB floor; device-experiment list.

## Sources consulted and accepted

Apple primary (accepted as confirmed evidence): sources 1–15, 19–21 in the brief — Initiating and maintaining a session; `NIDeviceCapability`; UWB availability support article (published 2026-03-27); Finding devices with precision sample; `NIError.Code`; WWDC20 10668 transcript; `MCSession`; Discovering peers with Multipeer Connectivity; `sessionWasSuspended(_:)`; WWDC22 10008 transcript; `NINearbyObject`; `NINearbyPeerConfiguration`; `isCameraAssistanceEnabled`; `NIAlgorithmConvergence`; `setARSession(_:)`; `CBPeripheral.readRSSI()`; `centralManager(_:didDiscover:advertisementData:rssi:)`; Core Bluetooth Background Processing (archive).

Non-Apple (accepted with labels): SmartPoser (UIST 2023) **[academic]** for ≈ 5 Hz NI update rate; Jutterström 2026 **[academic]** summarising Heinrich et al. < 20 cm UWB ranging error; Apple Developer Forums thread 744326 **[practitioner]** for range anecdotes.

Repository (accepted as confirmed for code-level claims only): files listed under "Repository evidence" in the brief.

## Sources consulted and rejected / not used

- `NINearbyObject.direction`, `horizontalAngle`, `verticalDirectionEstimate`, `NISession.worldTransform(for:)`, `NIError.Code.resourceUsageTimeout` individual reference pages — fetched but returned empty bodies (JavaScript-rendered); their content is instead cited from the parent `NINearbyObject` / `NIError.Code` pages and the WWDC transcripts, which carry the same statements.
- objc2-nearby-interaction Rust bindings (predecessor source 35) — not needed; the Apple `NIError.Code` page already establishes that no numeric session cap is published.
- SynchronizAR / Cappella (predecessor sources 27–28) — shared-frame registration papers; out of scope now that alignment is removed.
- Generic "BLE RSSI distance estimation" blog posts and vendor whitepapers — not Apple-primary and not iPhone-to-iPhone; the RSSI conclusion rests on Apple's API surface (signal strength only, no distance/bearing API) plus labelled inference.
- Third-party claims that specific iPhone models lack direction support — not adopted; Apple publishes only the runtime `supportsDirectionMeasurement` check, so per-model direction support is stated as an absence.

## Verification performed

- Every repository statement in §2 of the brief was checked by reading the named file on `main` @ `3d89b7f` (constants: 0.1 s skeleton age, 0.8 confidence, 0.45 m / 0.35 m legacy margins, `maximumPeers = 3`, 40-sample window, 6 s sample age, 0.25 s solve interval, `niTokenBytes: 4096`, `COVER_OBSERVATION_MS = 1000`, `uncertaintyMeters > 0.1`, `maxPlayers: 2`).
- Apple quotations were taken verbatim from fetched page text or transcripts on 2026-09-27; paraphrases retain Apple's qualifiers ("works best", "best used for", "roughly corresponds").
- Source numbering in the brief was checked to resolve 1–21 with no dangling references.
- The geometric claim "1 m lateral separation at 6 m ≈ 9.5°" is arithmetic (atan(1/6)); it is marked inference because real body/phone positions differ.

## Known limits

- **No physical-device evidence.** No iPhone was used. Direction availability, angular error, concurrent-session behaviour, update rate, thermal and battery cost, and the `ARBodyTrackingConfiguration` + Camera Assistance interaction are all listed as unmeasured in brief §6. Nothing in the brief may be cited in `docs/build-log.md` as device evidence.
- **Apple absences remain absences:** no numeric concurrent-session cap, no per-model direction table, no accuracy/rate/power figures for iPhone-to-iPhone NI, no documented behaviour for a body-tracking ARSession handed to NI.
- **Non-Apple figures are indicative only**; they were measured with different devices, indoors or with accessories, and never for two moving hand-held phones.
- **Permission semantics** differ between the WWDC20 description (one-time until app exit) and the current article (persisted in Settings); the brief follows the current article and flags the difference.
- **Regional and fleet assumptions** (Victoria, BC; owner-supplied phones) are inference; the support article's regional list is the confirmed part.
- The association rule in §4.2, the fallback ranking in §5 and every threshold are proposals for device experiments, not measured behaviour; the simulation, Convex and client changes they imply are listed as dependencies and were not designed or implemented.
