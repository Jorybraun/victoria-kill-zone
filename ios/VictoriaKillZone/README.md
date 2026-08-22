# VictoriaKillZone iOS G2 networking slice

The app uses Convex as the authoritative source for create, join, ready, start,
match snapshots, and the host-only debug-fire path. If no valid deployment URL
is injected, it deliberately falls back to the local shell so an unconfigured
build remains safe and usable. Camera capture, targeting, location reads,
signing, and deployment are separate workstreams.

## Module contracts

| Module | Responsibility and state owner | Public contract | Dependencies / prohibited dependencies | Failure and recovery | Verification |
| --- | --- | --- | --- | --- | --- |
| `Domain` | Own valid lobby transitions and framework-free authoritative match/session models. | `LobbyAction`, `LobbyRoute`, snapshots, typed `LobbyTransitionError`. | Foundation only. No SwiftUI, provider SDK, storage, or network calls. | Reject invalid actions without changing state; `.leave` recovers to home. | Deterministic state-machine tests. |
| `Features` | Render typed state and translate taps into typed intents. `LobbyStore` owns subscription lifecycle and reconciliation. | SwiftUI views plus `LobbyStore` intents. | Depends on Domain and `AppEnvironment`; never calls a provider SDK directly. | A stale connection locks match input; a fresh snapshot atomically replaces state before recovery. | Deterministic store/retry/recovery tests plus unsigned simulator compile. |
| `Services` | Implement the authoritative match-service boundary. | `GameSessionClient` plus `ConvexGameSessionClient`. | `ConvexMobile` is confined to the adapter and private wire DTOs. | Typed failures never expose raw backend text; `UnavailableGameSessionClient` fails closed with `notConfigured`. | Frozen-function-name and adapter compile tests. |
| `Targeting` | Define the future camera/pose session boundary. | `TargetingSession`, availability, snapshot, and typed failure. | No UI or networking. No ARKit/Vision implementation exists in this slice. | `UnavailableTargetingSession` fails closed and has an idempotent stop. | Future device/fixture tests. |
| `App` | Compose dependencies and select the root feature. | `AppEnvironment.liveOrShell`, `VictoriaKillZoneApp`. | Reads only the non-secret deployment URL build setting; no keys or credentials. | A missing, unresolved, or invalid URL selects the visible shell fallback. | App build and launch smoke test. |

Dependency direction is `SwiftUI views → LobbyStore → GameSessionClient / LobbyStateMachine`.
The Convex adapter points inward through `GameSessionClient`; the domain never
imports `ConvexMobile`.

## Configuration

Inject `CONVEX_DEPLOYMENT_URL` as a local or CI Xcode build setting. The app
copies that non-secret value into `Info.plist` and accepts only a resolved HTTPS
URL with a host. Do not commit an environment-specific endpoint, signing setting,
credential, device identifier, or session secret. No API key is required by this
client slice.

## Local verification

The protocol, state-machine, and store tests run as a host-side Swift package so
CI does not need to boot a simulator:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path ios/VictoriaKillZone
```

Compile the app and its XCTest bundle for an iOS 17+ simulator with:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project ios/VictoriaKillZone/VictoriaKillZone.xcodeproj \
  -scheme VictoriaKillZone \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/vkz-derived-data \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
```

Running the XCTest bundle on iOS additionally requires an installed simulator
runtime. Physical camera, location, haptics, live-deployment networking, and
signing remain separate evidence gates.
