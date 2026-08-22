# Build log

This is the integration-owned, evidence-based status record. Append observed results; do not paste secrets, signing material, unique device identifiers, or unsanitized logs.

## Current status — 2026-08-22

- **Current gate:** Pipeline bootstrap, before G0 Hardware.
- **Observed working:** Canonical product sources, delivery ownership, CI/deploy workflows, and guarded Outpost operator scripts are present. At 2026-08-22 10:35 PDT, local `pnpm verify` passed (`Repository contract: PASS`; `Workspace verification: PASS`), all CI/Outpost shell scripts passed Bash syntax parsing, both workflow files passed YAML syntax parsing, and `pnpm verify:ios` correctly skipped because the iOS scaffold has not landed. Xcode 26.6 and Devin CLI 3000.5.20 are installed.
- **Physical-device evidence:** None recorded in this repository.
- **Mocked or unproven:** Signed launch on two phones; camera/location permission; per-phone Convex mutation/subscription; spectator subscription; dual mirroring; debug-fire vertical slice.
- **Blockers:** No canonical remote is configured and the stored GitHub CLI login for `Jorybraun` is invalid; Outpost credential rotation/restart is not evidenced; macOS reports zero valid code-signing identities and no two connected phones are evidenced; Convex/demo environment credentials are not evidenced; the automated CI result on the integrated bootstrap commit is not yet evidenced.
- **Next integration step:** Re-authenticate GitHub, publish the bootstrap commit to the canonical repository, obtain a green CI run, then run a read-only Mac Outpost canary against that exact SHA and execute G0.
- **Cut or deferred:** No Phase 0 feature cut. Unity/custom-server/LAN archives, 3+ player targeting, shared AR coordinates, UWB, projectile physics, WebRTC, permanent accounts, and App Store work are reference-only or post-MVP.

## Evidence required to close G0 Hardware

- [ ] Green `main` SHA recorded.
- [ ] Xcode version and build configuration recorded.
- [ ] Signed shell launches on Phone A (model/iOS only; no UDID).
- [ ] Signed shell launches on Phone B (model/iOS only; no UDID).
- [ ] Rear-camera permission passes on both phones.
- [ ] Precise foreground-location permission passes on both phones.
- [ ] Phone A mutation and live subscription pass against the configured Convex deployment.
- [ ] Phone B mutation and live subscription pass against the configured Convex deployment.
- [ ] Spectator shell live subscription passes against the same deployment.
- [ ] One tested mirroring route is recorded for each phone.
- [ ] Sanitized Outpost run link/log and time are recorded.

## Entry template

### YYYY-MM-DD HH:MM TZ — Gate or slice

- **Git SHA / PR:**
- **Owner and write set:**
- **Environment/artifact:**
- **Commands/checks:**
- **Observed on browser/simulator:**
- **Observed on physical devices:**
- **Mocked or unproven:**
- **Result:** PASS / FAIL / BLOCKED
- **Blocker and owner:**
- **Next integration step:**
- **Cut/deferred or risk change:**
