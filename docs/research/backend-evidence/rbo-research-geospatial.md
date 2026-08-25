# Street-Scale / Open-World Shared AR on iPhone — 2025-2026 Infrastructure

Research date: 2026-04-30. This note collects primary-source evidence for persistent, shared, real-world AR infrastructure that works on iOS.

## Bottom line

- There is **no single out-of-the-box “street-scale shared AR coordinate space”** on iPhone.
- Apple’s ARKit gives **per-device geo-anchors** (`ARGeoAnchor`) in selected metro areas, but no built-in networking or shared world state.
- Google’s **ARCore Geospatial API** runs on iOS and lets an app place WGS84/Terrain/Rooftop anchors anywhere Google Street View covers; sharing is app-level (server-persisted anchor IDs/coordinates) rather than a built-in multiplayer session.
- **Niantic Spatial NSDK 4.x** is the current Niantic platform; it supports native iOS (Swift) and Unity, offers **VPS2** coarse + precise localization against scanned “Sites,” and supports persistent / shared anchors. The old **Lightship.dev / Geospatial Browser is deprecated** and **SharedAR was removed** in 2026.
- Room-scale sharing bridges are **ARKit Collaborative Sessions** (≤4 participants, app-provided network) and **ARCore Cloud Anchors** (iOS/Android, 24 h–365 d TTL, 30 host/300 resolve requests/min).
- Other players: **Immersal (Hexagon)** for custom VPS maps; **Augmented.City** city-scale AR cloud; **Snap Lens Studio Landmarkers / Custom Location AR** inside Snapchat/Camera Kit.

## Evidence table

| # | Claim | Source URL | Read / Inferred |
|---|-------|------------|-----------------|
| 1 | Apple `ARGeoTrackingConfiguration` requires an A12-or-later iOS/iPadOS device with cellular (GPS) capability; works outdoors only; needs internet. | https://developer.apple.com/documentation/arkit/argeotrackingconfiguration | read-directly |
| 2 | Apple location anchors (`ARGeoAnchor`) are available only in geo-tracking sessions; must be within ~5 km (0.05°) of the user; use Apple Maps “localization imagery” downloaded over the network. | https://developer.apple.com/documentation/arkit/argeoanchor | read-directly |
| 3 | Apple geo-tracking accuracy is reported as `high`, `medium`, `low`, or `undetermined`; no public meter-level accuracy guarantee. | https://developer.apple.com/documentation/arkit/argeotrackingstatus/accuracy-swift.enum | read-directly |
| 4 | ARKit collaborative sessions “work best with up to four participants”; the app must send collaboration data over its own network; peer-to-peer world data. | https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/3552254-iscollaborationenabled | read-directly |
| 5 | Google ARCore Geospatial API attaches content to any area covered by Google Street View; uses Visual Positioning System (VPS) for localization; WGS84/Terrain/Rooftop anchors. | https://developers.google.com/ar/develop/geospatial | read-directly |
| 6 | ARCore Geospatial iOS quickstart: Xcode 13.0+, Cocoapods 1.4.0+, ARKit-compatible iOS device running iOS 12.0+. | https://developers.google.com/ar/develop/ios/geospatial/quickstart | read-directly |
| 7 | ARCore iOS SDK is actively maintained; latest release 1.54.0 (Apr 2026). | https://github.com/google-ar/arcore-ios-sdk/releases | read-directly |
| 8 | Geospatial API quota: 1,000 sessions started per minute or 100,000 requests per minute per project. | https://developers.google.com/ar/develop/ios/geospatial/api-usage-quota | read-directly |
| 9 | ARCore Additional Terms: cannot use Cloud Anchors/Geospatial API in child-directed apps; cannot re-create Google products/features. | https://developers.google.com/ar/develop/terms | read-directly |
| 10 | ARCore Cloud Anchors support Android and iOS; API key auth gives max 24 h TTL; keyless auth up to 365 d; host quota 30/min, resolve quota 300/min per IP/project; unlimited anchors. | https://developers.google.com/ar/develop/ios/cloud-anchors/developer-guide | read-directly |
| 11 | Cloud Anchor Management API supports updating `expireTime` up to `maximumExpireTime` (one year after creation). | https://developers.google.com/ar/develop/cloud-anchors/management-api | read-directly |
| 12 | Cloud Anchor deprecation policy: one-year notice if Google discontinues the Cloud Anchor service introduced in ARCore 1.12.0. | https://developers.google.com/ar/develop/cloud-anchors/cloud-anchor-deprecation-policy | read-directly |
| 13 | Niantic Labs consumer-games site is now “Scopely Explore, formerly known as Niantic.” | https://nianticlabs.com | read-directly |
| 14 | Niantic Spatial is the remaining company, focused on “real-world foundation models for physical AI” and a Visual Positioning System. | https://nianticspatial.com | read-directly |
| 15 | Niantic Spatial VPS: global coverage, 3DOF and 6DOF localization, private mapping integration, secure private spaces. | https://nianticspatial.com/vps | read-directly |
| 16 | Niantic Spatial pricing: credit-based; Free 20k/mo, Plus $20/mo, Pro $50/mo, Enterprise custom; a VPS localization query costs 12 credits. | https://nianticspatial.com/pricing | read-directly |
| 17 | Niantic Spatial SDK (NSDK) 4.1.0 supports Unity, Swift (iOS), and Kotlin (Android); requires iOS 14.0+ (Unity) or Xcode 12.0+ / ARKit (Swift). | https://www.nianticspatial.com/docs/llms-nsdk/downloads.txt and https://www.nianticspatial.com/docs/llms-nsdk/setup.txt | read-directly |
| 18 | Niantic Spatial migration guide: legacy Lightship.dev and ARDK 3.x are deprecated; migrate to Scaniverse + NSDK 4.0; SharedAR no longer functional as of May 1 2026; Lightship.dev decommissioned Feb 20 2027. | https://www.nianticspatial.com/docs/llms-nsdk/migration_guide.txt | read-directly |
| 19 | Niantic VPS2: Coarse (global GPS + cloud geopositioning) and Precise (6DOF pose against a processed VPS map) modes; anchors support persistent and shared AR experiences. | https://www.nianticspatial.com/docs/llms-nsdk/features/vps2.txt | read-directly |
| 20 | Niantic VPS is described as centimeter-level accurate; Pokémon GO “Playgrounds” experiment places persistent Pokémon at specific locations for others to see. | https://nianticspatial.com/blog/largegeospatialmodel | read-directly |
| 21 | Niantic consumer-game privacy policy: games allow players to view/interact with the same virtual objects in a shared physical space and leave persistent virtual objects; location determined via GPS/Wi-Fi/cell tower. | https://www.nianticspatial.com/privacy-consumer-games | read-directly |
| 22 | Niantic old “Google Cloud” post: Pokémon GO’s “real-time shared world” was built on Google Cloud Datastore, scaled >50× projections. | https://web.archive.org/web/2022/https://nianticlabs.com/blog/googlecloud | read-directly (archival) |
| 23 | Niantic old dev-insights post: Pokémon GO “Shared AR Experience” used emerging shared AR technology for players to make memories with Buddy Pokémon. | https://web.archive.org/web/2022/https://nianticlabs.com/blog/devinsights-buddyadventuresharedar | read-directly (archival) |
| 24 | Snap Custom Location AR lets creators map a location, get a Location ID, and author AR content for that location; part of Lens Cloud; targets structures up to ~3 m. | https://developers.snap.com/lens-studio/features/location-ar/custom-landmarker | read-directly |
| 25 | Snap City-Scale AR template: supports selected regions of London, Downtown Los Angeles, and Santa Monica. | https://developers.snap.com/lens-studio/features/location-ar/city-landmarker | read-directly |
| 26 | Immersal (Hexagon) offers visual positioning for indoor/outdoor/city-scale maps; free up to 100 images/map, Pro $99/mo, Enterprise custom. | https://www.immersal.com and https://immersal.com/pricing | read-directly |
| 27 | Augmented.City is an AR cloud / platform ecosystem for city-scale capture, enrichment, and visualization on smartphones. | https://augmented.city | read-directly |
| 28 | Google S2 geometry library provides hierarchical spatial indexing on a sphere using S2 cells. | https://s2geometry.io | read-directly |
| 29 | Apple ARWorldTrackingConfiguration tracks 6DOF and supports plane detection, image detection, object detection. | https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration | read-directly |

## Findings by platform

### 1. Apple ARKit — `ARGeoAnchor` / GeoTracking (iOS 14+)

- **What it is:** A system-level API for placing “location anchors” at a lat/lon/(alt) coordinate and getting a local AR transform [1][2].
- **Capabilities:** Anchors align to an East-North-Up local frame; ARKit updates their transform as the user moves. Supports `ARGeoTrackingConfiguration` (not regular `ARWorldTrackingConfiguration`) [1][2].
- **Device requirements:** iOS 14.0+, iPadOS 14.0+; A12 Bionic or later; **cellular (GPS) capability** [1].
- **Coverage:** Available in “specific areas in over 20 countries, including many metropolitan areas in Australia, Europe, Japan, and North America.” The docs do **not** enumerate supported cities; availability must be checked at runtime with `checkAvailability(at:)` or `checkAvailability(completionHandler:)` [1].
- **Outdoor requirements:** Geo-tracking “occurs exclusively outdoors.” Uses “localization imagery” (street-level photos) from Apple Maps; public streets and car-accessible routes only [1][2].
- **Accuracy:** No numeric guarantee; `ARGeoTrackingStatus.Accuracy` reports `high`, `medium`, `low`, or `undetermined` [3]. Apple explicitly says apps should adapt UI based on accuracy level.
- **Shared / persistent?** No built-in sharing or persistence. Each iPhone creates its own geo-anchor; the app can share the lat/lon/alt via its own backend. For room-scale sharing, ARKit Collaborative Sessions support **up to four participants** with app-provided networking, but this is not street-scale [4].
- **Cost:** No Apple developer fee for using the API; users may incur mobile data usage for localization imagery [2].

### 2. Google ARCore — Geospatial API on iOS

- **What it is:** The ARCore SDK for iOS exposes the Geospatial API. It fuses device sensors, GPS, and Google’s **Visual Positioning System (VPS)** — built from Street View imagery and a global 3D point cloud — to place content at lat/lon/alt [5].
- **Capabilities:** Three anchor types: **WGS84** (ellipsoidal altitude), **Terrain** (altitude relative to ground), and **Rooftop** (altitude relative to building top) [5].
- **iOS availability:** Yes. ARCore SDK for iOS is actively maintained (release 1.54.0 as of Apr 2026) [7]. Quickstart requires **Xcode 13.0+, Cocoapods 1.4.0+, ARKit-compatible iOS device running iOS 12.0+** [6].
- **Coverage:** “Any area covered by Google Street View” — the localization model consists of trillions of points and “spans nearly all countries, with future coverage” [5]. VPS availability can be checked at runtime with `GARSession checkVPSAvailabilityAtCoordinate:` [5].
- **Accuracy:** Google states VPS is “much more accurate than GPS alone” and that with it “you won’t have to worry about your virtual objects jumping around.” The iOS pose page describes yaw uncertainty via `orientationYawAccuracy` in degrees; no public meter-level number is given [5].
- **Quotas / pricing:** Per project: **1,000 sessions started per minute** or **100,000 requests per minute** [8]. No published per-query price for Geospatial — usage is free within quota.
- **Terms:** Cannot use Cloud Anchors or Geospatial API in child-directed (COPPA) apps; cannot “re-create” Google products/features such as Google Maps Live View; must disclose Google data-use terms [9].
- **Shared / persistent?** Persistent anchors are not Cloud Anchors here; the app persists a Geospatial anchor’s lat/lon/alt and recreates it locally on each device. Multi-user sharing is app-level (share anchor coordinates/IDs through your own backend). Cloud Anchors (below) can bridge room-scale sharing.

### 3. ARCore Cloud Anchors — room-scale sharing on iOS

- **What it is:** Host a local AR anchor in the ARCore cloud and resolve it on another iOS/Android device in the same physical space [10][11].
- **iOS support:** Yes; works on all ARCore-supported devices, which includes ARKit-compatible iOS devices [12].
- **Hosting limits:**
  - With **API-key auth**: max TTL **24 hours** [10].
  - With **keyless auth**: TTL up to **365 days** [10][11].
  - Quotas: **30 host requests/minute** and **300 resolve requests/minute** per IP and project; number of anchors unlimited [10].
- **Deprecation status:** Not deprecated. Deprecation policy says Google will give a one-year notice via release notes if it discontinues the Cloud Anchor service introduced in ARCore 1.12.0 [12].
- **Scale:** Room-scale, not street-scale. Cloud Anchors are “best used for room-scale AR experiences” [10].

### 4. Niantic Spatial / NSDK (formerly Lightship)

- **Corporate status:** Niantic sold/transitioned its consumer games business; `nianticlabs.com` now reads **“Scopely Explore, formerly known as Niantic”** [13]. The remaining entity is **Niantic Spatial, Inc.**, focused on physical-AI foundation models, Scaniverse, and VPS [14].
- **Product status:**
  - **Lightship.dev and the Geospatial Browser are deprecated.** Niantic is migrating content to **Scaniverse**; self-serve migration opened Feb 2026 and Lightship.dev will be decommissioned Feb 2027 [18].
  - **NSDK 3.17** receives only critical bug/security fixes through Feb 2027; **NSDK 4.0** is the current release [18].
  - **SharedAR was removed as of May 1, 2026** [18].
- **SDK platforms:** NSDK 4.1.0 supports **Unity, native iOS (Swift / Xcode package), and native Android (Kotlin/AAR)** [17]. For Unity, iOS 14.0+; for Swift, Xcode 12.0+ and an ARKit iOS device [17].
- **VPS2 capabilities:**
  - **Coarse localization:** Global geoposition and heading using GPS + magnetometer (local) or optional cloud geopositioning; no VPS map needed [19].
  - **Precise localization:** 6DOF pose relative to a processed **VPS map / Site**; supports “persistent and shared AR experiences” via Site anchors [19].
  - Cloud geopositioning can take 60 s on cold start; until first response, accuracy is standard GPS [19].
- **Coverage:** Niantic claims **global outdoor, mapped indoor, and GPS-denied environments**, with a “continually growing network of pre-mapped locations worldwide” and private map integration [15]. For precise localization, the **Site must have been scanned and processed** in Scaniverse [19].
- **Accuracy:** Niantic’s public blog states VPS can position devices with **centimeter-level accuracy** [20].
- **Pricing / costs:** Scaniverse / Niantic Spatial is credit-based. Plans: **Free** ($0, 20k credits/mo), **Plus** ($20/mo, 40k credits), **Pro** ($50/mo, 105k credits), **Enterprise** custom [16]. A **VPS localization query costs 12 credits**, so the included free tier is ~1,500 queries/mo, Plus ~3,000, Pro ~9,000 [16]. Commercial use requires Pro or Enterprise.
- **Shared / persistent on iPhone:** With NSDK a Swift iOS app can track Site anchors that are persistent and shared across devices at the same Site. Real-time multiplayer must be implemented by the app; the old built-in SharedAR is gone [18][19].

### 5. Shared/multiplayer room-scale tech

- **ARKit Collaborative Sessions:** Built-in world-map sharing; up to **4 participants**; app provides the network; best on same OS version [4].
- **ARCore Cloud Anchors:** Cross-platform iOS/Android; host/resolve room-scale anchors; TTL 24 h–365 d; quotas as above [10][11].
- Neither is designed for kilometer-scale, open-world sharing. They bridge to street scale only when combined with a global localization layer (Geospatial API, VPS, or GPS+server). A typical architecture is: (1) global layer gives each phone a world-aligned pose; (2) app persists a geo-referenced content list; (3) each client places the same anchors locally.

### 6. Other credible players (one-line status)

- **Immersal (Hexagon)** — commercial visual-positioning provider for indoor/outdoor/stadium/city-scale maps; SDK for Unity, mobile AR, headsets; free tier up to 100 images/map, Pro $99/mo, Enterprise custom [26][27].
- **Augmented.City** — Italian AR-cloud platform for city-scale capture and visualization on smartphones; website lists partner countries but no detailed public pricing/SDK status [28].
- **Snap Lens Studio Landmarkers / Custom Location AR** — location-based AR inside Snapchat / Camera Kit. **Custom Location AR** lets creators scan a small location (≤ ~3 m structures) and get a Location ID to build a Lens [24]. **City Landmarker** supports selected city regions of London, Downtown Los Angeles, and Santa Monica [25]. Not a general-purpose iPhone native SDK.

### 7. Precedents — Niantic games and shared real-world state

- Niantic’s consumer games maintain a **server-side, location-indexed shared state**: players see the same virtual objects tied to real-world places, leave persistent objects, and the platform uses GPS, Wi-Fi, and cell-tower location [21].
- Pokémon GO was described as a **“real-time shared world … running on Google Cloud Datastore at more than fifty times our original projections”** [22].
- A Pokémon GO “Shared AR Experience” (Buddy Adventure) used **shared AR** so multiple players could see the same Buddy Pokémon together, demonstrating Niantic’s client-side shared-AR networking [23].
- The **Google S2 geometry library** provides the canonical hierarchical spatial-cell system used for many large-scale geospatial indexes, including possible use in Niantic’s backend, but a primary source confirming S2 inside Niantic’s game server stack was **not found** in this research [28].

## Capabilities, coverage, costs summary

| Platform | iPhone native? | Shared persistent AR? | Coverage | Cost (public tiers) |
|----------|---------------|------------------------|----------|---------------------|
| ARKit `ARGeoAnchor` | Yes (iOS 14+) | No (per-device, app must share) | 20+ countries, selected metros, outdoors only | Free (user data) |
| ARCore Geospatial iOS | Yes (SDK) | App-level (server-persisted IDs) | Any Google Street View area | Free within quota |
| ARCore Cloud Anchors | Yes | Yes, room-scale, 24 h–365 d | Same physical space only | Free within quota |
| Niantic Spatial NSDK | Yes (Swift + Unity) | Yes via VPS2 Site anchors, but no built-in SharedAR | Global coarse; precise needs scanned Sites | Credit-based, $0–$50+/mo |
| Snap Landmarkers | Camera Kit / Snapchat | Within Snapchat/Lens Cloud | Custom locations; city template limited to London/LA/Santa Monica | Free creator tools; commercial restrictions |
| Immersal | SDK (Unity, mobile, headset) | Custom VPS maps | User-mapped spaces | Free / $99 / Enterprise |
| Augmented.City | Web / app? | AR cloud | Partner cities / user-captured | Not public |

## Coverage status

- **Checked directly:** Apple ARKit geo-tracking docs; ARCore Geospatial/Cloud Anchors docs and iOS quickstart; Niantic Spatial website, pricing, NSDK 4.x docs (LLM text), migration guide, VPS2 docs; Snap Lens Studio location-AR docs; Immersal and Augmented.City home/pricing; S2 geometry library; Niantic historical blog posts via Wayback; ARCore iOS SDK GitHub releases.
- **Read directly but with caveats:** Some Google ARCore numbers (yaw accuracy) are not meter-level. Niantic historical blog posts are archived 2018–2021 and describe the pre-split company; current product is Niantic Spatial.
- **Remaining uncertain / not found in primary sources:**
  - A public, enumerated list of **Apple-supported cities** for `ARGeoAnchor` (Apple only describes “over 20 countries / many metropolitan areas” and a runtime API).
  - A public, numeric **meter-level accuracy** figure for either Apple GeoTracking or ARCore Geospatial.
  - A primary Niantic source explicitly stating use of **S2 cells** in Pokémon GO/Ingress server-side state; the S2 library is cited as the canonical cell scheme, but Niantic’s internal use is inferred, not directly read.

---

Sources

1. Apple — `ARGeoTrackingConfiguration` — https://developer.apple.com/documentation/arkit/argeotrackingconfiguration
2. Apple — `ARGeoAnchor` — https://developer.apple.com/documentation/arkit/argeoanchor
3. Apple — `ARGeoTrackingStatus.Accuracy` — https://developer.apple.com/documentation/arkit/argeotrackingstatus/accuracy-swift.enum
4. Apple — `ARWorldTrackingConfiguration.isCollaborationEnabled` — https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/3552254-iscollaborationenabled
5. Google — ARCore Geospatial API overview — https://developers.google.com/ar/develop/geospatial
6. Google — Geospatial quickstart for iOS — https://developers.google.com/ar/develop/ios/geospatial/quickstart
7. GitHub — ARCore iOS SDK releases — https://github.com/google-ar/arcore-ios-sdk/releases
8. Google — Geospatial API usage quota (iOS) — https://developers.google.com/ar/develop/ios/geospatial/api-usage-quota
9. Google — ARCore Additional Terms of Service — https://developers.google.com/ar/develop/terms
10. Google — Cloud Anchors developer guide for iOS — https://developers.google.com/ar/develop/ios/cloud-anchors/developer-guide
11. Google — Cloud Anchor Management API — https://developers.google.com/ar/develop/cloud-anchors/management-api
12. Google — Cloud Anchor API deprecation policy — https://developers.google.com/ar/develop/cloud-anchors/cloud-anchor-deprecation-policy
13. Niantic Labs / Scopely Explore — https://nianticlabs.com
14. Niantic Spatial — https://nianticspatial.com
15. Niantic Spatial — Visual Positioning System — https://nianticspatial.com/vps
16. Niantic Spatial — pricing — https://nianticspatial.com/pricing
17. Niantic Spatial — NSDK downloads & setup — https://www.nianticspatial.com/docs/llms-nsdk/downloads.txt and https://www.nianticspatial.com/docs/llms-nsdk/setup.txt
18. Niantic Spatial — migration guide (Lightship → NSDK 4.0) — https://www.nianticspatial.com/docs/llms-nsdk/migration_guide.txt
19. Niantic Spatial — VPS2 feature docs — https://www.nianticspatial.com/docs/llms-nsdk/features/vps2.txt
20. Niantic Spatial — “The Large Geospatial Model” blog — https://nianticspatial.com/blog/largegeospatialmodel
21. Niantic Spatial — consumer games privacy policy — https://www.nianticspatial.com/privacy-consumer-games
22. Wayback — Niantic “Google Cloud” post on Pokémon GO shared world — https://web.archive.org/web/2022/https://nianticlabs.com/blog/googlecloud
23. Wayback — Niantic “Dev Insights: Using shared AR to build real-world memories” — https://web.archive.org/web/2022/https://nianticlabs.com/blog/devinsights-buddyadventuresharedar
24. Snap — Custom Location AR — https://developers.snap.com/lens-studio/features/location-ar/custom-landmarker
25. Snap — City Landmarker / city-scale AR — https://developers.snap.com/lens-studio/features/location-ar/city-landmarker
26. Immersal — https://www.immersal.com and https://immersal.com/pricing
27. Augmented.City — https://augmented.city
28. S2 Geometry — https://s2geometry.io
29. Apple — `ARWorldTrackingConfiguration` — https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration

