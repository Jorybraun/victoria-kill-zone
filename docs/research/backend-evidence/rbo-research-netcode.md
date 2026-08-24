# Multiplayer Netcode Research for a Co-located AR Phone Game (2–8 players)

**Scope:** survey established, primary-source precedents for lag-compensated hitscan, authoritative projectiles, client-side prediction, snapshot/state sync, authority models, and multiplayer slow-motion / “bullet time.” The goal is an architecture recommendation that works on a local/co-located Wi-Fi LAN today and remains compatible with later remote play over ordinary Internet connections.

---

## Evidence Table

| # | Claim | Source URL | Direct / Inferred |
|---|-------|------------|-------------------|
| 1 | Source engine servers run discrete 15 ms ticks (~66.67 tps); each tick processes user commands, physics, rules, and object-state updates; higher tick rate raises precision at CPU/bandwidth cost. | https://developer.valvesoftware.com/wiki/Source_Multiplayer_Networking | Direct (`/tmp/valve_source_mp.md:99`, `319–322`) |
| 2 | Source sends ~20 snapshots/sec; entity interpolation defaults to 100 ms (`cl_interp 0.1`) so the renderer can interpolate across one lost snapshot; extrapolation is used for up to 0.25 s of packet loss. | https://developer.valvesoftware.com/wiki/Source_Multiplayer_Networking | Direct (`/tmp/valve_source_mp.md:236–250`) |
| 3 | Source view-interpolation delay is `max(cl_interp, cl_interp_ratio / cl_updaterate)`. | https://developer.valvesoftware.com/wiki/Source_Multiplayer_Networking | Direct (`/tmp/valve_source_mp.md:329–335`) |
| 4 | Source is server-authoritative; the server is a dedicated host authoritative over world simulation, game rules, and player input. Listen servers exist but still carry the same interpolation/lag-compensation pipeline. | https://developer.valvesoftware.com/wiki/Source_Multiplayer_Networking | Direct (`/tmp/valve_source_mp.md:81`, `250`, `290–298`) |
| 5 | Source lag compensation estimates command execution time as `Current Server Time − Packet Latency − Client View Interpolation`; the server rewinds *only players* to that time, runs weapon ray casts, then restores current positions. | https://developer.valvesoftware.com/wiki/Latency_Compensating_Methods_in_Client/Server_In-game_Protocol_Design_and_Optimization | Direct (`/tmp/valve_latency.md:228–241`; `/tmp/valve_source_mp.md:280–284`) |
| 6 | Valve explicitly did *not* lag-compensate autonomous projectile objects in Half-Life because a continuously existing projectile raises difficult temporal questions about how far to rewind other players for every simulation step. | https://developer.valvesoftware.com/wiki/Latency_Compensating_Methods_in_Client/Server_In-game_Protocol_Design_and_Optimization | Direct (`/tmp/valve_latency.md:271`) |
| 7 | Lag compensation in Source can make a high-latency player appear to “shoot around a corner”; this is a documented game-design tradeoff. | https://developer.valvesoftware.com/wiki/Latency_Compensating_Methods_in_Client/Server_In-game_Protocol_Design_and_Optimization | Direct (`/tmp/valve_latency.md:247–251`) |
| 8 | Client-side prediction lets the client simulate local movement immediately, but the server remains authoritative and corrects mispredictions; making clients authoritative over their own positions would make cheating trivial. | https://gafferongames.com/post/what_every_programmer_needs_to_know_about_game_networking/ | Direct (`/tmp/gaffer_networking.md:73–101`) |
| 9 | Snapshot interpolation transmits state from the simulation side and reconstructs a visual approximation on the receiving side; it does not run the full simulation on the receiver and uses intentional delay (e.g., 3× packet interval) to absorb jitter and packet loss. | https://gafferongames.com/post/snapshot_interpolation/ | Direct (`/tmp/gaffer_snapshot_converted.md:54–79`, `97`, `121–137`) |
| 10 | Deterministic lockstep is bandwidth-efficient but requires exact determinism and waits for all players; Fiedler recommends it for only ~2–4 players in the referenced physics context. | https://gafferongames.com/post/snapshot_interpolation/ | Direct (`/tmp/gaffer_snapshot_converted.md:58–60`) |
| 11 | State synchronization runs the simulation on both sides and sends both inputs and state; perfect determinism is not required, but it is approximate/lossy, can diverge and “pop,” and requires velocities and quantizing state on both sides to reduce divergence. | https://gafferongames.com/post/state_synchronization/ | Direct (`/tmp/gaffer_state_converted.md:58–66`, `81–85`, `125–127`, `173–181`) |
| 12 | Overwatch is server-authoritative, uses 16 ms command frames, and the client clock is ahead of the server by roughly half RTT plus one buffered command frame. | https://www.youtube.com/watch?v=8QHHVpBiG-I (transcript `/tmp/overwatch_gdc.en-orig.srt:771–791`) | Direct |
| 13 | Overwatch performs backwards reconciliation / rewind for hit registration before applying damage, reverting players and other moving entities (doors, platforms, payloads) to the shooter’s frame of reference. | https://www.youtube.com/watch?v=8QHHVpBiG-I (transcript `/tmp/overwatch_gdc.en-orig.srt:4410–4515`, `5160–5167`) | Direct |
| 14 | Overwatch clamps the rewind window and extrapolates beyond the clamp so victims are not pulled far behind cover; hit impacts are predicted on the client, but health-bar/hit-pip feedback waits for server acknowledgement. | https://www.youtube.com/watch?v=8QHHVpBiG-I (transcript `/tmp/overwatch_gdc.en-orig.srt:4770–4807`, `4815–4827`) | Direct |
| 15 | Overwatch “favors the shooter most of the time unless the victim does something to mitigate the shot” (e.g., Reaper Wraith Form); the shooter’s kill is still rejected if the victim was already invulnerable on the server. | https://www.youtube.com/watch?v=8QHHVpBiG-I (transcript `/tmp/overwatch_gdc.en-orig.srt:5083–5103`) | Direct |
| 16 | Overwatch distinguishes hitscan projectiles, travel-time projectiles with explosions, and continuous beams (e.g., Zarya); projectiles are instigator-tagged and have their own simulation/serialization slice. | https://www.youtube.com/watch?v=8QHHVpBiG-I (transcript `/tmp/overwatch_gdc.en-orig.srt:1960–1975`, `2260–2275`, `5820–5875`, `6330–6410`) | Direct |
| 17 | VALORANT uses a server-authoritative networking model; the server never trusts the client’s view of the world and issues corrections when client and server disagree. | https://technology.riotgames.com/news/peeking-valorants-netcode | Direct (`/tmp/riot_valorant.md:61–63`, `313–314`) |
| 18 | VALORANT runs movement/physics at a fixed 128 Hz timestep on both client and server, independent of render framerate, to minimize simulation divergence. | https://technology.riotgames.com/news/peeking-valorants-netcode | Direct (`/tmp/riot_valorant.md:300–332`) |
| 19 | VALORANT mitigates peeker’s advantage by global server footprint, 128-tick servers, low buffering, client performance, and map/weapon design levers; raw peeker advantage can be ~141 ms at 64 Hz/60 FPS and is reduced to ~71 ms at 144 FPS/128 tick. | https://technology.riotgames.com/news/peeking-valorants-netcode | Direct (`/tmp/riot_valorant.md:103–267`) |
| 20 | VALORANT hit registration rewinds the world to what the shooter was looking at, with limits on how far the server will rewind to prevent high-latency players killing someone a half-second after they reached cover. | https://technology.riotgames.com/news/peeking-valorants-netcode | Direct (`/tmp/riot_valorant.md:321–335`) |
| 21 | GGPO pioneered rollback networking for peer-to-peer games; it speculatively executes local inputs immediately, then resimulates from the point of divergence when late/different remote inputs arrive; it is designed for fully deterministic engines. | https://www.ggpo.net/ | Direct (`/tmp/ggpo.md`) |
| 22 | Local perception filters (LPF) were introduced by Sharkey, Ryan & Roberts (1998) as a method for hiding communication delays by rendering remote entities slightly out-of-date while preserving local-player real-time interaction; Smed et al. (2004) extended LPFs to realize a “bullet time” effect. | https://doi.org/10.1109/VRAIS.1998.658502; https://staff.cs.utu.fi/~jounsmed/papers/NG04_BulletTime-Slides.pdf | The 1998 paper is cited/second-hand in [10]; the Smed slides are Direct (`/tmp/bullettime_slides.txt`) |
| 23 | LPFs work by assigning a “temporal contour” to each entity; active entities (players) are shown in real time, passive/predictable entities (projectiles) can be shown in the past or future, and temporal distortion is localized around the player. | https://staff.cs.utu.fi/~jounsmed/papers/NG04_BulletTime-Slides.pdf | Direct (`/tmp/bullettime_slides.txt`) |
| 24 | Consistency maintenance (CM) techniques in networked games have different user-experience tradeoffs; Savery et al. identify that local avatar, other players, and player variables (health, lives) have the tightest consistency requirements, and that CM can add latency and jarring corrections. | https://research.cs.queensu.ca/home/savery/Publications/group2010-consistencymaintenance.pdf | Direct (`/tmp/savery_consistency.txt`) |
| 25 | SUPERHOT is single-player only and is tagged on Steam as “Singleplayer,” “Bullet Time,” and “Time Manipulation.” | https://store.steampowered.com/app/322500/SUPERHOT/ | Direct (`/tmp/steam_superhot.html` tags) |
| 26 | Max Payne 3 has both “Single-player” and “Multi-player” Steam categories and is tagged “Bullet Time,” but the classic Max Payne bullet-time mechanic is a single-player staple (Max Payne and Max Payne 2 are “Single-player” only); Max Payne 3’s multiplayer implements it as a limited “Burst” ability. | https://store.steampowered.com/app/204100/Max_Payne_3/; https://store.steampowered.com/app/12140/Max_Payne/; https://store.steampowered.com/app/12150/Max_Payne_2_The_Fall_of_Max_Payne/; https://kotaku.com/how-multiplayer-bullet-time-works-in-max-payne-3-5907699 | Direct (Steam tags + Kotaku) |
| 27 | Double Action: Boogaloo is a shipped, free-to-play multiplayer game on Steam with “Multiplayer” and “Bullet Time” tags and a store description that emphasizes diving, flipping, sliding, and action-movie mayhem. | https://store.steampowered.com/app/317360/Double_Action_Boogaloo/ | Direct (`/tmp/steam_da.html` + Steam API) |
| 28 | A dedicated, server-authoritative model is the safest default for anti-cheat, the cleanest path to remote play, and the easiest to scale from a local host; a listen/host-authoritative server can reduce co-located latency but reintroduces the same trust boundary as a client-hosted peer. | https://developer.valvesoftware.com/wiki/Source_Multiplayer_Networking; https://gafferongames.com/post/what_every_programmer_needs_to_know_about_game_networking/ | Inferred from [1] + [3] |
| 29 | Rollback/lockstep networking is a poor default for a full AR simulation because AR tracking, physics, device timing, and floating-point behavior are non-deterministic across heterogeneous mobile devices; deterministic rollback can only be used for a carefully isolated, deterministic mini-simulation. | https://www.ggpo.net/; https://gafferongames.com/post/snapshot_interpolation/; https://gafferongames.com/post/state_synchronization/ | Inferred from [8] + [4] + [5] |
| 30 | For an AR phone game, the recommended default is a single authoritative server (dedicated or a trusted local host), client-side prediction for the local player, snapshot interpolation or state synchronization for remote players/objects, server-side lag-compensated hitscan, and server-authoritative projectiles with client-predicted muzzle/trajectory visuals reconciled by the server. | https://developer.valvesoftware.com/wiki/Source_Multiplayer_Networking; https://developer.valvesoftware.com/wiki/Latency_Compensating_Methods_in_Client/Server_In-game_Protocol_Design_and_Optimization; https://gafferongames.com/post/what_every_programmer_needs_to_know_about_game_networking/; https://gafferongames.com/post/snapshot_interpolation/; https://gafferongames.com/post/state_synchronization/; https://www.youtube.com/watch?v=8QHHVpBiG-I; https://technology.riotgames.com/news/peeking-valorants-netcode; https://www.ggpo.net/; https://doi.org/10.1109/VRAIS.1998.658502; https://staff.cs.utu.fi/~jounsmed/papers/NG04_BulletTime-Slides.pdf; https://research.cs.queensu.ca/home/savery/Publications/group2010-consistencymaintenance.pdf | Inferred synthesis of the above |

---

## Findings

### 1. Server tick and update model

The Source engine is a useful concrete reference for a client/server action game. It simulates the game in discrete **ticks**; the default timestep is 15 ms, giving ~66.67 ticks per second [1]. During each tick the server processes incoming user commands, runs a physics step, checks game rules, and updates object states. After the tick it decides whether any client needs a world update and, if so, takes a **snapshot** [1]. A higher tick rate improves precision but costs CPU and bandwidth; Valve warns that running at 100 ticks produces ~1.5× the CPU load of the 66-tick default and is not recommended for most Source games [1].

Clients and the server exchange small packets at 20–30 Hz [1]. The server does **delta compression**: it normally sends only state changes since the last acknowledged update, falling back to a full snapshot on heavy packet loss or at game start [1].

### 2. Entity interpolation

Because the client receives only ~20 snapshots per second, rendering raw snapshots would be choppy and one dropped packet would cause a glitch. Source solves this by rendering a fixed time in the past. The default interpolation period is **100 ms** (`cl_interp 0.1`) [1, 2]. With two buffered snapshots the renderer can always interpolate, and if one snapshot is lost it can still interpolate between the previous two [1].

The relation between snapshot rate and interpolation delay is:

```
interpolation period = max( cl_interp, cl_interp_ratio / cl_updaterate )
```

[1, 3]. This means the interpolation delay can be reduced by raising `cl_updaterate` (up to the server tick rate) and lowering `cl_interp`, but at the cost of less packet-loss tolerance [1].

### 3. Client-side prediction and authority

The modern FPS technique, described by Glenn Fiedler via John Carmack’s QuakeWorld work, is **client-side prediction**: the client immediately simulates the local player’s movement using the same movement code as the server, then accepts server corrections when the simulations diverge [3]. Carmack described this as “the client guesses at the results of the user’s movement until the authoritative response from the server comes through,” accepting the loss of the elegant “dumb terminal” client [3].

A crucial design rule: the client **must not** be authoritative over its own position. If it were, a cheater could simply teleport or instantly dodge [3]. Fiedler quotes Tim Sweeney’s Unreal networking architecture: “The Server Is The Man” [3].

Source implements the same pattern: `cl_predict 1` lets the client run the same movement code the server will run and show the result immediately; when the server snapshot arrives the client compares and, if different, smoothly corrects the error [1].

Valve’s Yahn Bernier paper adds the implementation detail that the client keeps a circular buffer of past state and input so that, when a server correction arrives, it can discard state older than the correction and replay the intervening inputs to re-derive the present predicted state [2, 8].

### 4. Snapshot interpolation vs. state synchronization

Glenn Fiedler’s survey gives three major strategies:

- **Deterministic lockstep** runs identical simulations on all peers and waits for every player’s input before advancing the frame. It is bandwidth-efficient, but requires exact determinism (floating-point determinism across platforms is hard) and causes everyone to wait for the most lagged player; Fiedler recommends it for **2–4 players at most** [4, 10].
- **Snapshot interpolation** does not run the simulation on the receiver. The sender captures the whole visual state of the world, sends it over UDP, and the receiver buffers snapshots in an interpolation delay (e.g., ~3× the packet interval) to absorb jitter and packet loss [4, 9]. Bandwidth is high, but it scales to larger player counts and tolerates non-determinism.
- **State synchronization** runs the simulation on both sides and sends both inputs and periodic state updates. Because state is sent, perfect determinism is not required, but the synchronization is approximate and lossy, can diverge and “pop,” and requires sending velocities as well as positions [5, 11]. Quantizing state identically on both sides reduces divergence, and visual smoothing is applied as error offsets rather than at the simulation level [5, 11].

For a fast action game on mobile phones, pure lockstep is not attractive. Snapshot interpolation is a proven path for FPS-style state (Overwatch and Source both interpolate remote players from server snapshots). State synchronization is viable for physics-heavy scenes with many objects, but requires more engineering to avoid pops.

### 5. Lag compensation for hitscan

Valve’s lag-compensation system is the canonical example of “rewind to the shooter’s view.” The algorithm is:

1. The server estimates the player’s latency.
2. It searches the server-side history for the world update the player received just before issuing the command.
3. It moves other players backward in time to where they were when the command was created, accounting for **both connection latency and the client’s interpolation amount**.
4. It runs weapon ray casts against those old positions.
5. It restores the moved players to their current positions [2, 5].

Source’s formula for the command execution time is:

```
Command Execution Time = Current Server Time − Packet Latency − Client View Interpolation
```

[1, 5].

This means the server effectively rewinds the world to the shooter’s perceived “now.” It deliberately applies only to **players** (and player-derived hitboxes) and not to autonomous projectiles [2, 6]. Valve explicitly notes that a projectile that lives on after the firing command raises hard temporal questions (which time should the projectile live in? how far back should other players be moved on every step?), so Half-Life simply did not lag-compensate projectiles [2, 6].

The tradeoff is that a highly lagged player can appear to “shoot around a corner” from the victim’s point of view; from the shooter’s point of view, the shot was legitimate. Valve considered this an acceptable design tradeoff for Half-Life, Counter-Strike, and Team Fortress [2, 7].

### 6. Overwatch 2017 GDC: ECS, command frames, and favor-the-shooter

The 2017 GDC talk *Overwatch Gameplay Architecture and Netcode* (Tim Ford) is the best primary source for how a modern shooter layers netcode over an entity-component system [6]. Key points from the transcript:

- The simulation runs on 16 ms **command frames** and the client clock is ahead of the server by roughly **half RTT plus one buffered command frame** (e.g., ~80 ms + 16 ms for 160 ms RTT) [6].
- Overwatch is server-authoritative. Mispredictions are accepted as a side effect of server authority and lag; when the client and server disagree, the client is corrected [6].
- For hit registration, the server **rewinds** the shooter’s targets (and potentially other moving entities such as doors, platforms, and the payload) back to the shooter’s frame of reference before applying damage, then rolls the state forward [6].
- The rewind is bounded: “we put clamps on it… after that, we start to extrapolate.” Overwatch does not want to drag a victim far behind cover just because a high-latency shooter fired late [6].
- Hit impacts (blood) are predicted on the client, but the hit pip and health bar are not predicted; they wait for server acknowledgement [6].
- The game “favors the shooter most of the time unless the victim does something to mitigate the shot,” e.g., using an invulnerability ability such as Reaper’s Wraith Form [6].
- The ECS architecture made rewind easy to express: only entities with the right component set are moved backward, and damage is applied in a separate slice from the rewind itself [6].
- Overwatch handles **hitscan projectiles, travel-time projectiles with explosions, and continuous beams** (e.g., Zarya). Projectiles are instigator-tagged, and their simulation is isolated so that effects can be deferred to the right frame [6].

The GDC Vault recording is the primary publication; a YouTube mirror with the English auto-subtitles used here is also available [6].

### 7. Riot VALORANT: 128-tick, peeker’s advantage, and server-side hit validation

Riot’s engineering article *Peeking into VALORANT’s Netcode* confirms a very similar architecture and adds the 128-tick framing [7].

- VALORANT uses a **server-authoritative** networking model and explicitly states that “a server must never trust a client’s view of the world” [7, 17].
- Movement, physics, and related systems are decoupled from render framerate and run at a fixed **128 Hz** timestep on both client and server, so the two sides can compare simulation results on an apples-to-apples basis [7, 18].
- Peeker’s advantage comes from the time it takes for the peeker’s movement input to reach the server, be processed, and be sent to the holder. Riot quantified it as roughly **141 ms** in a 64-tick/60-FPS baseline, and showed that 128-tick servers, low buffering, higher client framerates, and Riot Direct latency reduction can cut that advantage (e.g., to ~71 ms at 144 FPS with good ping) [7, 19].
- For hit registration, the server rewinds the world to the state the shooter was seeing and traces the shot, but imposes limits so a player with 500 ms latency cannot kill someone who already reached cover [7, 20].
- When the client and server diverge, the server commits its prediction as truth and the client adjusts; the correction is kept small and visible only to the player with the network problem [7, 17].

### 8. Multiplayer “bullet time” and time manipulation

The request asked for both academic precedents and explicit evidence that famous bullet-time games are single-player.

- **SUPERHOT** is single-player only; its Steam tags are “Singleplayer,” “Bullet Time,” and “Time Manipulation” [12, 25].
- The **Max Payne** series originated bullet time as a single-player mechanic. **Max Payne 3** shipped a full competitive online multiplayer mode (XP, loadouts, Burst perks), and bullet time exists in it as a limited **“Burst”** ability fueled by an adrenaline meter [13, 15]. **Correction (2026-08-24, verified against the primary Kotaku companion article):** the mechanic is a *line-of-sight propagated time bubble*, not a target-only slowdown — “Bullet time in multiplayer slows you down, slows down anyone you can see, anyone who can see you, and anyone who those affected people can see or be seen by… You’re only unaffected if you’re out of sight.” The advantage is asymmetric: enemies caught in it get a red haze and slowed reload/rate-of-fire; the activator’s side gets a white haze and “the world slows down for you, but your guns are still fast” [15b]. The original Max Payne and Max Payne 2 are single-player [17, 18].
- **Double Action: Boogaloo** is a shipped free-to-play multiplayer game whose store description is “a free stylish multiplayer game about diving, flipping, and sliding your way into action movie mayhem,” and it is tagged both “Multiplayer” and “Bullet Time” [14, 27].

Academic precedents:

- **Local perception filters** were introduced by **Sharkey, Ryan & Roberts** in 1998 as a way to hide communication delays by rendering remote entities at slightly out-of-date locations based on network delay, preserving local real-time interaction [9, 22].
- Smed, Niinisalo, and Hakonen applied LPFs to a **multiplayer bullet time** effect. Their conference slides explain that LPFs assign a “temporal contour” to each entity: active (player) entities are rendered in real time, passive/predictable entities (projectiles) can be rendered in the past or future, and the distortion is localized around the player [10, 23]. A player using bullet time can be given an increased artificial delay relative to nearby passive entities, giving the bullet-timed player more time to react without globally freezing the world [10, 23].
- Savery, Graham, and Gutwin’s human-factors framework for consistency maintenance in networked games notes that different entities have different consistency requirements: the local avatar and player variables (health, lives) are the most sensitive, while remote players and world objects can tolerate more latency or correction [11, 24]. This is relevant to any bullet-time implementation because slowing one player’s view while keeping others’ views consistent creates exactly these kinds of consistency conflicts.

### 9. Authority models compared

For a small AR phone game, four authority models are relevant:

1. **Dedicated server-authoritative.** One trusted machine simulates the whole world and everyone else is a client. Trust model is clean: the server validates all inputs and hit detection. Latency is whatever the network is. This is the model Source, Overwatch, and VALORANT use [1, 6, 7]. Bandwidth and CPU cost grow with the number of clients and the physics complexity, but for 2–8 players on a modern phone or a tiny cloud host it is very feasible. Failure mode: server crash ends the match; server is a single target for cheating if compromised.

2. **Host / listen server (one player is the server).** One client also runs the server simulation. For a co-located LAN this is effectively a zero-hop server and can have very low latency, but the hosting player has the same trust advantage as any server operator and the same anti-cheat burden. Source notes that even on a listen server the default 100 ms view interpolation still applies because the same client/server pipeline is used [1, 4]. Failure mode: if the host quits, the match must migrate or end; the host can more easily cheat or manipulate state.

3. **Rollback / GGPO-style peer-to-peer.** The GGPO SDK runs a fully deterministic simulation on all peers, predicts remote inputs, and resimulates from divergence points [8, 21]. It is excellent for 2-player fighting games where inputs are discrete and simulation is fully deterministic. For an AR game it is a poor default because:
   - AR tracking (ARKit, ARCore, device IMU, camera pose) is **not bit-exact or deterministic** across devices.
   - Mobile GPUs, floating-point differences, and device timing make full determinism hard to guarantee [5, 10, 11].
   - Rollback has to resimulate many frames; on a phone CPU this is expensive for a full 3D AR physics scene.
   The safer use of rollback is to confine it to a small, deterministic sub-system (e.g., a 2D prediction minigame) rather than the whole AR world [21, 29].

4. **State-synchronization / distributed simulation.** Each device runs a copy of the simulation and sends inputs plus state. This avoids waiting for all players but accepts approximate, lossy sync and possible pops [5, 11]. It can be attractive for AR because each phone already has local world tracking, but reconciling device pose drift and inconsistent local AR maps across devices is a hard consistency problem that goes beyond the scope of the surveyed game-networking literature.

### 10. Projectile handling

Sources agree that **autonomous projectiles are harder than hitscan**:

- Valve explicitly avoided lag-compensating projectiles in Half-Life because the projectile exists over many frames and continuously moving other players backward is conceptually awkward and expensive [2, 6].
- Overwatch does have travel-time projectiles and beams, but handles them with instigator tagging, separate simulation slices, and deferred effect spawning so the server can resolve ownership and collisions cleanly [6].
- Gaffer’s state-synchronization article shows that synchronizing velocities is essential for extrapolating objects between state updates, which is directly applicable to projectiles [5, 11].

The recommended pattern for projectiles in an AR shooter is:

- The **server is the only authority** over whether a projectile hit and what damage it did.
- The client can predict the **visual muzzle flash, sound, and initial trajectory**.
- The client can show a **predicted local copy** of the projectile while waiting for the server, but must reconcile when the server’s authoritative result arrives (e.g., remove a client projectile that the server says missed, or spawn the explosion at the server-approved impact point).
- For grenades/rockets with travel time, the server simulates the projectile at a fixed timestep and sends snapshots/state updates to clients; clients interpolate/extrapolate between them.

This is an **inferred pattern** synthesized from [2, 5, 6, 11, 16].

### 11. Recommended architecture for the AR game

The following is an **inferred architecture recommendation** based on the sources above [28, 30].

**For co-located play today:**

- Use a single authoritative server. In the simplest deployment, one phone acts as the **host/listen server** while also rendering the local view. To reduce cheat risk and simplify later migration, design the server as a separate module from the client so it can later run on a cloud host or a spare device.
- Run the server at a fixed tick rate (e.g., 60 or 128 Hz). Use the same fixed timestep on clients for prediction [7, 18].
- Use **client-side prediction** for the local player’s movement and aiming.
- Use **snapshot interpolation** for remote players and AR objects when possible; if the scene is physics-heavy with many objects, use **state synchronization** with velocity, quantize state on both sides, and apply visual smoothing [4, 5, 9, 11].
- For **hitscan weapons**, implement server-side lag compensation with a bounded rewind window and account for client interpolation [1, 2, 5, 6, 7, 20].
- For **projectiles**, simulate them on the server; the client predicts visual effects and reconciles against server state [2, 6, 16].
- Do **not** use rollback for the whole AR simulation; only consider it for isolated, deterministic mini-games [8, 10, 21, 29].

**For later remote play:**

- The same architecture scales cleanly: move the server module onto a dedicated cloud host with a global footprint (like Riot Direct or Steam Datagram Relay) [1, 7].
- Keep 60–128 ticks; 128 ticks are VALORANT’s standard and measurably reduce peeker’s advantage [7, 19].
- Keep interpolation delay short but not zero, to balance latency and packet-loss tolerance [1, 4, 9].

**For multiplayer “bullet time” (if the design calls for it):**

- Avoid a global slow-down across all players because that multiplies latency and ruins responsiveness for non-bullet-timed players.
- Consider **local perception filters**: the bullet-timed player’s *local view* renders nearby passive entities (projectiles, physics objects) with extra delay, giving the player more reaction time, while other players’ views are not globally slowed [10, 23].
- Use the consistency-maintenance lens from Savery et al. to decide which entities need tight consistency (player avatars, health) and which can tolerate temporal distortion (projectiles, world debris) [11, 24].

---

## Sources

1. Valve Developer Community, *Source Multiplayer Networking*, https://developer.valvesoftware.com/wiki/Source_Multiplayer_Networking (read directly from `/tmp/valve_source_mp.md`).
2. Yahn Bernier / Valve, *Latency Compensating Methods in Client/Server In-game Protocol Design and Optimization*, https://developer.valvesoftware.com/wiki/Latency_Compensating_Methods_in_Client/Server_In-game_Protocol_Design_and_Optimization (read directly from `/tmp/valve_latency.md`).
3. Glenn Fiedler, *What every programmer needs to know about game networking*, https://gafferongames.com/post/what_every_programmer_needs_to_know_about_game_networking/ (read directly from `/tmp/gaffer_networking.md`).
4. Glenn Fiedler, *Snapshot Interpolation*, https://gafferongames.com/post/snapshot_interpolation/ (read directly from `/tmp/gaffer_snapshot_converted.md`).
5. Glenn Fiedler, *State Synchronization*, https://gafferongames.com/post/state_synchronization/ (read directly from `/tmp/gaffer_state_converted.md`).
6. Blizzard / Tim Ford, *Overwatch Gameplay Architecture and Netcode*, GDC 2017. Primary publication: https://gdcvault.com/play/1024000/Overwatch-Gameplay-Architecture-and-Netcode; mirror and transcript used: https://www.youtube.com/watch?v=8QHHVpBiG-I (English auto-subtitles read from `/tmp/overwatch_gdc.en-orig.srt`).
7. Matt deWet & David Straily / Riot Games, *Peeking into VALORANT’s Netcode*, https://technology.riotgames.com/news/peeking-valorants-netcode (read directly from `/tmp/riot_valorant.md`).
8. GGPO, *GGPO Rollback Networking SDK*, https://www.ggpo.net/ (read directly from `/tmp/ggpo.md`).
9. P. M. Sharkey, M. D. Ryan, and D. J. Roberts, *A local perception filter for distributed virtual environments*, IEEE VRAIS 1998. DOI: https://doi.org/10.1109/VRAIS.1998.658502 (cited/introduced through [10]; full paper not directly read).
10. Jouni Smed, Henrik Niinisalo, and Harri Hakonen, *Realizing Bullet Time in Multiplayer Games with Local Perception Filters* (conference slides), https://staff.cs.utu.fi/~jounsmed/papers/NG04_BulletTime-Slides.pdf (read directly from `/tmp/bullettime_slides.txt`); associated paper DOI: https://doi.org/10.1145/1016540.1016551.
11. Cheryl Savery, T. C. Nicholas Graham, and Carl Gutwin, *The Human Factors of Consistency Maintenance in Multiplayer Computer Games*, GROUP 2010. Direct PDF: https://research.cs.queensu.ca/home/savery/Publications/group2010-consistencymaintenance.pdf (read directly from `/tmp/savery_consistency.txt`); DOI: https://doi.org/10.1145/1880071.1880103.
12. Steam, *SUPERHOT* store page, https://store.steampowered.com/app/322500/SUPERHOT/ (read directly from `/tmp/steam_superhot.html` Steam tags).
13. Steam, *Max Payne 3* store page, https://store.steampowered.com/app/204100/Max_Payne_3/ (read directly from `/tmp/steam_mp3_2.html` and Steam API `/tmp/steam_api_mp3.json`).
14. Steam, *Double Action: Boogaloo* store page, https://store.steampowered.com/app/317360/Double_Action_Boogaloo/ (read directly from `/tmp/steam_da.html` and Steam API `/tmp/steam_api_da2.json`).
15. Kotaku, *How Multiplayer Bullet Time Works in Max Payne 3*, https://kotaku.com/how-multiplayer-bullet-time-works-in-max-payne-3-5907699 (read directly from `/tmp/kotaku_mp3.md`).
15b. Stephen Totilo (Kotaku), *Max Payne 3 Multiplayer Is Good, Essential and Rockstar’s Boldest Move In Years* (April 2012; the companion article with the full mechanic description), https://kotaku.com/max-payne-3-multiplayer-is-good-essential-and-rockstar-5904303 (read directly 2026-08-24).
16. Mikola Lysenko, *Local Perception Filter Demo*, http://mikolalysenko.github.io/local-perception-filter-demo/; source https://github.com/mikolalysenko/local-perception-filter.
17. Steam, *Max Payne* store page, https://store.steampowered.com/app/12140/Max_Payne/ (read directly from `/tmp/steam_mp1.html` Steam tags; Single-player only).
18. Steam, *Max Payne 2: The Fall of Max Payne* store page, https://store.steampowered.com/app/12150/Max_Payne_2_The_Fall_of_Max_Payne/ (read directly from `/tmp/steam_mp2.html` Steam tags; Single-player only).

---

## Coverage Status

### Directly verified / read

- Source engine tick, snapshot, interpolation, and lag-compensation pages (Valve) [1, 2].
- Glenn Fiedler’s networking, snapshot interpolation, and state synchronization articles [3, 4, 5].
- Overwatch 2017 GDC auto-transcript (favor-the-shooter, command frames, rewind, projectiles, ECS netcode) [6].
- Riot’s “Peeking into VALORANT’s Netcode” (128-tick, peeker’s advantage, server authority, hit-registration rewind limits) [7].
- GGPO SDK overview (rollback determinism requirements) [8].
- Smed et al. LPF/bullet-time slides (local perception filters and temporal contours) [10].
- Savery et al. consistency-maintenance PDF (human-factors framework) [11].
- Steam store/API evidence for SUPERHOT, Max Payne / Max Payne 2 / Max Payne 3, and Double Action: Boogaloo [12, 17, 18, 13, 14].

### Not directly read (paywalled/blocked)

- Sharkey/Ryan/Roberts 1998 IEEE paper [9]: metadata and DOI confirmed; the full text was not fetched. Its content is summarized through the directly read Smed slides [10].
- The original GDC Vault recording for Overwatch [6] was behind Cloudflare; the YouTube mirror with English auto-subtitles was used as a direct fallback.

### Remaining uncertainty

- No directly read source gives a complete, step-by-step recipe for server-authoritative **projectiles** in an AR context. The findings in §10 and the architecture in §11 are inferred from the combination of Valve’s explicit avoidance of projectile lag-compensation [2, 6], Overwatch’s projectile-instigator and simulation-slice notes [6], and Fiedler’s state-sync guidance [5, 11].
- The AR-specific concerns (camera pose drift, ARKit/ARCore non-determinism, heterogeneous mobile timing) are inferred from the general determinism requirements in [4, 5, 8] rather than from AR-specific netcode literature; no AR netcode primary source was found.
