# Slice 005 — Shared combat and human skeleton hit presentation

Status: frozen implementation contract, 2026-09-05. Owner: integration. Implements the full-review decision in ADR 0008. Physical acceptance remains open.

Use the existing VKZ palette/type/spacing tokens. The camera remains the visual background during play. Reserve the screen center for a small crosshair and target acquisition feedback. Place health and match time at the top, the four-member score strip beneath it, and reachable fire/reload/shield/slow-field controls at the bottom. Each control has a plain accessibility label and communicates availability with text or a progress ring as well as color. Respect reduced motion and increased text size; authoritative geometry/timing never changes with graphics quality.

The skeleton is recognizable original 3D anatomy: skull/jaw, ribs/sternum, vertebral column, pelvis and limb bones. Retarget its rigid parts from observed skeletal landmarks. Missing observation hides the affected part. Neutral bone details are visual styling, never independently observed joints or collision evidence. Show this skeleton only for the confirmed hit window, on the identified target; keep the ordinary camera unobscured at other times. Keep a separate confirmed crosshair marker and incoming damage indicator. A provisional tracer is not a confirmed hit.

| State | Player-facing behavior | Enabled actions |
|---|---|---|
| Lobby | Callsign, invite/code, 2–4 roster, ready status and selected weapon rules | Host can begin when at least two and all joined players are ready/connected |
| Connecting | “Connecting to match” with cancellable progress | Leave |
| Mapping | “Scan the play area” and concrete mapping progress | Capture map when mapping is ready; leave |
| Relocalizing | “Find the same area” with camera, host map identity and retry | Retry after timeout; leave |
| Reference measurement | “Align the arena” with independent common-scene measurement guidance | Capture/verify the reference; leave. No fabricated zero-residual success |
| Awaiting members | “Waiting for players to align” and each member’s status | Host begins when all spatial gates pass |
| Running | Clear health/ammo/time/score; target association indicator; continuous finite projectile worldlines | Hold fire, reload, shield, slow field, leave subject to authoritative eligibility |
| Reloading | Remaining reload progress and ammo value | Shield/field if their rules allow; fire disabled |
| Shield active | Visible oriented phone shield and energy/time remaining | Fire disabled; shield can be released |
| Slow field active | Visible local sphere and remaining duration; projectiles change speed at its boundary | Player movement/camera remain normal; field cooldown visible |
| Tracking/clock/identity uncertain | “Tracking paused” with concrete recovery instruction | Recalibrate or leave; no spatial fire |
| Reconnecting | “Reconnecting” with retained scores and frozen input | Leave; reconnect uses a fresh authoritative snapshot |
| Eliminated | Respawn countdown; no fire | Look/move normally; leave |
| Finished | Ranked scores, personal hits/kills and replayable confirmed ledger when available | Return to lobby/home |

The backend owns cooldown, magazine, damage, protection, shield energy and field expiry. Render projectile position from authoritative spawn/segment parameters and synchronized match time. Never replay unknown elapsed flight after a disconnect. Reject stale/foreign epochs, ambiguous body association and absent tracked geometry.

Acceptance: automated lifecycle/geometry/protocol/recovery tests; real rendered anatomy review; complete native app compile; two/four-phone calibration and convergence; filmed hit/shield/slow-field controls; accessibility/permissions and sustained thermal/frame-time evidence. A synthetic anatomy render establishes visual form only.

## Bounded gameplay feedback refinement — 2026-09-05

Rejected player actions appear as brief inline feedback above the controls and are announced accessibly. They do not replace the live controls or turn a transient refusal into an unavailable arena. Begin shows a pending progress state until authority acknowledges it. Ammunition display accounts for submitted shots while authoritative state catches up; authority remains responsible for acceptance and reload totals.

Use friendly weapon names, never raw configuration identifiers. The local slow-field button displays its accepted active duration before its cooldown; other players' fields do not claim the local ability is active. Spawn protection has a remaining-time label, and reload shows a bounded progress bar plus remaining seconds. These displays use synchronized authority time and never alter gameplay durations.

Recovery distinguishes connection retry, timing synchronization, and alignment retry. Permanent admission/configuration failures show a safe explanation and a connection retry action. Camera Settings is offered only for a relevant permission problem. During an already-started match, tracking recovery can resume play automatically; initial match start remains a host action after alignment. The completion action says “Return home” because leaving clears the current session.

Reference capture and verification UI remain owned by the calibration integration; this refinement does not invent reference data or claim an aligned state.

## Multiplayer entry and lobby copy — 2026-09-05

The main entry identifies two-to-four-player arena play and offers Create arena / Join arena. The classic two-player path remains available under its existing debug gate, and Credits remains reachable. The home screen does not advertise a fixed round duration independently of the selected match state.

The waiting room uses “Arena” for the Durable Objects mode and “Classic duel” for the retained duel path, including invite and accessibility copy. Capacity and open-slot counts come from the room; round duration is shown only when the authoritative lobby snapshot supplies it. The current lobby model does not expose a selected weapon, so this slice does not invent a weapon/rules summary from duplicated defaults.

Place the code and sharing action in a compact panel, followed by the roster. The larger QR invitation is secondary, explicitly expandable content. Ready/start controls remain reachable at the bottom on ordinary text sizes; at accessibility text sizes they become normal scroll content so a tall fixed footer cannot hide the roster. Player status moves below the identity at large accessibility sizes. Explain the actual readiness blocker: too few players, disconnected players, unready players, or waiting for the host.

Create, ready, and start mutations expose their existing pending state. Codes can be copied and are read character by character by accessibility labels; sharing remains a deliberate user action. No cosmetic status dot claims a live connection before the app has one.
