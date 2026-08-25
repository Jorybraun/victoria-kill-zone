# Phone-to-Phone Real-Time Data Exchange for AR Laser Tag

## Research memo — co-located iPhones, 2-8 players, 20-30 Hz pose + fire events

---

## Executive summary

For a native iOS AR laser-tag game, the cleanest separation of concerns is:

* Use a network transport for pose and fire-event payloads.
* Use **unreliable / latest-state** semantics for high-rate pose transforms.
* Use **reliable delivery** for fire events and critical control messages.
* Avoid sending full `ARWorldMap` data during gameplay; use it only for initial joining / relocalization.
* Use ARKit collaboration data only when a shared spatial understanding is required, and keep a separate compact game-state channel for deterministic gameplay.
* Treat **Nearby Interaction / UWB** as an optional spatial/ranging aid, not as the primary data channel.
* Prefer **Network.framework** for new custom real-time networking because Apple’s current guidance deprecates `MultipeerConnectivity` and exposes UDP plus peer-to-peer controls.
* At 2–4 peers a direct mesh is operationally manageable; at 8 peers the full-mesh traffic and ARKit collaboration guidance become more concerning.
* A host/relay topology is usually simpler for authoritative fire-event handling and reduces connection fan-out, but adds a central failure point and an extra forwarding hop.

---

## 1. Transport options

### 1.1 MultipeerConnectivity

`MultipeerConnectivity` is a high-level framework for peer discovery and data exchange over nearby links [1].

* **Transports on iOS:** infrastructure Wi-Fi, peer-to-peer Wi-Fi, and Bluetooth personal area networks [1].
* **Data model:** message-based data, streaming data, and resources [1].
* **Session limit:** an `MCSession` supports **up to 8 peers, including the local peer** [2].
* **Send modes:**
  * `reliable` — guaranteed delivery, queued/retransmitted as needed, in-order [3].
  * `unreliable` — sent immediately without socket-level queueing; messages that cannot be sent immediately are dropped, and order is not guaranteed [3].
* **Backgrounding:** when the app moves to the background, the framework stops advertising/browsing and disconnects open sessions. On returning to the foreground it automatically resumes advertising/browsing, but the app must re-establish sessions [1].
* **API model:** all peers are equal and the framework builds a fully connected mesh. Delegate callbacks run on a private operation queue [2].
* **Deprecation status:** `MultipeerConnectivity` is deprecated as of the current Apple networking guidance; Apple recommends avoiding it in new code and considering migration to `Network.framework` [5][6].

For pose+fire events this means: the 8-peer cap matches the requested “up to ~8” scale, and the two send modes map directly to the classic latest-state (unreliable) vs. reliable event pattern. The main concerns are the deprecation, the background disconnection, and the lack of control over transport selection or framing.

### 1.2 Network.framework peer-to-peer

`Network.framework` provides direct access to TLS/TCP, UDP, DTLS, and QUIC, and is the modern Apple path for custom real-time protocols [4][5].

* **Peer-to-peer Wi-Fi:** opt-in via `NWParameters.includePeerToPeer` [7][8]. The on-the-wire Apple peer-to-peer protocol is not documented for third-party use and only works between Apple devices [5].
* **Bonjour discovery:** `NWEndpoint.service(name:type:domain:interface:)` lets a connection target a Bonjour service [9]; `NWBrowser` / `NWListener` discover and advertise services [6]. Bonjour is designed to work without network infrastructure using link-local addressing, multicast DNS, and DNS-SD [5].
* **UDP support:** `NWParameters.udp` and `NWParameters(dtls:udp:)` provide best-effort datagram channels [7]. UDP broadcast is not supported; UDP multicast is available through `NWConnectionGroup` but requires the `com.apple.developer.networking.multicast` entitlement and local-network access on iOS [5].
* **Reliable options:** QUIC is recommended as the default reliable protocol. A QUIC connection supports multiple reliable streams **and** at most one best-effort datagram channel, which can be used for low-latency latest-state data [6]. TCP and TLS provide a single reliable stream; setting up a parallel UDP datagram channel is possible but more work [6].
* **Architecture flexibility:** `Network.framework` supports client-server as well as fully connected topologies. A client-server design uses one `NWListener` as the server and `NWConnection` per client; a fully connected design runs a listener and an outbound connection to every other peer [6].
* **Message framing:** stream protocols do **not** preserve message boundaries; the app must add framing (e.g. `TLV` or `Coder`) [6].
* **Performance note:** enabling peer-to-peer Wi-Fi can reduce network performance for the app and for other apps on the device; Apple says to stop browse/listen operations as soon as they are not needed [6].

Comparison with `MultipeerConnectivity`:

| Capability | MultipeerConnectivity | Network.framework |
|---|---|---|
| Status | Deprecated [5][6] | Modern / preferred [5] |
| P2P Wi-Fi | Yes (opaque) | Opt-in via `includePeerToPeer` [8] |
| Discovery | Built-in | Bonjour / `NWBrowser` [6][9] |
| Reliable stream | `send(...with: .reliable)` [3] | QUIC / TCP / TLS [6][7] |
| Best-effort datagram | `send(...with: .unreliable)` [3] | UDP / QUIC datagram [6][7] |
| Peer limit | 8 incl. local [2] | No Apple-documented hard cap |
| Framing | Message-based | App must frame streams [6] |
| Background | Disconnects [1] | App-managed; no auto-reconnect |

Network.framework is the better long-term choice if the team is willing to implement discovery, peer IDs, framing, and reliability policy.

---

## 2. ARKit collaborative sessions and world maps

### 2.1 How collaboration works

* Enabling `ARWorldTrackingConfiguration.isCollaborationEnabled` makes ARKit periodically emit `ARSession.CollaborationData` [10][11].
* Collaboration data contains detected real-world surfaces, the user’s position relative to them, created anchors, and participant information [10].
* The **app** is responsible for serializing and transmitting it over a network of its choice, and for deserializing and calling `ARSession.update(with:)` on the receiving side [10][12][13].
* For optimum performance, participants should be on the same OS version; unarchiving data from a different OS version may fail [10].
* Apple recommends using **reliable** transport for data with `priority == .critical` and **unreliable** for optional data [10][14].

### 2.2 Participant counts and best practice

* Apple states: “**Collaborative sessions work best with up to four participants.**” This is guidance, not a hard limit [10].
* The older “Creating a multiuser AR experience” sample supports “two or more” iOS 12 devices, but that is not an upper bound [15].

### 2.3 World-map sharing and relocalization

* `ARWorldMap` captures ARKit’s spatial mapping state and anchors. It can be archived, sent over the network, and assigned to `ARWorldTrackingConfiguration.initialWorldMap` to start a session from a saved state [16][17].
* To merge worlds, ARKit must recognize overlap between the two devices’ views. Apple’s guidance: ask users to hold devices side by side so both cameras observe overlapping areas [13].
* Relocalization works best when the sender has thoroughly scanned the environment and the receiver is placed next to the sender or otherwise sees a similar area [15].
* `ARParticipantAnchor` is added to the session for every user ARKit detects, providing the peer’s world position [18].
* World-map capture and transmission are “**time-consuming, bandwidth-intensive operations**,” so Apple recommends doing them **once** when a new device joins, then sending only compact action/pose data during the ongoing session [15].

### 2.4 Outdoor / no-infrastructure operation

* ARKit world tracking is camera- and visual-feature-based [19]. It can run anywhere the camera has enough texture, contrast, and light, but Apple documentation does not specifically address outdoor performance.
* For network transport, both `MultipeerConnectivity` and `Network.framework` support **peer-to-peer Wi-Fi and Bluetooth**, so no Wi-Fi access point or cellular infrastructure is required [1][5][8].
* The practical limitation outdoors is therefore likely **AR tracking reliability** (rapid motion, changing lighting, feature-poor or highly dynamic scenes, glare, heat shimmer) rather than the network transport. No official Apple benchmark for outdoor ARKit collaboration was found.

---

## 3. SwiftShot design evidence

Apple’s WWDC 2018 AR sample **SwiftShot** (an unofficial but apparently verbatim GitHub mirror of the Apple sample project’s README was found) used `MultipeerConnectivity` and an `ARWorldMap` for a 2-6 player game [20].

Key design points directly relevant to a laser-tag game:

* **Action queue / host-authoritative game events:** `GameManager` maintains a list of `GameCommand` objects. The local peer serializes a `GameAction` enum and sends it through the multipeer session; each peer decodes received actions and adds them to its local queue [20].
* **Rendering loop timing:** `GameManager` updates game state on each SceneKit rendering loop pass (60 frames per second), removing commands in the order received and applying their effects [20].
* **Physics synchronization:** because `SceneKit` simulates physics on only one device, SwiftShot designates the **host peer** as the source of truth. The host continually sends **minimal physics state** to other peers: position, orientation, velocity, angular velocity, and an in-motion flag. It sends updates only for bodies relevant to gameplay and only when their state changed [20].
* **Domain-specific compression:** `PhysicsNodeData` / `PhysicsPoolNodeData` encode physics state to a compact binary representation, e.g. position in 48 bits and orientation in 38 bits [20].
* This shows a proven pattern for your use case: one reliable-ish control stream for actions, a separate compact binary state stream, and a host for authoritative physics/ hit detection.

---

## 4. Nearby Interaction / UWB

### 4.1 What it provides

* Nearby Interaction reports **distance** and **direction** to nearby UWB-capable Apple devices, not a general-purpose game payload [21][22][23].
* It is supported by devices with a UWB chip, such as **iPhone 11 and later** and Apple Watch, subject to runtime `NIDeviceCapability` checks [21][24].
* One `NISession` represents one nearby object; multiple peers require separate sessions [22].
* To start a session, the app must discover peers and exchange `NISession.discoveryToken` over a separate network (e.g. `MultipeerConnectivity`, Core Bluetooth, LAN, or a server) [25][26].

### 4.2 Ranging performance and limitations

* Apple recommends best operation: devices within **~9 meters**, in **portrait** orientation, with their **back cameras facing each other** and a **clear line of sight** [25].
* Direction is reported only inside a narrow line-of-sight cone and is `nil` when the peer is out of line of sight or out of range [25][23].
* **Camera Assistance** (`NINearbyPeerConfiguration.isCameraAssistanceEnabled`) combines ARKit’s 6-DOF spatial model with UWB to widen the range of environmental conditions where distance and direction are available, and adds `horizontalAngle` and `verticalDirectionEstimate` [27][28].
* `NISession.setARSession(_:)` and `NISession.worldTransform(for:)` return a transform in ARKit’s world coordinate space so that virtual content can be overlaid on the peer’s physical position [29][30].
* In the foreground, ranging is freely available. In the background, UWB ranging is limited to devices that are BLE-paired/connected, or with a Live Activity on iOS 18.4+ and the “Uses Nearby Interaction” background mode [21].

### 4.3 Measured UWB update rates (academic source)

Apple does not publish an official UWB sampling rate for `NINearbyObject`. A credible ACM UIST paper (SmartPoser) reported:

* Distance updates from the Nearby Interaction API at approximately **5 Hz** between an iPhone 13 Pro and an Apple Watch Series 7 [31].
* iPhones can offer higher sampling rates and azimuth/elevation readings when a UWB peer is inside a narrow cone-shaped field of view, but that cone was too narrow for the study’s use case [31].
* The same study’s **application-level** arm-pose result had a median positional error of **11.0 cm**, and a UWB correction model reduced one body-occlusion example’s mean error from **34.5 cm to 6.7 cm** [31].

These are study-specific results, not universal Apple transport guarantees, and they should not be presented as Apple’s official UWB precision. They do confirm that UWB distance updates are on the order of a few hertz, not comparable to a 20-30 Hz network game loop.

---

## 5. Latency, throughput, and update-rate evidence

### 5.1 No official Apple latency guarantee

Apple documentation defines transport **modes** and **APIs** but does **not** provide a general guaranteed latency figure for `MultipeerConnectivity`, `Network.framework`, or AWDL. Any 20-30 Hz target should be treated as an implementation-validation requirement, not as a documented platform property. The recommended next step is to measure on target devices, in the actual venue, with timestamped send/receive and loss/jitter metrics.

### 5.2 Credible measured data for the underlying link

A 2018 reverse-engineering study of the Apple Wireless Direct Link (AWDL) peer-to-peer Wi-Fi protocol found:

* AWDL uses an **accepted synchronization error of 3 ms** [32].
* A **channel-switch operation takes at least 8 ms** [32].
* Maximum throughput is limited by the device’s supported **PHY data rate** when nodes are not simultaneously using an infrastructure network [32].
* When a node must switch between an AP channel and the AWDL channel, the cumulative throughput of two concurrent connections drops by about **13%** [32].

These numbers bound the **physical/link-layer** overhead. They do not predict end-to-end application latency, but they confirm that small, frequent datagrams on an idle P2P Wi-Fi link should be able to meet a 20-30 Hz cadence, while heavy contention or channel switching will add jitter and reduce throughput.

### 5.3 Update rate summary

| Source / mechanism | Kind of number | Credible value / claim |
|---|---|---|
| Nearby Interaction UWB distance (SmartPoser, iPhone 13 Pro ↔ Apple Watch) | UWB sampling rate | ~5 Hz [31] |
| AWDL channel switch | Physical/link overhead | ≥ 8 ms [32] |
| AWDL accepted sync error | Physical/link overhead | 3 ms [32] |
| SwiftShot GameManager | Game-state update cadence | 60 fps rendering loop [20] |
| ARKit collaboration data | Periodically emitted; app transports it | No fixed Apple rate; observed to be event/burst-driven [10] |

For a 20-30 Hz pose+fire event exchange, the bottleneck is not the radio when on P2P Wi-Fi; it is more likely **serialization, queueing, reliability policy, and ARKit-to-network timing**.

---

## 6. Failure modes and scaling behavior

### 6.1 Backgrounding and lifecycle

* `MultipeerConnectivity` **stops advertising/browsing and disconnects sessions** when the app backgrounds; sessions must be re-established on foreground [1].
* `Network.framework` does **not** automatically tear down a connection on backgrounding, but iOS may suspend the app and its sockets; keeping connections or listeners alive in the background requires an appropriate background mode and is app-managed (inferred, not an explicit Apple claim).
* ARKit sessions should be paused (`ARSession.pause()`) when not needed [19]; when the app is not in the foreground the camera feed is not available, so world tracking effectively stops (inferred).
* Nearby Interaction UWB ranging is foreground-only except for BLE-paired/connected peers or Live Activity use [21].

For a real-time game, all of these mean the experience is effectively **foreground-only**; any phone that locks, goes to the app switcher, or receives a call will drop out of the game.

### 6.2 Range, line of sight, and occlusion

* Nearby Interaction: 9 m ideal, direction lost outside the line-of-sight cone or when blocked by people/walls [25]. Body occlusion can add tens of centimeters of UWB error before correction [31].
* Multipeer/Network P2P Wi-Fi and Bluetooth: typical indoor ranges of a few meters to tens of meters, depending on obstacles and interference. If devices fall back to Bluetooth PAN, throughput drops sharply.
* ARKit tracking itself degrades with poor lighting, motion blur, reflective/glossy/dark/textureless surfaces, and moving objects in the scene.

### 6.3 Interference and channel switching

* AWDL channel switching to stay connected to an AP while doing P2P can reduce aggregate throughput by ~13% [32].
* Nearby Wi-Fi networks, Bluetooth traffic, microwave ovens, and human bodies can all increase packet loss and jitter on the unlicensed bands.
* `MultipeerConnectivity` may switch transports underneath the app; `Network.framework` lets the app select the protocol and observe the current `NWPath`, but the link layer is still managed by the OS.

### 6.4 Peer-count scaling and mesh traffic

* `MCSession` hard cap: **8 peers including the local peer** [2].
* ARKit collaboration: Apple recommends up to **4 participants for best results** [10]. This is guidance, not a hard cap, and it does not mean 8 players are ideal for ARKit collaboration.
* In a **full mesh**, if every peer sends every pose update directly to every other peer, the number of directed streams is `N(N-1)`. At 8 peers that is **56 directed streams** (inferred, not an Apple claim). This is the most important scaling concern for a 20-30 Hz latest-state protocol.
* A **host/relay** topology reduces connection count to `N-1` client↔host connections and lets one device arbitrate fire events and world state. It introduces a single point of failure and an extra forwarding hop.
* SwiftShot’s design suggests a hybrid: a host for authoritative physics, plus a compact binary state representation, plus separate queues for actions [20].

---

## 7. Recommendations for the AR laser-tag prototype

1. **Transport:** Use `Network.framework` with `includePeerToPeer`, Bonjour discovery, and **QUIC + datagrams** or **DTLS/UDP** for latest-state pose data. Keep a reliable QUIC/TCP stream for fire events and session control. If the team wants the fastest path to a working prototype and is already familiar with it, `MultipeerConnectivity` can work, but it is deprecated and has stricter background behavior.
2. **Pose data:** send small, self-contained, latest-state pose datagrams at the rendering/update rate. Include sequence numbers and a timestamp. Use UDP/QUIC-datagram for low latency; do not require acknowledgements for every pose.
3. **Fire events:** send fire/ hit events on a reliable stream with sequence numbers. Have the host arbitrate hits to avoid race conditions.
4. **Shared AR space:** use `ARWorldMap` or `isCollaborationEnabled` to establish a shared frame once at join, then keep game state in your own compact binary messages. Do not transmit full ARKit collaboration data continuously.
5. **UWB:** optionally enable `isCameraAssistanceEnabled` + `setARSession(_:)` to improve spatial alignment and ranging, but keep the primary pose/fire channel on the network transport. UWB is too low-rate to carry 20-30 Hz game state.
6. **Scaling:** target 2–4 peers for the most reliable ARKit experience; up to 8 is technically possible for the network layer but mesh traffic, ARKit overhead, and real-world RF conditions will degrade. Consider a host/relay topology.
7. **Validation:** because Apple does not guarantee transport latency, instrument the actual build with per-message send/receive timestamps, one-way delay estimates, loss and jitter counters, and a graceful degradation path (e.g. interpolation, last-known-pose timeout).

---

## Evidence table

| # | Source | URL | Key claim | Type | Confidence |
|---|--------|-----|-----------|------|------------|
| 1 | Apple, *MultipeerConnectivity* framework overview | https://developer.apple.com/documentation/multipeerconnectivity | iOS uses infrastructure Wi-Fi, P2P Wi-Fi, and Bluetooth PAN; backgrounding stops advertising/browsing and disconnects sessions | primary | high |
| 2 | Apple, `MCSession` | https://developer.apple.com/documentation/multipeerconnectivity/mcsession | Sessions support up to 8 peers including the local peer; delegate callbacks run on a private queue | primary | high |
| 3 | Apple, `MCSessionSendDataMode` | https://developer.apple.com/documentation/multipeerconnectivity/mcsessionsenddatamode | Reliable: guaranteed, queued, in-order; Unreliable: immediate, may drop, no ordering | primary | high |
| 4 | Apple, `Network` framework overview | https://developer.apple.com/documentation/network | Direct access to TLS, TCP, UDP, custom protocols; use `URLSession` for HTTP | primary | high |
| 5 | Apple, TN3151 “Choosing the right networking API” | https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api | MultipeerConnectivity deprecated; Network.framework has P2P Wi-Fi; Bonjour works without infrastructure; UDP multicast needs entitlement / local-network access | primary | high |
| 6 | Apple, TN3213 “Moving from Multipeer Connectivity to Network framework” | https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework | Migration guide; send-mode mapping; client-server vs. mesh; QUIC + datagram best-effort; P2P Wi-Fi performance warning | primary | high |
| 7 | Apple, `NWParameters` | https://developer.apple.com/documentation/network/nwparameters | Default UDP, DTLS, QUIC, TCP parameters; `includePeerToPeer` toggles P2P links | primary | high |
| 8 | Apple, `NWParameters.includePeerToPeer` | https://developer.apple.com/documentation/network/nwparameters/includepeertopeer | Boolean enabling peer-to-peer link technologies | primary | high |
| 9 | Apple, `NWEndpoint.service(name:type:domain:interface:)` | https://developer.apple.com/documentation/network/nwendpoint/service(name:type:domain:interface:) | Endpoint represented as a Bonjour service | primary | high |
| 10 | Apple, `ARWorldTrackingConfiguration.isCollaborationEnabled` | https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/iscollaborationenabled | Collaborative sessions work best with up to four participants; app is responsible for network transport; priority hints at reliability choice | primary | high |
| 11 | Apple, `ARWorldTrackingConfiguration` | https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration | Tracks 6-DOF device movement | primary | high |
| 12 | Apple, `ARSession.update(with:)` | https://developer.apple.com/documentation/arkit/arsession/update(with:) | Call to update a session with received collaboration data | primary | high |
| 13 | Apple, “Creating a collaborative session” | https://developer.apple.com/documentation/arkit/creating-a-collaborative-session | Serialize collaboration data; merge requires overlapping camera views; hold phones side by side | primary | high |
| 14 | Apple, `ARSession.CollaborationData.priority` | https://developer.apple.com/documentation/arkit/arsession/collaborationdata/priority-swift.property | Hints whether to use reliable or unreliable transport for a given data instance | primary | high |
| 15 | Apple, “Creating a multiuser AR experience” | https://developer.apple.com/documentation/arkit/creating-a-multiuser-ar-experience | World-map share is time-consuming/bandwidth-intensive; use compact custom data afterward; two or more iOS 12+ devices | primary | high |
| 16 | Apple, `ARWorldMap` | https://developer.apple.com/documentation/arkit/arworldmap | Serialize/deserialize world map and set `initialWorldMap` | primary | high |
| 17 | Apple, `ARWorldTrackingConfiguration.initialWorldMap` | https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/initialworldmap | Start a session from an existing map | primary | high |
| 18 | Apple, `ARParticipantAnchor` | https://developer.apple.com/documentation/arkit/arparticipantanchor | Anchor representing another user’s world position after merge | primary | high |
| 19 | Apple, `ARSession.pause()` | https://developer.apple.com/documentation/arkit/arsession/pause() | Pauses AR processing | primary | high |
| 20 | GaoGuohao/SwiftShot (unofficial mirror of Apple WWDC18 sample README) | https://github.com/GaoGuohao/SwiftShot/blob/master/README.md | SwiftShot uses MultipeerConnectivity, ARWorldMap, action queue, 60 fps GameManager, host-authoritative physics, compact binary state, 2–6 players | secondary | medium |
| 21 | Apple, Nearby Interaction framework overview | https://developer.apple.com/documentation/nearbyinteraction | UWB devices such as iPhone 11+; distance/direction in foreground; background limited to BLE-paired/connected or Live Activity | primary | high |
| 22 | Apple, `NISession` | https://developer.apple.com/documentation/nearbyinteraction/nisession | One session per nearby object; `setARSession(_:)` for Camera Assistance | primary | high |
| 23 | Apple, `NINearbyObject.direction` | https://developer.apple.com/documentation/nearbyinteraction/ninearbyobject/direction-4qh5w | Normalized Cartesian direction vector; `nil` when unavailable | primary | high |
| 24 | Apple, `NIDeviceCapability` | https://developer.apple.com/documentation/nearbyinteraction/nidevicecapability | Runtime capability checks for precise distance, direction, Camera Assistance, etc. | primary | high |
| 25 | Apple, “Initiating and maintaining a session” | https://developer.apple.com/documentation/nearbyinteraction/initiating-and-maintaining-a-session | Best practice: within ~9 m, portrait, back cameras facing, clear line of sight; direction `nil` when out of cone/range | primary | high |
| 26 | Apple, “Discovering peers with Multipeer Connectivity” | https://developer.apple.com/documentation/nearbyinteraction/discovering-peers-with-multipeer-connectivity | App uses separate network to discover peers and exchange discovery tokens | primary | high |
| 27 | Apple, `NINearbyPeerConfiguration.isCameraAssistanceEnabled` | https://developer.apple.com/documentation/nearbyinteraction/ninearbypeerconfiguration/iscameraassistanceenabled | Combines ARKit spatial awareness with UWB for wider conditions and horizontal/vertical angle | primary | high |
| 28 | Apple, `NINearbyPeerConfiguration` | https://developer.apple.com/documentation/nearbyinteraction/ninearbypeerconfiguration | Peer interaction config; can enable Camera Assistance and Extended Distance | primary | high |
| 29 | Apple, `NINearbyObject.distance` | https://developer.apple.com/documentation/nearbyinteraction/ninearbyobject/distance-676dm | Distance in meters; `nil` if not acquired | primary | high |
| 30 | Apple, `NISession.worldTransform(for:)` | https://developer.apple.com/documentation/nearbyinteraction/nisession/worldtransform(for:) | Returns world transform in ARKit coordinate space for a nearby object | primary | high |
| 31 | DeVrio, Mollyn, Harrison, *SmartPoser* (arXiv) | https://arxiv.org/abs/2509.03451 | Nearby Interaction distance updates ~5 Hz in iPhone 13 Pro ↔ Apple Watch setup; study-specific pose error 11.0 cm; UWB correction reduced one body-occlusion case from 34.5 cm to 6.7 cm | primary (academic) | medium |
| 32 | Stute, Kreitschmann, Hollick, *One Billion Apples’ Secret Sauce* (arXiv/ACM MobiCom ’18) | https://arxiv.org/abs/1808.03156 | AWDL accepted sync error 3 ms; channel switch ≥ 8 ms; throughput limited by PHY; concurrent AP on different channel drops aggregate throughput ~13% | primary (academic) | medium |
| 33 | heckj/MPCF-TestBench | https://github.com/heckj/MPCF-TestBench | Third-party tool exists for benchmarking MultipeerConnectivity on Apple platforms | secondary | low |

---

## Sources

1. Apple — MultipeerConnectivity: https://developer.apple.com/documentation/multipeerconnectivity
2. Apple — `MCSession`: https://developer.apple.com/documentation/multipeerconnectivity/mcsession
3. Apple — `MCSessionSendDataMode`: https://developer.apple.com/documentation/multipeerconnectivity/mcsessionsenddatamode
4. Apple — Network framework: https://developer.apple.com/documentation/network
5. Apple — TN3151 Choosing the right networking API: https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api
6. Apple — TN3213 Moving from Multipeer Connectivity to Network framework: https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework
7. Apple — `NWParameters`: https://developer.apple.com/documentation/network/nwparameters
8. Apple — `NWParameters.includePeerToPeer`: https://developer.apple.com/documentation/network/nwparameters/includepeertopeer
9. Apple — `NWEndpoint.service(name:type:domain:interface:)`: https://developer.apple.com/documentation/network/nwendpoint/service(name:type:domain:interface:)
10. Apple — `ARWorldTrackingConfiguration.isCollaborationEnabled`: https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/iscollaborationenabled
11. Apple — `ARWorldTrackingConfiguration`: https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration
12. Apple — `ARSession.update(with:)`: https://developer.apple.com/documentation/arkit/arsession/update(with:)
13. Apple — “Creating a collaborative session”: https://developer.apple.com/documentation/arkit/creating-a-collaborative-session
14. Apple — `ARSession.CollaborationData.priority`: https://developer.apple.com/documentation/arkit/arsession/collaborationdata/priority-swift.property
15. Apple — “Creating a multiuser AR experience”: https://developer.apple.com/documentation/arkit/creating-a-multiuser-ar-experience
16. Apple — `ARWorldMap`: https://developer.apple.com/documentation/arkit/arworldmap
17. Apple — `ARWorldTrackingConfiguration.initialWorldMap`: https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/initialworldmap
18. Apple — `ARParticipantAnchor`: https://developer.apple.com/documentation/arkit/arparticipantanchor
19. Apple — `ARSession.pause()`: https://developer.apple.com/documentation/arkit/arsession/pause()
20. GaoGuohao/SwiftShot (README, third-party mirror of the Apple WWDC18 sample): https://github.com/GaoGuohao/SwiftShot/blob/master/README.md
21. Apple — Nearby Interaction framework overview: https://developer.apple.com/documentation/nearbyinteraction
22. Apple — `NISession`: https://developer.apple.com/documentation/nearbyinteraction/nisession
23. Apple — `NINearbyObject.direction`: https://developer.apple.com/documentation/nearbyinteraction/ninearbyobject/direction-4qh5w
24. Apple — `NIDeviceCapability`: https://developer.apple.com/documentation/nearbyinteraction/nidevicecapability
25. Apple — “Initiating and maintaining a session”: https://developer.apple.com/documentation/nearbyinteraction/initiating-and-maintaining-a-session
26. Apple — “Discovering peers with Multipeer Connectivity”: https://developer.apple.com/documentation/nearbyinteraction/discovering-peers-with-multipeer-connectivity
27. Apple — `NINearbyPeerConfiguration.isCameraAssistanceEnabled`: https://developer.apple.com/documentation/nearbyinteraction/ninearbypeerconfiguration/iscameraassistanceenabled
28. Apple — `NINearbyPeerConfiguration`: https://developer.apple.com/documentation/nearbyinteraction/ninearbypeerconfiguration
29. Apple — `NINearbyObject.distance`: https://developer.apple.com/documentation/nearbyinteraction/ninearbyobject/distance-676dm
30. Apple — `NISession.worldTransform(for:)`: https://developer.apple.com/documentation/nearbyinteraction/nisession/worldtransform(for:)
31. DeVrio, Mollyn & Harrison, *SmartPoser: Arm Pose Estimation with a Smartphone and Smartwatch Using UWB and IMU Data* (ACM UIST ’23 / arXiv): https://arxiv.org/abs/2509.03451
32. Stute, Kreitschmann & Hollick, *One Billion Apples’ Secret Sauce: Recipe for the Apple Wireless Direct Link Ad hoc Protocol* (ACM MobiCom ’18 / arXiv): https://arxiv.org/abs/1808.03156
33. heckj/MPCF-TestBench: https://github.com/heckj/MPCF-TestBench

---

## Coverage status

* Checked directly: Apple primary documentation for `MultipeerConnectivity`, `MCSession`, `MCSessionSendDataMode`, `Network.framework`, `NWParameters`, `NWParameters.includePeerToPeer`, `NWEndpoint.service`, `NWConnection`/`NWBrowser`/`NWListener`, TN3151, TN3213, ARKit collaboration, `ARWorldMap`, multiuser AR, `ARParticipantAnchor`, Nearby Interaction framework, `NISession`, `NINearbyPeerConfiguration`, `NIDeviceCapability`, `NINearbyObject` distance/direction, Camera Assistance, `worldTransform(for:)`, and two academic sources (AWDL paper, SmartPoser).

* Inferred / not directly from Apple: full-mesh directed stream count (`N(N-1)`), the O(N²) application-traffic growth, that outdoor ARKit performance is likely limited by camera tracking rather than the network, and that a host/relay topology adds a forwarding hop. These are noted as inferences.

* Not found / unresolved: no official Apple transport-latency benchmark for `MultipeerConnectivity` or `Network.framework`; no primary Apple page still online for the original SwiftShot sample (the analysis above uses a third-party mirror of its README); no Apple-documented upper participant count for ARKit collaboration beyond “best with up to four.”

* Could not complete: none. The draft is saved to the requested path.
