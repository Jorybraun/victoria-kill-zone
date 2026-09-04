# App Store readiness checklist — Pew Pew (VictoriaKillZone iOS)

Audit date: 2026-09-04. Scope: `ios/VictoriaKillZone` (app target + `CombatTransport` package), `.github/workflows/testflight.yml`, `scripts/release/**`.
Guideline numbers refer to the App Store Review Guidelines; "HIG"/"TN" items are platform requirements.

Status legend: **PASS** = compliant as found · **FIXED** = fixed in the App Store readiness PR · **OPEN** = owner action still required.

## 1. Info.plist and privacy declarations

| # | Item | Guideline | Status | Detail / owner action |
|---|---|---|---|---|
| 1.1 | `NSCameraUsageDescription` present and specific | 5.1.1(i) | FIXED | Reworded to name body-pose tracking (the actual use). |
| 1.2 | `NSLocalNetworkUsageDescription` present | 5.1.1(i) | PASS | Used by `ArenaPeerLink` (Bonjour + TCP). |
| 1.3 | `NSBonjourServices` lists every advertised/browsed type | 5.1.1(i), iOS 14 local-network privacy | FIXED | `_pewpew-arena._tcp` (`ArenaPeerLink`) was present; `_vkz-combat._udp` (`CombatTransport/NetworkPeerLink`, linked into the app target) was missing and is added. Without it Bonjour discovery silently fails on iOS 14+. |
| 1.4 | `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription` | 5.1.1(i) | PASS | Both used by the opt-in Voice Fire toggle (`VoiceFireController`); copy states audio/transcripts are not stored. |
| 1.5 | Location usage strings | 5.1.1(i), 5.1.1(iii) | FIXED | `NSLocationWhenInUseUsageDescription` and `NSLocationTemporaryUsageDescriptionDictionary` removed — there is no Core Location code anywhere in `ios/`. Declaring an unused permission is a review flag. If geofencing lands later, re-add with the code. |
| 1.6 | Privacy manifest `PrivacyInfo.xcprivacy` | 5.1.1, 5.1.2; required since spring 2024 | FIXED | Added and registered in the app target's Resources phase. Declares `NSPrivacyTracking = false`, no tracking domains, collected data = Gameplay Content (app functionality, not linked, not tracking), required-reason API `NSPrivacyAccessedAPICategorySystemBootTime` reason `35F9.1` for `ProcessInfo.systemUptime` (`VoiceFireController`, `ArenaPeerLink`). No `UserDefaults`, file-timestamp, disk-space or active-keyboard APIs are used. `DispatchTime.uptimeNanoseconds` is not a listed required-reason API. |
| 1.7 | App Tracking Transparency / IDFA | 5.1.2(i) | PASS | No `AppTrackingTransparency`, `AdSupport`, `identifierForVendor`, analytics, or ad SDKs in the tree. Answer "No" to tracking in App Store Connect. |
| 1.8 | `ITSAppUsesNonExemptEncryption` | Export compliance (ASC) | PASS | Set to `false`. The app uses only HTTPS/WSS to Convex and Network.framework TLS on the peer plane (exempt standard encryption). Owner: confirm the export-compliance answer in ASC matches. |
| 1.9 | `UIBackgroundModes` | 2.5.4 | PASS | None declared; AR session and audio engines are paused on background (`ARVisionTargetingSession`, `VoiceFireController`). |
| 1.10 | `UIRequiredDeviceCapabilities` | 2.4.1, 4.2 | PASS | Intentionally not declared. iOS 17 floor + `TARGETED_DEVICE_FAMILY = 1` guarantees ARKit world tracking; body tracking is optional at runtime (`ARBodyTrackingConfiguration.isSupported` → Vision fallback). Do **not** add `arkit`/body-tracking capabilities: they cannot be removed in later updates. |
| 1.11 | `CFBundleURLTypes` (`pewpew://`) | 2.5.1 | PASS | Custom scheme for the duel invite link; handled by `RootView.onOpenURL`. |
| 1.12 | App category | ASC metadata | OPEN | `INFOPLIST_KEY_LSApplicationCategoryType` is set in the project; the store category (Games › Action) must also be set in App Store Connect. |

## 2. Build configuration

| # | Item | Guideline | Status | Detail / owner action |
|---|---|---|---|---|
| 2.1 | Deployment target vs APIs | 2.4.5 / SDK | PASS | `IPHONEOS_DEPLOYMENT_TARGET = 17.0`; newest APIs used are `AVAudioApplication.recordPermission` (iOS 17) and SwiftUI `.dynamicTypeSize`. No `@available` gaps found. |
| 2.2 | Private APIs | 2.5.1 | PASS | No `NSClassFromString`, `performSelector`, `value(forKey:)`, `dlopen`, or underscored selectors in `ios/`. |
| 2.3 | Debug UI compiled out of Release | 2.3.1 (misleading/incomplete UI), 4.2 | FIXED | `SHARED ARENA HARNESS (KIL-20)` link, `SharedArenaHarnessView`, `SharedArenaSession`, home-screen networking pill + shell footnote, lobby "LOCAL SHELL CONTROLS"/"Simulate …" buttons, and the "Simulate Host Start" path are all `#if DEBUG`. The unused "PERMISSIONS DECLARED" pill was deleted. |
| 2.4 | `DEBUG TORSO FALLBACK` fire button | AGENTS.md debug-fire rule, 2.3.1 | OPEN | Relabelled "DEBUG · TORSO FALLBACK FIRE" with a VoiceOver label and gated behind the dedicated compilation condition `VKZ_DEBUG_FIRE`, which is set in **both** Debug and Release `SWIFT_ACTIVE_COMPILATION_CONDITIONS` of the app target so the button still ships in TestFlight (the promote lane archives Release). The network path `shots:debugFire` / `LobbyStore.debugFire()` and the automatic fallback in `fireShot()` are untouched. **Owner action: remove `VKZ_DEBUG_FIRE` from the Release configuration once the two-phone markerless fire evidence is recorded in `docs/build-log.md`; do this before App Store submission** — a visible "DEBUG" control in a store build is a 2.3.1 flag. |
| 2.5 | Version / build number | 2.3, TestFlight | PASS (with note) | `MARKETING_VERSION = 0.1.1`, `CFBundleVersion` frozen from `github.run_number` by `promote-testflight.mjs`/`testflight-upload.sh` → monotonic across runs. Note: re-running a *failed* promote job reuses the same `run_number`; if the earlier attempt already uploaded, ASC rejects the duplicate build number. Owner: dispatch a fresh run instead of "re-run jobs" in that case. |
| 2.6 | Signing / provisioning | ASC | OPEN | Distribution signing lives on the Mac Outpost (`CODE_SIGN_STYLE = Automatic`, team set). Owner: confirm an App Store distribution profile (not Development) is used when archiving for review — TestFlight build 16 proves the upload lane works. |

## 3. Runtime behaviour (minimum functionality)

| # | Item | Guideline | Status | Detail / owner action |
|---|---|---|---|---|
| 3.1 | Camera permission denied | 4.2, 5.1.1 | FIXED | Previously a one-shot alert; now a persistent in-HUD panel (`TargetingBlocker.cameraDenied`) with an "OPEN SETTINGS" button (`UIApplication.openSettingsURLString`). The duel keeps running (health, opponent HP, events); only markerless aiming is disabled. Unit-tested in `TargetingBlockerTests`. |
| 3.2 | Device without body tracking | 4.2 | PASS | `ARVisionTargetingSession` falls back to world tracking + Vision `VNDetectHumanBodyPoseRequest` when `ARBodyTrackingConfiguration.isSupported == false`. |
| 3.3 | Device without ARKit / targeting failure | 4.2 | FIXED | `TargetingBlocker.unsupportedDevice` panel replaces the generic alert; no blank/crash path. |
| 3.4 | No data collection beyond need | 5.1.1(ii), 5.1.1(iii) | PASS | Match-scoped anonymous identity, user-chosen callsign, shot/hit events only. No accounts, no contacts, no analytics. |
| 3.5 | Crash-free on unconfigured backend | 2.1 | PASS | `AppEnvironment.liveOrShell` degrades to the shell; Release ships with `CONVEX_DEPLOYMENT_URL` baked in. |
| 3.6 | Kids Category / age rating | 1.3, ASC | OPEN | Simulated laser-tag "ELIMINATED"/"KILL" copy → owner sets age rating (expect 9+ or 12+, "Infrequent/Mild Cartoon or Fantasy Violence"). Not a Kids Category app. |

## 4. Accessibility

| # | Item | Guideline | Status | Detail / owner action |
|---|---|---|---|---|
| 4.1 | Dynamic Type does not break the duel HUD | HIG | FIXED | HUD clamped to `...xxxLarge`; key numerals already use `minimumScaleFactor`. |
| 4.2 | VoiceOver labels on primary buttons | HIG | FIXED | Added: Callsign field, Create duel, Join duel, Leave duel, Open Settings, debug fallback. Fire/Voice Fire/reticle/countdown already labelled. |
| 4.3 | Full VoiceOver pass on device | HIG | OPEN | Needs the two-phone TestFlight run (see §5). |

## 5. App Store Connect / owner actions (not code)

| # | Item | Guideline | Owner action |
|---|---|---|---|
| 5.1 | Privacy nutrition labels | 5.1.1, 5.1.2 | Declare "Gameplay Content" (app functionality, not linked to identity, no tracking); everything else "Data Not Collected". Must match `PrivacyInfo.xcprivacy`. |
| 5.2 | Privacy policy URL | 5.1.1(i) | Required for every app. Publish a policy covering camera/mic/local-network use and Convex match data, add the URL in ASC. |
| 5.3 | Screenshots (6.9" and 6.5" iPhone) | 2.3.3 | Capture from a TestFlight/Release build so no debug UI appears. |
| 5.4 | App description / keywords / support URL | 2.3.1, 2.3.7 | Describe the two-phone requirement clearly (Guideline 2.1: reviewers need to know how to test). |
| 5.5 | App Review notes + demo | 2.1 | Explain that a duel needs two iPhones on the same Wi-Fi; provide a short video of a full duel, or reviewers cannot exercise the core loop. |
| 5.6 | Export compliance | ASC | Answer consistent with `ITSAppUsesNonExemptEncryption = false`. |
| 5.7 | Age rating questionnaire | 1.3 | See 3.6. |
| 5.8 | Two-phone TestFlight verification of this PR | AGENTS.md hardware gate | Verify: (a) no harness link / shell controls visible in the TestFlight build, and the `DEBUG · TORSO FALLBACK FIRE` button **is** still present for the host; (a2) markerless FIRE lands hits on both phones without the fallback — this is the evidence that unlocks removing `VKZ_DEBUG_FIRE` from Release (item 2.4); (b) deny camera → panel + Open Settings works and the duel HUD stays alive; (c) Bonjour discovery still works for `_pewpew-arena._tcp`; (d) VoiceOver reads the primary buttons; (e) Dynamic Type at largest accessibility size. Record model/iOS only in `docs/build-log.md`. |

## Deleted in this audit

- Unused location usage strings (no Core Location code exists).
- The static "PERMISSIONS DECLARED" home-screen pill (no user meaning).

Kept deliberately: `shots:debugFire`, `LobbyStore.debugFire()`, the automatic torso fallback in `ActiveDuelView.fireShot()`, the `VKZ_DEBUG_FIRE` fallback button in TestFlight builds, and everything under `archive/`.
