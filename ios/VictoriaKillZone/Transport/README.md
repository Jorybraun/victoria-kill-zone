# CombatTransport (KIL-35 — combat transport v0)

An independently testable Swift package for the peer plane of the multiplayer
combat loop: Bonjour-discovered, host/relay Network.framework transport carrying
**latest-state pose datagrams** and a **reliable ordered fire/control channel**
for a 2–4 player set.

Declared exclusive write set: `ios/VictoriaKillZone/Transport/**`.

## Layering

The package is split so that everything that decides game-visible behaviour is
pure and deterministic, and the Network.framework code is a thin adapter with no
policy in it.

| Layer | Type | Testability |
|---|---|---|
| Frame codec (`TransportFrame`, `PoseFrame`, `ReliableEventFrame`) | pure value types | Tier 0 |
| Latest-state pose admission (`PoseInbox`) | pure state machine | Tier 0 |
| Reliable ordering/dedup (`ReliableEventOrderer`) | pure state machine | Tier 0 |
| Bounded queues (`PoseSendQueue`, `ReliableSendQueue`) | pure | Tier 0 |
| Host/relay membership + fire lock (`HostRelayTopology`) | pure state machine | Tier 0 |
| Instrumentation (`TransportStats`) | pure accumulator | Tier 0 |
| Session orchestration (`CombatTransportCore`) | pure, clock-injected | Tier 0/1 |
| In-process fabric + fault injection (`LoopbackFabric`, `FaultProfile`) | test double, seeded PRNG, virtual clock | Tier 1 |
| Network.framework adapter (`NetworkPeerLink`) | I/O binding only, queue-confined | compile + Tier 2 |
| Field harness (`TransportFieldHarness`) | callable by a device build | Tier 2 (human) |

`CombatTransportCore` never touches `Network`; `NetworkPeerLink` and
`LoopbackFabric` both satisfy the same `PeerLink` protocol. That is what makes
the fault-injection suite meaningful rather than a mock of itself.
The Network.framework binding delegates role, handshake, flow readiness, routing,
and send backpressure to the pure `PeerLinkStateMachine`; the binding only
translates Network callbacks and writes the selected flow.

The standalone package manifest is at
`ios/VictoriaKillZone/Transport/CombatTransport/Package.swift`; its sources and
tests are under that package directory. Keeping the manifest below the iOS
verification script's search depth preserves the app package test target.

## Topology

Host/relay, never a mesh, never a 1v1 pair assumption:

- Slots `0...3`; the host owns slot `0`. Player count is `2...4`
  (`SimulationConstants.playerCapacityMin/Max` in the simulation core).
- A client's only outbound peer is the host. `HostRelayTopology.outboundRoute`
  for a client is exactly `[hostSlot]` regardless of player count.
- The host forwards each received frame to every other `active` slot, excluding
  the origin slot and itself (`relayTargets(from:)`), setting the `relayed` flag
  and preserving the original sender slot in the header.

## Wire format (`transport-frame.v1`, little-endian)

Header, 8 bytes:

| Field | Type | Notes |
|---|---|---|
| magic | UInt16 | `0x564B` |
| version | UInt8 | `1` |
| kind | UInt8 | `1` pose, `2` reliable event, `3` authenticated slot claim |
| epoch | UInt16 | session epoch; bumped on (re)join to invalidate old sequences |
| senderSlot | UInt8 | `0...3`, the *original* sender even when relayed |
| flags | UInt8 | bit0 `relayed`; other bits must be zero |

Pose body, 41 bytes (best-effort channel):

`sequence UInt32` (starts at 1, strictly increasing per sender per epoch),
`timestampMs Int64` (match clock, strictly positive and strictly increasing),
`position 3 × Float32`, `orientation 4 × Float32` (unit quaternion),
`tracking UInt8` (`0` normal, `1` lost).

Reliable event body (reliable ordered channel):

`sequence UInt32` (starts at 1, contiguous per sender per epoch),
`eventKind UInt8` (`1` fire, `2` control), `payloadLength UInt16` (`≤ 512`),
`payload payloadLength bytes` — **opaque** to this package. Fire/control DTOs
belong to the shared contracts owned by Integration; the transport deliberately
carries bytes so it does not couple to `match.v2` shapes.

Slot-claim body (reliable handshake channel, kind `3`):

`claimedSlot UInt8`, `nonce UInt32`, `digest 32 × UInt8`. The digest is
`SHA256(preSharedKey ‖ nonce ‖ claimedSlot)` with the nonce encoded
little-endian. The pre-shared key is never transmitted. A host keeps each
accepted connection pending until a valid claim binds it to one distinct client
slot in `1...3`; later frames must use that bound sender slot.

Decoding is strict and total: every malformed input throws a typed
`TransportCodecError` (`magicMismatch`, `unsupportedVersion`, `unknownFrameKind`,
`truncated`, `trailingBytes`, `slotOutOfRange`, `reservedFlagSet`,
`payloadTooLarge`, `payloadLengthMismatch`, `zeroSequence`,
`nonPositiveTimestamp`, `invalidTracking`, `nonFiniteComponent`) and never traps.

## Latest-state and reliable semantics

- **Pose (best-effort).** A pose frame is admitted only if its epoch matches and
  both its sequence and its timestamp strictly advance that sender's last
  admitted values. Duplicates, replays, and out-of-order arrivals are discarded
  with a typed reason and counted. Nothing older than the newest admitted sample
  ever reaches the simulation core.
- **Fire/control (reliable ordered).** QUIC gives us reliability and per-stream
  ordering, so the loopback fault model injects delay, jitter, duplication and
  cross-relay reordering on this channel — not loss. Connection loss is modelled
  separately as a peer-down event. `ReliableEventOrderer` delivers strictly in
  ascending sequence, buffering up to `maxPendingReliableEvents` future frames
  and suppressing duplicates; a gap that cannot be closed within that bound is an
  `unrecoverableGap`, which engages the fire lock and requires an epoch resync
  rather than silently skipping an event.

## Fire lock (deterministic)

Engaged, as an emitted effect, when any of: an expected peer is `disconnected`,
a reliable gap is unrecoverable, the reliable send queue is full, or (as a
client) the host link is down. Released only when every expected peer is
`active`, all reliable channels are in order, and both queues are at or below
their low-water mark. Effects are returned from `advance(nowMs:)` so tests
assert exact effect sequences instead of polling state.

The documented low-water mark is one queued frame per channel. Callers may
override it for deterministic fixtures, but the default is `1`.

## Backpressure

- `PoseSendQueue` (capacity 3) drops the **oldest** sample on overflow —
  latest-state wins — and counts `posesDroppedForFreshness`.
- `ReliableSendQueue` (capacity 128) never drops: overflow returns
  `.rejectedQueueFull` and engages the fire lock.

## Instrumentation

`TransportStats.sanitizedSnapshot()` emits `transport-stats.v0`: per-channel and
per-**slot** counters (sent/received/accepted/discarded/duplicate/buffered),
sequence-gap loss percent, inter-arrival jitter (p50/p95 over a fixed 128-sample
ring), send→receive milliseconds (p50/p95, with an explicit clock-source label),
disconnect/recovery counts and total fire-locked milliseconds.

On loopback, virtual send and receive clocks are comparable, so send→receive
percentiles are populated. On a physical device, the receive handler has no
comparable remote send clock and reports `nil` for those percentiles rather than
fabricating zero-latency values. Arrival-delta jitter and cadence remain
measurable on device; percentile fields remain absent until enough samples exist.

No device names, no UDIDs, no addresses, no Bonjour service names, no secrets:
the API is addressed by slot index, so there is no surface through which an
identifier could enter the snapshot. A test pins the exact key set.

## Network.framework adapter

Network.framework only; no MultipeerConnectivity.

- Hosts advertise `NWListener(service:using:)`; clients browse
  `NWBrowser(for: .bonjour(...))` on `_vkz-combat._udp`, with
  `parameters.includePeerToPeer = true`. Clients select only an exact
  `serviceToken` match and keep browsing when no match is present.
- QUIC (`NWProtocolQUIC.Options`, ALPN `vkz-combat-v1`): an `NWMultiplexGroup`
  for the reliable fire/control stream, plus one datagram flow
  (`options.isDatagram = true`, `maxDatagramFrameSize = 512`) for poses. Verified
  present in the pinned SDK (`NWProtocolQUIC.Options.isDatagram`,
  `maxDatagramFrameSize`, `nw_quic_get_stream_usable_datagram_frame_size`).
- TLS via a caller-supplied match-scoped pre-shared key
  (`TransportCredentials`), so no signing material and no committed secret. The
  advertised service name is a match-scoped random token, never a device name.
- Foreground drop: path/connection failure marks the peer disconnected and locks
  fire; recovery re-forms the link and bumps the epoch, with no app restart.

## Tiers

- **Tier 0 (`swift test`)** — codec/validation, pose admission, reliable
  ordering, queues, topology, stats math.
- **Tier 1 (Outpost)** — `LoopbackFabric` fault-injection suites on a virtual
  clock with a seeded PRNG: 2- and 4-player host/relay fixtures, 5% pose loss,
  heavy jitter/reorder, peer loss and recovery, seed-stability of the stats
  snapshot.
- **Tier 2 (physical devices, human-run — NOT satisfied here)** — two-phone and
  four-phone outdoor cadence/loss/jitter. `TransportFieldHarness` exists to be
  called by a device build and to emit the sanitized stats artifact; simulator or
  loopback output never closes a Tier 2 checkbox.
