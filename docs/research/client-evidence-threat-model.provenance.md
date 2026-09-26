# Provenance: Threat model for client-generated spatial evidence in zero-step AR combat (BIO-36)

- **Date:** 2026-09-26 (all URLs accessed this date; all repository paths read from the working tree at this date on the `main` checkout, no local modifications to source).
- **Tracking:** https://linear.app/biossphere/issue/BIO-36/spike-engineer-zero-step-ar-room-understanding-and-authoritative
- **Rounds:**
  1. Repository audit — read `AGENTS.md`, the existing research brief and provenance style (`docs/research/shared-arena-frame-options*.md`), ADRs 0010/0011/0013, `docs/interface-contracts.md`, the shared-spatial-hit-registration requirements, and every file listed under [R1]–[R15] in the brief. Grepped the whole tree for `sceneDepth`, `sceneReconstruction`, `frameSemantics`, `ARMeshAnchor`, `smoothedSceneDepth`, `AppAttest`, `DCAppAttestService`, `DeviceCheck`, `PhonePoseSample`, `ALLOWED_SIGN_IN` to establish absences.
  2. Verification of the five "facts to verify" in the assignment (ARKit/Vision + local plane detection; sighting fire = body evidence only; Convex prepares/projects; DO simulates; Deploy workflow excludes worker, operator script deploys it). All five confirmed from source.
  3. Primary-source pass — Apple developer documentation for App Attest (integrity, server validation, assertion counter rule), DeviceCheck, `ARFrame.sceneDepth`, `supportsSceneReconstruction`, `ARMeshAnchor`, `ARPlaneAnchor.Classification`, Vision point confidence, `ARWorldMap`, `ARSession.CollaborationData`, `ARCamera.TrackingState`, `ARBodyAnchor`, App Privacy Details; Cloudflare documentation for Durable Objects (overview, limits, storage API) and the Workers Rate Limiting binding.
  4. Academic/practitioner pass — USENIX Security 2024 Slocum et al. on shared-state AR attacks; Gambetta lag-compensation series; footspeed figure for the plausibility bound sanity check.
  5. Synthesis — threat matrix per evidence class, corroboration model, attestation placement, trust tiers, explicit trust boundaries, experiment protocol.
- **Sources consulted:** [R1]–[R15], [E1]–[E17], [E19]–[E21] as listed in the brief; additionally Valve Developer Community *Source Multiplayer Networking*; Niantic Gameplay Fairness Policy (search-result snippet only).
- **Sources accepted:** all [R*] (read directly from source); all Apple and Cloudflare [E*] pages (HTTP 200 verified; the App Attest assertion-counter rule was confirmed from Apple's page data after the rendered page truncated); [E17] (peer-reviewed, USENIX); [E19] marked practitioner; [E20] marked tertiary and used only as a sanity anchor for the existing 15 m/s constant.
- **Sources rejected / caveats:**
  - Valve *Source Multiplayer Networking* — fetch returned an anti-bot interstitial; not used. Gambetta [E19] substituted for the lag-compensation point.
  - Niantic Gameplay Fairness Policy — appeared in search results but no canonical URL resolved at verification time (404 on the candidate URLs tried); not cited.
  - `developer.apple.com/documentation/vision/vnrecognizedpoint/confidence` returned 404; replaced by `vndetectedpoint/confidence` (200), which is the documented inherited property.
  - Apple *App Store Review Guidelines* page fetched but truncated before the privacy section; *App privacy details* [E21] used instead for the disclosure requirement.
  - Several Apple pages render primarily via JavaScript; content was taken from the text that did render or from the page's JSON data, and only statements visible there are quoted.
- **Speculation explicitly marked in the brief:** the sighting-derived alignment estimator and its convergence (§5); anthropometric collider bands and jerk/gravity-consistency bounds (§4.2, §4.1); patch cadence and per-match byte budgets (§7); App Attest device/region availability and simulator behaviour (§6); all numeric success criteria in §11. None has device evidence.
- **Verification:**
  - Repository facts were read from source files, not from docs alone; line-level constants quoted (`MAX_SPEED = 15`, `POSITION_SLACK = 0.1`, `COVER_OBSERVATION_MS = 1_000`, `BODY_ANCHOR_METERS = 2`, `IDLE_RETENTION_MS = 24 h`, `MAX_UNCONFIRMED_COLLAB_BYTES = 1 MiB`, ticket 120 s, mint 1/s/player, 8 MiB map cap).
  - The distinction "shared-frame mode anchors body colliders to the victim's phone; sighting mode does not" was verified in `packages/combat-simulation/src/index.ts` (pose observations set to `[]` when `rules.geometry === "sighting"`, `anchoredToPhone` only reached on the non-sighting path).
  - Absences (no depth/mesh/LiDAR consumption; no attestation code; no wall/surface evidence on the fire message) were established by repository-wide search, not by reading a subset.
  - No code, build, test, or device run was performed; `pnpm verify` was not run because nothing under verification changed.
- **Known limits:**
  - This is read-only research: no implementation, branch, PR, commit, or deployment. The two markdown files were written to the working tree but not committed.
  - No physical-device evidence exists for any ARKit behaviour asserted here beyond what Apple documents; alignment accuracy, LiDAR/non-LiDAR mixing, and Vision confidence behaviour under adversarial input are untested.
  - The academic source [E17] studies web/HoloLens-style shared-state AR platforms, not ARKit collaborative sessions; its attack taxonomy transfers, its measurements do not.
  - Attestation guidance is limited to Apple's published server-validation procedure; no App Attest availability matrix by device or region was verified.
  - Privacy analysis is limited to Apple's App Store disclosure requirements; no jurisdiction-specific legal analysis was performed.
  - Collusion between two attested, honest-looking phones defeats every cross-phone check described; the brief states this as an inherent limit rather than proposing a remedy.
