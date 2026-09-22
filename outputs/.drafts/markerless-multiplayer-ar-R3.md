# Research: In-game player-report & diagnostics pipelines for iOS games

Scope: how shipped mobile games and the iOS ecosystem implement in-game player reports and diagnostics; comparison against the game's existing pipeline (in-app voice-note report → on-device Speech transcription → diagnostics JSON + device metadata → authenticated Cloudflare Worker → GitHub issue; os_log subsystem logging + bounded persisted diagnostics file). Backend stack context: Cloudflare Workers + Convex, 4-player markerless AR game in TestFlight.

Status markers: [done] all five questions answered with fetched sources.

---

## Evidence Table

| # | Source | URL | Key claim | Type | Confidence |
|---|--------|-----|-----------|------|------------|
| 1 | Instabug iOS integration docs | https://instabug-docs.luciq.ai/docs/ios-integration | Invocation via shake, screenshot, floating button, manual; can be enabled only for beta builds | primary (vendor docs) | high |
| 2 | Instabug iOS report content docs (fetched in full) | https://instabug-docs.luciq.ai/docs/ios-bug-report-content | Default attachment is auto-captured annotatable screenshot; auto screen recording of "up to the last 30 seconds" before report (beta, "used for internal testing"); attachments capped at 4; default attributes: app version, device, OS version, app view, location, session duration | primary (vendor docs, read directly) | high |
| 3 | Instabug iOS logging docs | https://instabug-docs.luciq.ai/docs/ios-logging | Each report carries console logs (≤500), Instabug logs (≤1,000), network logs (≤100), user steps (≤100) | primary | high |
| 4 | Instabug iOS Repro Steps docs | https://instabug-docs.luciq.ai/docs/ios-repro-steps | Repro steps = per-view interaction log (taps, swipes, lifecycle events, memory warnings) with screenshots | primary | high |
| 5 | Helpshift gaming platform page | https://www.helpshift.com/platform/tech/ | Gaming-native SDKs for Unity/Unreal/Cocos/React Native/native iOS; in-game messaging UI, FAQs, AI→human escalation, persistent per-player conversation | primary (vendor) | high |
| 6 | Helpshift Unity SDK X iOS guide | https://developers.helpshift.com/sdkx-unity/getting-started-ios/ | User attachments enabled via SDK config; attachments picked from photo library or file picker | primary | high |
| 7 | Unity Cloud Diagnostics – Configuring User Reporting | https://docs.unity.com/cloud-diagnostics/user-reporting/configuring-user-reporting | User reports contain metadata, events, sampled metrics, screenshots, file attachments (Base64); Cloud Diagnostics deprecated, Unity 6.2+ has new diagnostics | primary | high |
| 8 | Unity Cloud Diagnostics – Understanding User Reporting | https://docs.unity.com/en-us/cloud-diagnostics/user-reporting/understanding-user-reporting.md | Report size limit 10 MB; attachments downloadable in dashboard | primary | high |
| 9 | Apple App Store Connect Help – View tester feedback | https://developer.apple.com/help/app-store-connect/test-a-beta-version/view-tester-feedback/ | TestFlight 2.3+ gives testers built-in screenshot feedback + crash feedback, visible in App Store Connect; crash reports downloadable 120 days | primary (official docs) | high |
| 10 | TestFlight public page | https://testflight.apple.com/ | Testers send feedback via TestFlight app or by taking a screenshot in the beta app; comments up to 4,000 chars | primary | high |
| 11 | Apple MXMetricManager docs (verified via DocC JSON) | https://developer.apple.com/documentation/metrickit/mxmetricmanager | "Metric reports at most once per day per metric source, and diagnostic reports immediately in iOS 15 and later"; payloads cover past 24 h + undelivered reports; subscribe via `MXMetricManager.shared.add(_:)`; safe during app launch | primary (official docs, read directly) | high |
| 12 | Apple MXDiagnosticPayload docs (verified via DocC JSON) | https://developer.apple.com/documentation/metrickit/mxdiagnosticpayload | "The system delivers a diagnostic report as soon as it's available"; contains crashDiagnostics, cpuExceptionDiagnostics, appLaunchDiagnostics, hangDiagnostics, diskWriteExceptionDiagnostics; `jsonRepresentation()` for export | primary (official docs, read directly) | high |
| 13 | WWDCNotes – What's new in MetricKit (WWDC20) | https://wwdcnotes.com/documentation/wwdc20-10081-whats-new-in-metrickit/ | Diagnostics are event-tied (vs. aggregated metrics); MXCallStackTree included; implement `didReceive(_ payloads: [MXDiagnosticPayload])` | secondary (community notes on Apple session) | medium |
| 14 | Sentry Apple/iOS features docs | https://docs.sentry.io/platforms/apple/guides/ios/features.md | Crash report persists to disk, sent on next launch (iOS only allows async-safe code during crash); app-hang detection, watchdog termination tracking, auto breadcrumbs, screenshot + view hierarchy capture, user feedback UI | primary | high |
| 15 | Sentry iOS attachments docs | https://docs.sentry.io/platforms/apple/guides/ios/enriching-events/attachments.md | Attachments live on scope; ≤40 MB compressed / 200 MB uncompressed per event; **attachments not supported on crashes** | primary | high |
| 16 | Firebase Crashlytics – customize crash reports (iOS) | https://firebase.google.com/docs/crashlytics/ios/customize-crash-reports | Custom keys, custom log messages attached to crash reports; `recordError` records non-fatal exceptions sent next launch; non-fatals grouped by NSError domain+code | primary | high |
| 17 | BugSnag iOS docs | https://docs.bugsnag.com/platforms/ios/ | Auto diagnostics: all-thread stack traces, app state, device spec, free memory/disk/battery; auto breadcrumbs incl. low-memory warnings, screenshot capture, thermal state changes; URLSession network breadcrumbs via plugin | primary | high |
| 18 | Bugnet blog – structured logging for multiplayer games | https://bugnet.io/blog/how-to-set-up-structured-logging-for-multiplayer-games | Emit JSON log entries with mandatory fields incl. session_id, player_id, match_id; session_id is the correlation ID to include in bug-report metadata; match_id enables cross-player timelines for desync debugging; sample high-frequency events | secondary (technical blog) | medium |
| 19 | OneUptime blog – game event replay with Redis Streams | https://oneuptime.com/blog/post/2026-03-31-redis-how-to-build-a-game-event-replay-system-with-redis-streams/view | Established pattern: append-only ordered per-match event stream (move/shoot/kill events) stored with TTL for replay/debugging/anti-cheat | secondary (technical blog) | medium |
| 20 | Convex Log Streams docs | https://docs.convex.dev/production/integrations/log-streams.md | Convex streams function_execution + console events as JSON (topic/timestamp schema) to Axiom, Datadog, PostHog, **or a custom webhook**; dashboard shows recent logs only | primary | high |
| 21 | Apple Technical Q&A QA1951 | https://developer.apple.com/library/archive/qa/qa1951/_index.html | Speech framework: 1,000 requests/hour per device; max ~1 minute of audio per SFSpeechRecognitionRequest | primary (official) | high |
| 22 | Apple SFSpeechRecognizer docs | https://developer.apple.com/documentation/speech/sfspeechrecognizer | Devices may be limited in recognitions/day; apps may be throttled globally; tasks >1 min are stopped (battery/network burden); handle fast-failure as rate limit | primary (official) | high |
| 23 | Apple requiresOnDeviceRecognition docs | https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition | On-device requests "won't be as accurate"; honored only if `supportsOnDeviceRecognition` is true for the locale | primary (official) | high |
| 24 | intrepidkarthi – SFSpeechRecognizer on-device deep dive | https://intrepidkarthi.com/writing/sfspeechrecognizer-on-device-deep-dive/ | Undocumented ~60 s limit per streaming SFSpeechRecognitionTask; on-device models only for major locales; check supportsOnDeviceRecognition and degrade gracefully | secondary (technical blog) | medium |
| 25 | DEV Community – on-device speech recognition boundaries | https://dev.to/tbds_2dadf2b626f315902eae/on-device-speech-recognition-on-ios-the-honest-boundaries-1ndn | "Supported" ≠ model installed; on-device failure mode is an empty transcript, not an error; noisy/quiet audio fails silently | secondary | medium |
| 26 | Apple Developer Forums thread 731230 | https://developer.apple.com/forums/thread/731230 | On-device recognition (error 1101) fails unless matching keyboard installed, Dictation enabled, and dictation language downloaded | primary (Apple forum, incl. engineer guidance) | medium |
| 27 | Cloudflare Workers AI – whisper-large-v3-turbo | https://developers.cloudflare.com/workers-ai/models/whisper-large-v3-turbo/ | Server-side ASR on their existing stack; $0.000513 per audio minute; transcribe/translate tasks, initial_prompt support | primary | high |
| 28 | Cloudflare Workers AI – Whisper chunking tutorial | https://developers.cloudflare.com/workers-ai/guides/tutorials/build-a-workers-ai-whisper-with-chunking/ | Official pattern for transcribing large audio files via AI binding, chunking to fit Worker limits | primary | high |
| 29 | Apple RPScreenRecorder docs (+ DocC JSON for startClipBuffering) | https://developer.apple.com/documentation/replaykit/rpscreenrecorder | ReplayKit records app audio+video + mic commentary; `startClipBuffering`/`exportClip(to:duration:)` rolling-clip API introduced iOS 15.0 (verified in DocC JSON; marked deprecated at iOS 27) | primary (official docs, read directly) | high |
| 30 | Swift with Majid – exporting Unified Logging data | https://swiftwithmajid.com/2022/04/19/exporting-data-from-unified-logging-system-in-swift/ | OSLogStore(scope: .currentProcessIdentifier) is the only iOS scope; fetch entries since a position, filter by subsystem → export/share | secondary | medium |
| 31 | Use Your Loaf – fetching OSLog messages | https://useyourloaf.com/blog/fetching-oslog-messages-in-swift/ | Practical limits: on iOS, OSLogStore only returns entries for the **current process run** (no pre-launch history), fetches can be slow | secondary | medium |
| 32 | GONet Record & Replay (Unity netcode) | https://galoreinteractive.com/gonet/record-replay | Commercial multiplayer SDK implements "always-on circular buffer capturing last N seconds" of session events for highlights/crash context — same rolling-buffer pattern as Instabug auto recording | primary (vendor) | medium |

---

## Findings by question

### Q1. Player-report flows in shipped mobile games

**The dominant pattern is exactly what the game already implements: a freeform report bundled with automatically captured context.** Every major tool converges on the same structure: (a) a low-friction invocation, (b) a text/voice description field, (c) auto-attached screenshot + logs + device metadata, (d) optional extra attachments.

**Invocation patterns.** Instabug's defaults are shake-to-report, screenshot-gesture, floating button, two-finger swipe, or manual invocation; multiple events can be combined, and the SDK can be compiled in only for beta/TestFlight builds via `#if DEBUG` or environment checks [1]. For an AR game, a settings-menu "Report a problem" button (what the game already has) is the right call — shake is awkward mid-game and the screenshot gesture collides with players screenshotting gameplay.

**Auto-attached context (the part the industry standardizes on).** Per Instabug's iOS report-content docs (read directly), every report automatically includes:
- An **annotatable screenshot** captured at invocation (draw/blur/magnify) — the default attachment [2]
- Optional extra screenshots, photo-library images, and **screen recording** [2]
- **Auto screen recording**: the SDK can continuously buffer and attach "up to the last 30 seconds" of app screen before the report — disabled by default, currently beta, explicitly positioned "for internal testing rather than on production," counts toward a 4-attachment cap [2]
- Logs: console logs (≤500 lines), SDK logs (≤1,000), network request/response logs (≤100), user steps (≤100) [3]
- **Repro Steps**: a per-view timeline of user interactions (taps, swipes, text edits, foreground/background transitions, memory warnings) with thumbnails [4]
- Default attributes: app version, device, OS version, current app view, location, session duration [2]

**In-game support-ticket model.** Helpshift positions itself as a "gaming-native" SDK (Unity Verified) with in-game messaging UI, searchable FAQs, AI→human escalation, and persistent per-player conversations; attachments are enabled via SDK config and picked from photo library/file picker [5][6]. This is heavier than needed for a 4-person TestFlight beta — it solves the "support conversation" problem, not the "debug this desync" problem.

**Engine-provided reporting.** Unity Cloud Diagnostics' User Reporting bundled metadata, logged events, sampled performance metrics, screenshots, and arbitrary file attachments (Base64, ≤10 MB/report) into a dashboard [7][8] — notably, it is now deprecated in favor of Unity 6.2's diagnostics [7]. The fact that Unity built a first-party version confirms this is standard infrastructure for games, not an edge case.

**Platform baseline.** TestFlight itself gives testers screenshot feedback ("take a screenshot in the beta app") and crash feedback with comments up to 4,000 chars, visible in App Store Connect [9][10]. So the game's custom flow competes with a zero-effort built-in path — its justification is the richer payload (voice, transcript, diagnostics JSON, match context), which is real.

**Gap assessment vs. industry practice:**
- Matches: freeform report + bundled diagnostics + routed to an issue tracker (GitHub issues ≈ Instabug dashboard / Jira integrations).
- Missing vs. Instabug-class tools: (1) no visual attachment — no screenshot, no screen clip, which matters enormously for "the marker drifted / the enemy wasn't there" AR reports; (2) no structured pre-report event trail equivalent to "user steps"/repro steps — the diagnostics JSON partially covers this if it logs gameplay events; (3) no crash/hang capture (see Q2).

### Q2. Crash + non-fatal diagnostics on iOS

**MetricKit (first-party, zero dependencies).** Subscribe once at launch — `MXMetricManager.shared.add(self)` on an `MXMetricManagerSubscriber` — documented as "safe to use in performance-sensitive code, such as during app launch" [11]. Delivery model (verified from Apple's docs):
- **Metric payloads**: at most once/day per source, covering the past 24 h + any undelivered reports (launch time, hang rate, battery, memory, disk writes) [11]
- **Diagnostic payloads**: "delivered immediately" on iOS 15+/macOS 12+ — i.e., the app receives them on next run after the event and can upload right away [11][12]
- Diagnostic types: `crashDiagnostics` (call stack tree, exception type/code/signal, termination reason, VM region for bad access), `hangDiagnostics` (hang duration + main-thread backtrace), `cpuExceptionDiagnostics`, `diskWriteExceptionDiagnostics`, `appLaunchDiagnostics` [12]; iOS 27 adds a memory-exception diagnostic type [13]
- `jsonRepresentation()` produces an uploadable JSON — meaning MetricKit output can flow through the game's **existing** Worker → GitHub pipeline with ~50 lines of code [12]
- Caveat: callStackTree is Apple's JSON symbolication format, not a symbolicated backtrace — useful for aggregation/regressions but requires a symbolication step to read (Xcode Organizer handles this for App Store builds automatically).

**Third-party SDKs.** All three majors do more than MetricKit but add a dependency + dashboard:
- **Sentry iOS**: crash report persisted to disk and sent on *next launch* (iOS only permits async-safe work during a crash); automatic app-hang detection and watchdog-termination tracking; auto breadcrumbs (lifecycle, touch, system events, HTTP); screenshot + view-hierarchy capture on errors; built-in User Feedback UI [14]. Attachments up to 40 MB compressed/200 MB uncompressed per event — but **attachments cannot be added to crash events** [15].
- **Firebase Crashlytics**: custom keys + custom logs attached to reports; `recordError` for non-fatals (sent next launch, grouped by NSError domain+code); breadcrumbs require Google Analytics [16].
- **BugSnag iOS**: auto diagnostics incl. free memory/disk/battery; auto breadcrumbs include **thermal state changes**, memory warnings, and screenshot capture; URLSession network breadcrumbs via plugin [17] — thermal breadcrumbs are unusually relevant for an AR game, where thermal throttling is a top real-world failure mode.

**Where the game stands.** The persisted diagnostics file covers app-authored events, but nothing captures crashes, hangs, watchdog kills, or CPU/disk-write exceptions today. MetricKit is the obvious fit: no dependency, no new backend, no privacy surface beyond what's already uploaded, and it slots into the existing Worker endpoint. A third-party SDK's added value (symbolicated crash grouping, dashboards, non-fatals) is real but arguably premature at TestFlight scale — TestFlight itself already delivers crash reports via App Store Connect [9].

### Q3. Gameplay telemetry / event trails

**The established pattern is a structured, append-only per-match event log keyed by correlation IDs.** For multiplayer debugging, the fields that matter are `session_id` (per player connection — the correlation ID you thread through every log and *include in bug-report metadata*), `match_id` (to reconstruct cross-player timelines — "pull every log entry for a match, sort by timestamp, find where two players' states diverge" for desync debugging), `player_id`, timestamp, event type, and payload [18]. High-frequency events (position updates, input state) should be sampled at a configurable rate to control volume [18]. A per-match append-only event stream with a TTL is the canonical implementation for match replay/debugging [19], and commercial netcode SDKs ship always-on circular buffers of "the last N seconds" of events for crash context [32].

**Fit to their stack (Cloudflare Workers + Convex):**
- Convex mutations already process every game action — appending a compact `{matchId, playerId, seq, type, data}` row to a `matchEvents` table inside the same mutation is nearly free and gives an authoritative server-side event trail for free (inference — based on Convex's mutation model; no client-side gaps).
- Convex **Log Streams** already emit `function_execution` and `console` events as structured JSON to Axiom/Datadog/PostHog **or a custom webhook** — i.e., their existing Cloudflare Worker could be the ingestion destination; note the dashboard only retains recent logs, so streaming is needed for history [20].
- Lightweight alternative: a bounded in-memory event ring per match on the client, serialized into the diagnostics bundle only on report — zero server cost, but loses the other 3 players' perspectives, which is exactly what desync debugging needs (inference, cf. [18]).
- **The single highest-leverage detail**: put `matchId` + `sessionId` into both the diagnostics JSON and the GitHub issue metadata, so a player report links directly to the server-side match trail. This is precisely the session-ID-in-report-metadata pattern recommended in [18].

### Q4. Voice report handling

**On-device Speech framework limits (verified from Apple sources):**
- `SFSpeechRecognitionRequest` default path uses Apple's servers: max **~1 minute of audio per request** and **1,000 requests/hour per device** [21]; tasks longer than ~1 minute are stopped by design (battery/network burden) [22]
- Per-device daily recognition caps and **global per-app throttling** apply; a request failing within ~1–2 s of starting indicates a service/limit failure [22]
- `requiresOnDeviceRecognition = true` keeps audio on-device but is "not as accurate" and only honored when `supportsOnDeviceRecognition` is true for that locale [23]
- Practical gotchas from field reports: streaming tasks die around ~60 s (undocumented), on-device models cover major locales only, "supported" ≠ model downloaded (error 1101 unless matching keyboard/dictation assets installed), and the failure mode is often a **silently empty transcript**, not an error [24][25][26]

**Server-side alternative — and it already fits their stack.** Cloudflare Workers AI hosts `whisper-large-v3-turbo` at **$0.000513 per audio minute** with `transcribe`/`translate` tasks and `initial_prompt` for domain vocabulary; there's an official chunking tutorial for larger files through a Worker's AI binding [27][28]. A 30–60 s bug-report voice note costs a fraction of a cent.

**Assessment of their current design:** on-device transcription is the right default (privacy, offline, zero marginal cost). The gap is the **empty-transcript failure mode**: if the on-device transcript comes back empty or garbage, the report currently loses the voice note's content entirely. The industry-standard mitigation is to upload the audio file alongside the transcript — the audio is then either directly listenable or re-transcribable server-side via Workers AI Whisper [27][28]. This also future-proofs against the 1-minute/task limits: a longer note can be chunked server-side [28].

### Q5. Recommendations for a tiny TestFlight team

Ranked by debugging-value-per-effort:

1. **MetricKit integration (highest value/effort ratio).** ~50 lines: subscribe `MXMetricManager` at launch, serialize `MXDiagnosticPayload.jsonRepresentation()` + `MXMetricPayload`, forward through the existing authenticated Worker into GitHub issues (or a separate "diagnostics" issue label). Gains crash call-stack trees, hang reports, CPU exceptions, disk-write exceptions, launch metrics — the entire system-level failure surface an AR game is most likely to hit — with zero dependencies and zero new infrastructure [11][12][13]. Fills the biggest current gap: the pipeline only captures what the app itself logs, nothing that kills or stalls the process.

2. **Visual attachment: screenshot now, rolling clip if budget allows.** A still frame (capture the current ARFrame/MTKView into a JPEG attached to the report) is a day of work and covers most "the alignment was wrong" reports. The next step — matching Instabug's proven "last 30 seconds" pattern [2] and commercial replay buffers [32] — is ReplayKit's `startClipBuffering`/`exportClip` rolling-clip API (iOS 15+; note it's marked deprecated in iOS 27 per DocC metadata, so verify direction on current SDK before building on it) [29]. For a *spatial* AR game, a 30 s video clip of drift/occlusion is worth more than any amount of log text; this is the standard industry answer to "can't reproduce" reports. Attach clips only on demand (user opts in per report) to control upload size.

3. **Server-side match event log with report linkage.** Append structured `{matchId, sessionId, playerId, seq, type, data}` events inside existing Convex mutations (near-zero marginal cost), retain per-match TTL-style; emit `matchId`/`sessionId` into the diagnostics bundle and GitHub issue so every report is one click from the authoritative event trail [18][19][20]. For a 4-player game this is the only way to debug desync/anchor-sharing bugs, which will be the hardest class of TestFlight issues. Optionally wire Convex Log Streams to the Worker webhook for backend-error visibility [20].

**Cheaper honorable mentions:**
- Upload the voice-note audio alongside the transcript; re-transcribe via Workers AI Whisper when the on-device transcript is empty (<$0.001/report) [25][27]
- Note that TestFlight's built-in screenshot/crash feedback exists regardless — worth documenting to testers so both paths get used [9][10]
- Defer Sentry/Crashlytics/BugSnag: they earn their dependency cost when non-fatal error grouping and dashboards are needed at scale; MetricKit + persisted logs + match events cover the beta need [14][16][17]
- Their persisted diagnostics file is the right call over `OSLogStore`: on iOS the store only exposes the current process run, so it can't capture logs from a crashed previous session — a persisted file can [30][31]

---

## Coverage Status

- **Checked directly (fetched/read):** Apple DocC JSON for MXMetricManager, MXDiagnosticPayload, RPScreenRecorder/startClipBuffering; full Instabug iOS report-content page; all other sources via search-result content extraction.
- **Confirmed:** MetricKit diagnostic types & delivery cadence; Speech framework limits (1 min/request, 1000 req/h, throttling); Instabug auto-recording (30 s, beta); Sentry/Crashlytics/BugSnag iOS feature sets; TestFlight built-in feedback; Cloudflare Whisper availability & pricing; Convex Log Streams + custom webhook; OSLogStore current-process limitation on iOS.
- **Uncertain / not fully verified:** exact price of `@cf/openai/whisper` base model (only turbo pricing verified); whether iOS 27's deprecation of `startClipBuffering` has a named replacement (worth checking current SDK headers before implementing); Bugnet/OneUptime posts are reputable-seeming technical blogs, not vendor-official — claims used only for the general "structured match event log" pattern, which is independently corroborated by commercial SDK docs [32].
- **Not done:** no shipped-game-by-name teardowns (e.g., which specific titles use Instabug/Helpshift) — tool documentation + platform baselines were judged sufficient evidence for the practice-level questions.

## Sources

1. Instabug — iOS Integration. https://instabug-docs.luciq.ai/docs/ios-integration
2. Instabug — Report Types & Content for iOS. https://instabug-docs.luciq.ai/docs/ios-bug-report-content
3. Instabug — Report Logs for iOS. https://instabug-docs.luciq.ai/docs/ios-logging
4. Instabug — Repro Steps for iOS. https://instabug-docs.luciq.ai/docs/ios-repro-steps
5. Helpshift — Gaming Support SDK & Platform Technology. https://www.helpshift.com/platform/tech/
6. Helpshift — SDK X Unity: Getting Started iOS. https://developers.helpshift.com/sdkx-unity/getting-started-ios/
7. Unity Docs — Configuring User Reporting (Cloud Diagnostics). https://docs.unity.com/cloud-diagnostics/user-reporting/configuring-user-reporting
8. Unity Docs — Understand User Reporting. https://docs.unity.com/en-us/cloud-diagnostics/user-reporting/understanding-user-reporting.md
9. Apple — View tester feedback (App Store Connect Help). https://developer.apple.com/help/app-store-connect/test-a-beta-version/view-tester-feedback/
10. Apple — TestFlight. https://testflight.apple.com/
11. Apple — MXMetricManager. https://developer.apple.com/documentation/metrickit/mxmetricmanager
12. Apple — MXDiagnosticPayload. https://developer.apple.com/documentation/metrickit/mxdiagnosticpayload
13. WWDCNotes — What's new in MetricKit (WWDC20 session notes). https://wwdcnotes.com/documentation/wwdc20-10081-whats-new-in-metrickit/
14. Sentry — Apple SDK for iOS: Features. https://docs.sentry.io/platforms/apple/guides/ios/features.md
15. Sentry — Attachments for iOS. https://docs.sentry.io/platforms/apple/guides/ios/enriching-events/attachments.md
16. Firebase — Customize Crashlytics crash reports (iOS). https://firebase.google.com/docs/crashlytics/ios/customize-crash-reports
17. BugSnag — iOS platform docs. https://docs.bugsnag.com/platforms/ios/
18. Bugnet — How to Set Up Structured Logging for Multiplayer Games. https://bugnet.io/blog/how-to-set-up-structured-logging-for-multiplayer-games
19. OneUptime — How to Build a Game Event Replay System with Redis Streams. https://oneuptime.com/blog/post/2026-03-31-redis-how-to-build-a-game-event-replay-system-with-redis-streams/view
20. Convex — Log Streams. https://docs.convex.dev/production/integrations/log-streams.md
21. Apple — Technical Q&A QA1951: Speech Framework API rate limits. https://developer.apple.com/library/archive/qa/qa1951/_index.html
22. Apple — SFSpeechRecognizer. https://developer.apple.com/documentation/speech/sfspeechrecognizer
23. Apple — SFSpeechRecognitionRequest.requiresOnDeviceRecognition. https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition
24. intrepidkarthi — SFSpeechRecognizer deep dive: what requiresOnDeviceRecognition really gets you. https://intrepidkarthi.com/writing/sfspeechrecognizer-on-device-deep-dive/
25. DEV Community — On-device speech recognition on iOS: the honest boundaries. https://dev.to/tbds_2dadf2b626f315902eae/on-device-speech-recognition-on-ios-the-honest-boundaries-1ndn
26. Apple Developer Forums — Failure of speech recognition when supportsOnDeviceRecognition is true (thread 731230). https://developer.apple.com/forums/thread/731230
27. Cloudflare — Workers AI: whisper-large-v3-turbo. https://developers.cloudflare.com/workers-ai/models/whisper-large-v3-turbo/
28. Cloudflare — Whisper-large-v3-turbo with Cloudflare Workers AI (chunking tutorial). https://developers.cloudflare.com/workers-ai/guides/tutorials/build-a-workers-ai-whisper-with-chunking/
29. Apple — RPScreenRecorder (ReplayKit). https://developer.apple.com/documentation/replaykit/rpscreenrecorder
30. Swift with Majid — Exporting data from Unified Logging System in Swift. https://swiftwithmajid.com/2022/04/19/exporting-data-from-unified-logging-system-in-swift/
31. Use Your Loaf — Fetching OSLog Messages in Swift. https://useyourloaf.com/blog/fetching-oslog-messages-in-swift/
32. Galore Interactive — GONet Record & Replay. https://galoreinteractive.com/gonet/record-replay
