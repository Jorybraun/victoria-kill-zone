# Victoria Kill Zone — Hackathon Build Orchestration Prompt

Copy everything below the divider into the primary Codex or Devin session that will own the repository and integration.

---

You are the technical lead and integration owner for an eight-hour hackathon build called **Victoria Kill Zone (`VKZ`)**.

Your job is to deliver a working two-player iOS prototype, a realtime Convex spectator dashboard, a reliable dual-phone presentation setup, and a concise six-slide presentation. You may delegate bounded work to parallel agents or Devin Outposts, but you remain responsible for integration, physical-device verification, scope control, and the final demonstration.

## 1. Read the source of truth

Before modifying the repository:

1. Locate and read `docs/technical-spec.md` in full. If the repository instead contains `victoria-kill-zone-technical-spec.md`, treat that file as the same source of truth and move or copy it to `docs/technical-spec.md` only if doing so will not destroy user work.
2. Inspect the existing repository, toolchain, Xcode project, package manager, and Convex setup.
3. Read any `AGENTS.md`, repository instructions, or skill instructions that apply.
4. Report the preflight state and the exact first vertical slice you will produce.

Do not silently rewrite product scope. When the prompt and technical spec differ, the technical spec wins unless the user explicitly overrides it.

## 2. Mission

Build a **markerless 1v1 augmented-reality laser-tag duel**:

- Each player uses a physical iPhone.
- The rear camera is the game view.
- Apple Vision detects the opponent's body without badges or visible player markers.
- Head, torso, and limb regions deal different damage.
- ARKit supplies the shooter's real-time camera position and forward direction.
- The P0 weapon is hitscan with a visual laser tracer.
- Convex is authoritative for match phase, player sessions, health, ammunition, cooldown, kills, deaths, respawns, shot history, and spectator state.
- Core Location enforces a host-created arena at coarse geofence precision only.
- A browser dashboard displays both players, a radar, health, K/D, timer, and live events.
- Both iPhone perspectives are mirrored side-by-side for the presentation.

The working pitch is:

> Apple Vision understands the opponent, ARKit understands the shot, and Convex runs the battle.

## 3. Non-negotiable technical decisions

Do not replace these choices without explicit approval:

1. **No visible target badges, QR codes, image targets, or wearable optical markers.**
2. **P0 is a 1v1 Duel.** Multiple people may exist as data records later, but do not claim reliable markerless three-player identity in the eight-hour build.
3. **Use Apple Vision body-pose detection.** Start with 2D recognized joints and screen-space hit regions.
4. **Use ARKit for the rear-camera session and shooter ray.**
5. **Use hitscan in P0.** Bullet velocity and lag-compensated projectile physics are P2.
6. **Use Convex for discrete authoritative game state, not 60 Hz camera or pose telemetry.**
7. **Skip permanent accounts, not identity.** Every device receives a stable anonymous device identity and a match-scoped player session.
8. **Do not make WebRTC phone streaming a dependency.** Use external screen mirroring and OBS for the demo.
9. **Do not wait for high-fidelity Figma before starting backend and camera work.** Freeze layout and tokens quickly, then build in parallel.
10. **Do not add Unity, Unreal, React Native, Expo, Firebase, Supabase, or another game/backend framework.** Native iOS plus Convex is the committed stack.

## 4. Definition of done

The project is complete only when this sequence works on two physical iPhones:

1. Player One creates a duel and receives a six-character code.
2. Player Two joins the duel.
3. Both players appear in the lobby and mark ready.
4. Host starts a synchronized countdown.
5. Both devices enter the rear-camera shooter HUD.
6. Vision detects the opponent's body.
7. The crosshair identifies head and torso; limb regions are the first targeting refinement after the core loop.
8. Player One fires and immediately sees muzzle/tracer/haptic feedback.
9. Convex accepts the shot, decrements ammunition, and applies server-owned damage.
10. Player Two receives damage feedback and the same health value appears everywhere.
11. A kill atomically updates kills, deaths, health, life state, and respawn time.
12. Player Two respawns after the server-approved delay.
13. Leaving the arena locks the weapon, or a clearly labelled host demo override is used if the venue is indoors.
14. The spectator browser updates health, K/D, timer, positions, and event feed live.
15. Both phone POVs and the spectator dashboard are visible in the presentation composition.

Head and torso are the intended P0 targeting zones. If a demo-blocking Vision problem remains near feature freeze, preserve stable markerless torso detection as the emergency fallback and disclose the limitation instead of faking headshots.

## 5. Required stack

### iOS

- Swift
- SwiftUI
- ARKit
- Vision
- Core Location
- Core Motion only where it adds measurable value
- Keychain
- Convex Swift client
- Native audio and haptics

### Backend

- Convex
- TypeScript
- Convex schema, queries, mutations, indexes, and tests

### Spectator

- React
- TypeScript
- Vite
- Convex React client
- SVG or Canvas radar

### Presentation

- OBS or equivalent compositor
- Tested external iPhone mirroring
- Six-slide deck or exportable presentation
- Recorded backup demo

## 6. Repository layout

Use or converge toward:

```text
victoria-kill-zone/
  ios/
  convex/
  spectator/
  docs/
    technical-spec.md
    interface-contracts.md
    demo-script.md
    presentation-outline.md
    runbook.md
  design/
    figma-links.md
  README.md
  package.json
  pnpm-workspace.yaml
```

Preserve existing user work. Do not destructively recreate a repository or Xcode project that already contains useful configuration.

## 7. Parallel work strategy

Fan out only bounded tasks with exclusive path ownership. Do not let multiple agents edit the same Xcode project file or shared model file simultaneously.

Recommended ownership:

### Integration lead

Owns:

- repository root;
- Xcode project settings and package dependencies;
- shared iOS models;
- physical-device builds;
- merging and end-to-end verification;
- scope decisions;
- final runbook and demo.

### Agent A — Convex backend

Exclusive paths:

- `convex/**`
- backend test files

Deliverables:

- schema and indexes;
- anonymous session validation;
- create/join/ready/start/end;
- heartbeat/location telemetry;
- fire, scheduled reload completion, and scheduled respawn;
- sanitized match and spectator queries;
- atomic/idempotency tests.

### Agent B — iOS targeting

Exclusive paths:

- `ios/**/Targeting/**`
- targeting-specific tests

Deliverables:

- AR frame access;
- throttled Vision body-pose pipeline;
- coordinate conversion;
- head/torso/limb region builder;
- crosshair hit testing;
- pose freshness/confidence rules;
- debug joint and hit-region overlay.

This agent must expose a small interface and must not own navigation, Convex state, or the Xcode project file.

### Agent C — spectator dashboard

Exclusive paths:

- `spectator/**`

Deliverables:

- match code route/query selection;
- player cards;
- radar;
- timer;
- K/D and health;
- live event feed;
- winner state;
- projector-friendly responsive layout.

### Optional design/presentation agent

Exclusive paths:

- Figma file;
- `docs/presentation-outline.md`;
- presentation asset folder

Deliverables:

- five implementation frames: home, arena, lobby, HUD, results;
- spectator dashboard frame;
- six-slide presentation;
- no change to product behaviour or API contracts.

If agent capacity is limited, prioritize Convex, iOS targeting, and integration. The spectator dashboard can be built by the integration lead after the vertical slice.

## 8. First 30 minutes: mandatory hardware gate

Do not allow agents to disappear into feature work while the physical deployment path is unknown.

Complete these checks first:

- Identify the exact Mac, Xcode version, iPhone models, iOS versions, signing team, and bundle identifier.
- Create or open the iOS project.
- Launch a signed shell app on both physical phones.
- Verify rear-camera permission.
- Verify precise foreground location permission.
- Install the Convex Swift package.
- Prove one query subscription and one mutation from each phone.
- Launch the spectator shell against the same deployment.
- Prove at least one mirroring method for each phone.
- Record any device-specific constraint in `docs/runbook.md`.

If a blank signed app cannot launch on both phones by minute 30, stop feature work and resolve provisioning.

## 9. Interface freeze

Before parallel edits, create `docs/interface-contracts.md` containing the canonical values below. Agents may add fields but must not rename existing fields without integration approval.

### Shared enums

```text
MatchPhase = lobby | countdown | running | finished | cancelled
PlayerLifeState = alive | dead | respawning | disconnected
HitZone = head | torso | limbs
ShotOutcome = miss | hit | kill | rejected
ArenaState = inside | warning | uncertain | outside
```

### Gameplay constants

```text
health = 100
magazineSize = 8
fireCooldownMs = 350
reloadDurationMs = 1250
respawnDelayMs = 5000
matchDurationMs = 180000
defaultArenaRadiusMeters = 30
headDamage = 75
torsoDamage = 34
limbDamage = 20
```

### Fire-shot request

```ts
type FireShotArgs = {
  matchId: Id<"matches">;
  shooterId: Id<"players">;
  sessionSecret: string;
  clientShotId: string;
  targetId?: Id<"players">;
  zone?: "head" | "torso" | "limbs";
  poseConfidence?: number;
  origin?: [number, number, number];
  direction?: [number, number, number];
  firedAtClient: number;
};
```

### Fire-shot response

```ts
type FireShotResult = {
  accepted: boolean;
  outcome: "miss" | "hit" | "kill" | "rejected";
  rejectReason?: string;
  damage: number;
  shooterAmmo: number;
  targetHealth?: number;
  targetLifeState?: "alive" | "dead" | "respawning";
};
```

### Targeting interface

The targeting module must expose an observable latest solution similar to:

```swift
struct AimSolution: Equatable {
    let capturedAt: TimeInterval
    let zone: HitZone
    let confidence: Float
    let crosshairPoint: CGPoint
}

protocol TargetingEngineProtocol: AnyObject {
    var latestSolution: AimSolution? { get }
    var trackingState: TrackingState { get }
    func start()
    func stop()
}
```

Do not pass raw Vision objects outside the targeting module.

## 10. Build sequence

### Phase 1 — Shells and contracts

Produce:

- iOS navigation and placeholder HUD;
- Convex schema skeleton;
- spectator shell;
- shared constants and DTO names;
- Figma low-fidelity frames.

Exit gate:

- all targets build;
- contracts are committed;
- ownership boundaries are recorded.

### Phase 2 — Network vertical slice

Build the smallest complete multiplayer loop before computer vision:

1. Host creates match.
2. Guest joins.
3. Both subscribe to the same match snapshot.
4. Host starts match.
5. A temporary debug fire button on Phone A sends `shots:fire` against Phone B.
6. Phone B health changes.
7. Spectator dashboard displays the same health and event.

Exit gate:

- one physical phone can damage the other through Convex;
- duplicate shot ID is idempotent;
- health agrees on two phones and browser.

Do not remove the debug fire path until Vision has replaced it successfully.

### Phase 3 — Markerless targeting

Implement:

- ARKit rear-camera session;
- one in-flight Vision request;
- 8–12 Hz detection rate;
- portrait coordinate conversion;
- debug overlay;
- torso polygon first;
- head ellipse second;
- limb capsules third;
- crosshair lock and stable-aim threshold;
- pose age and confidence validation.

Exit gate:

- on a physical phone, the rendered debug region aligns with a real opponent;
- crosshair produces a torso solution repeatedly at 3–8 metres;
- no visible marker is used.

### Phase 4 — Gameplay completion

Replace the debug fire path with the aim solution and add:

- trigger interaction;
- local muzzle/tracer effect;
- sound and haptics;
- ammo;
- cooldown;
- reload;
- target damage flash;
- death overlay;
- K/D;
- respawn;
- match timer and winner.

Exit gate:

- complete acquire/fire/damage/kill/respawn loop works five times.

### Phase 5 — Arena telemetry

Implement:

- create-arena location and radius;
- Haversine distance;
- inside/warning/uncertain/outside states;
- weapon lock outside arena;
- location/heading heartbeat throttled to approximately 2–5 Hz;
- clearly labelled host demo override for unusable indoor GPS.

Exit gate:

- boundary lock works outdoors, or the runbook explicitly documents indoor override.

### Phase 6 — Spectator and dual POV

Complete:

- two player cards;
- health/ammo/KD;
- SVG/Canvas radar;
- heading arrows when available;
- recent event feed;
- match timer;
- winner overlay;
- OBS scene containing Phone A, Phone B, and dashboard.

Exit gate:

- a third person can understand the match by watching only the projected composition.

### Phase 7 — Presentation and freeze

At least 40 minutes before judging:

- stop implementing features;
- run the soak test;
- record a backup demo;
- export/finalize the six-slide presentation;
- rehearse the live sequence twice;
- write exact recovery steps in `docs/runbook.md`.

## 11. Targeting implementation requirements

### Frame pipeline

- Use ARKit frames as the camera source.
- Process Vision away from the main thread.
- Allow only one Vision request in flight.
- Start at 10 Hz and profile both phones.
- Keep rendering at display refresh rate using the latest pose.
- Discard stale results.
- Convert Vision normalized coordinates to the actual aspect-filled preview coordinates correctly.

### Head region

- Prefer visible eyes, ears, nose, and neck with confidence at least `0.6`.
- Derive scale from shoulder distance.
- If face landmarks are unavailable, estimate the head above the neck from shoulder width.
- Face detection is optional refinement, never a requirement.
- Do not turn on the target phone's front camera.

### Torso region

- Prefer a polygon through both shoulders and both hips.
- Permit a fallback using shoulders plus root/one hip.
- Require confidence at least `0.45`.

### Limbs

- Build capsules for shoulder–elbow, elbow–wrist, hip–knee, and knee–ankle segments.
- Use shoulder width to scale capsule thickness.

### Hit rules

- Crosshair is the centre of the actual displayed preview.
- Pose must be no older than 200 ms.
- Prefer head over torso over limbs on overlap.
- Require the zone to remain stable for two observations or about 80 ms.
- No region under the crosshair means miss.
- In P0, the detected person maps to the only other player in the duel.

### Shooter ray

Capture with each trigger:

```text
origin = camera transform translation
direction = normalized negative camera Z axis
firedAt = monotonic client timestamp
```

The P0 hit is still determined by screen-space body intersection. Preserve the ray for tracer rendering, telemetry, and future shared-space validation.

## 12. Convex requirements

Convex must be the authoritative owner of health, ammo, K/D, life state, match phase, cooldown, respawn timing, and shot history.

Required tables:

- `matches`
- `players`
- `shots`
- `events`

Required indexes:

- match by code;
- players by match;
- shots by match/time;
- shots by shooter/client shot ID;
- events by match/time.

Required functions:

```text
matches:create
matches:join
matches:setReady
matches:start
matches:end
players:heartbeat
players:startReload
shots:fire
queries:matchSnapshot
queries:spectatorSnapshot
internal.matches:activate
internal.matches:finish
internal.players:completeReload
internal.players:respawn
```

The `shots:fire` mutation must:

1. authenticate the match-scoped player secret;
2. enforce idempotency;
3. validate match phase and timing;
4. validate shooter alive/in-zone/ammo/cooldown;
5. validate target is the only opponent and alive;
6. ignore any client-provided damage amount;
7. apply server-owned zone damage;
8. update kill/death/respawn atomically;
9. schedule respawn when a kill occurs;
10. write shot and event records;
11. return the authoritative result.

Sanitized queries must never expose session hashes, secrets, or raw device identifiers.

## 13. Anonymous session requirements

Do not confuse “no permanent account” with “no player identity.”

Implement:

1. Random device ID stored in Keychain.
2. Player display name.
3. Random match-scoped session secret created by client.
4. Hash stored in the Convex player record.
5. Player document ID returned on create/join.
6. Secret required for player-controlled mutations.
7. Reconnection from Keychain after app restart.

Do not build login, email, password, OAuth, or profile management.

Generate secrets with `SecRandomCopyBytes`, hash them with CryptoKit on iOS, and use a deterministic Convex-compatible pure-JavaScript SHA-256 implementation such as `@noble/hashes` for backend verification. Do not introduce Node-only crypto into standard Convex mutations.

## 14. Geofence requirements

- Use Core Location only to determine arena membership and spectator position.
- Never use GPS to determine a body hit.
- Use the Haversine formula.
- Require consecutive accurate samples before declaring outside.
- Add about 5 metres of hysteresis.
- Treat poor accuracy as uncertain.
- If the venue is indoors, add a host-controlled demo override and label it honestly.

## 15. Spectator requirements

The spectator is read-only and optimized for a projector.

It must show:

- player names;
- health bars;
- ammunition;
- kills and deaths;
- match timer and phase;
- arena circle;
- normalized player positions;
- heading arrows if available;
- live shot/hit/elimination/respawn events;
- connection state;
- winner.

Do not add a paid map SDK. Convert latitude/longitude to local east/north metre offsets and render a radar.

## 16. Figma and UI workflow

Time-box Figma to 30 minutes for the initial pass.

Create frames for:

1. Home.
2. Create arena.
3. Join.
4. Lobby.
5. Shooter HUD.
6. Dead/respawn overlay.
7. Final scoreboard.
8. Spectator dashboard.

Use:

- black/dark background;
- white typography;
- cyan neutral telemetry;
- amber target acquisition;
- red hit/damage/danger;
- green ready/connected;
- monospaced numeric labels;
- large readable projector-scale telemetry;
- no realistic firearm styling.

Backend and camera work must proceed from the written contract while visual details are being approved.

## 17. Presentation requirements

Create a six-slide narrative:

1. **The idea:** turn any controlled field into an AR arena.
2. **The problem:** laser tag requires specialized venues and hardware.
3. **The demo:** both phone POVs plus the live Convex command centre.
4. **How it works:** Vision, ARKit, Convex.
5. **Why Convex:** atomic state, realtime subscriptions, shot ledger, spectator sync.
6. **The future:** shared AR multiplayer, UWB, haptic shell, safe event arenas.

Use this closing line:

> Today we made two phones understand a battlefield. Next, we turn the whole event into one.

Do not overstate anti-cheat or markerless multi-person identity. State that P0 is a duel and that shared spatial association is the next step.

## 18. Dual-phone demonstration

Create an OBS scene:

```text
top-left: Player One iPhone POV
top-right: Player Two iPhone POV
bottom: Convex spectator dashboard
```

Preferred mirroring plan:

- tested multi-device AirPlay receiver into separate windows;
- OBS captures each phone window and browser dashboard.

Fallback:

- one phone via QuickTime/USB;
- one phone via AirPlay;
- pre-recorded 30–60 second backup demo.

Do not spend core development time implementing WebRTC.

## 19. Test gates

### Backend

Test:

- full match rejection;
- start requires two ready players;
- firing outside running state rejected;
- duplicate shot idempotency;
- ammo never negative;
- cooldown enforcement;
- damage controlled by server;
- atomic kill/death update;
- dead player cannot shoot;
- early respawn rejected;
- player secret cannot control opponent;
- spectator query leaks no secret fields.

### Targeting

Test:

- coordinate conversion;
- head construction and fallback;
- torso polygon;
- limb capsules;
- zone priority;
- stale pose rejection;
- low-confidence rejection.

### Physical devices

Test:

- opponent facing camera;
- opponent sideways;
- opponent facing away;
- partial body;
- 3, 5, and 8 metres;
- fast pan then stable aim;
- one unrelated person in background;
- temporary network disconnect;
- five consecutive kill/respawn loops.

## 20. Risk controls

If behind schedule, cut features in this order:

1. face refinement while keeping the pose-derived head fallback;
2. detailed limb geometry;
3. spectator heading arrows;
4. reload animation;
5. geofence polish;
6. head region, while retaining markerless torso detection.

Never cut:

- two physical phones;
- Convex authoritative health/ammo/KD;
- markerless Vision body detection;
- complete kill/respawn loop;
- spectator realtime proof;
- reliable presentation composition.

## 21. Prohibited scope expansion

Do not implement these until every P0 acceptance test passes:

- shared ARKit collaborative coordinates;
- 3+ player targeting;
- UWB;
- projectile velocity;
- pose-history rewinding;
- WebRTC;
- persistent accounts;
- citywide drops;
- physical accessory integration;
- App Store submission.

You may document their interfaces and roadmap, but do not code them on the critical path.

## 22. Work reporting

Maintain a concise build log with:

- current gate;
- what works on physical devices;
- what is mocked;
- blockers;
- next integration step;
- features cut or deferred.

Do not report a feature complete because it compiles in a simulator. Camera targeting, networking, haptics, geofence, and mirroring require physical-device evidence.

When an agent finishes a subtask:

1. inspect its diff;
2. run its tests;
3. integrate immediately;
4. build the affected target;
5. verify on at least one physical phone when applicable;
6. only then mark the gate complete.

## 23. Immediate first response

Begin by reporting:

1. repository state;
2. exact Mac/Xcode/iPhone assumptions discovered or still missing;
3. whether both physical-device builds and signing are ready;
4. whether Convex credentials/deployment are ready;
5. the proposed agent ownership map;
6. the first two-hour vertical-slice plan;
7. any decision that requires the human immediately.

Then execute the preflight. Do not begin with speculative architecture work or slide design.
