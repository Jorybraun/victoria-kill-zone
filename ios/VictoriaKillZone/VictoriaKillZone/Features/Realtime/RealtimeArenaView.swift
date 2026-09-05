import SwiftUI

#if os(iOS)
import UIKit
#endif

/// Camera-first match surface. The controller owns rules/networking; rendering
/// receives accepted world state and never decides health or target identity.
struct RealtimeArenaView: View {
  @ObservedObject var controller: RealtimeArenaController
  let onLeave: () -> Void
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.openURL) private var openURL
  @StateObject private var fx = LaserFXEngine()
  @State private var hitUntil = Date.distantPast
  @State private var damageUntil = Date.distantPast
  @State private var confirmedTargetID: String?
  @State private var confirmedZone: TargetingHitZone?

  var body: some View {
    ZStack {
      camera.ignoresSafeArea()
      LinearGradient(colors: [.black.opacity(0.75), .clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea().allowsHitTesting(false)
      targetCue
      if controller.now < damageUntil {
        RoundedRectangle(cornerRadius: 30).stroke(VKZPalette.danger.opacity(0.85), lineWidth: reduceMotion ? 8 : 15)
          .ignoresSafeArea().allowsHitTesting(false)
      }
      reticle.allowsHitTesting(false)
      if dynamicTypeSize.isAccessibilitySize {ScrollView {hud}}
      else {hud}
    }
    .foregroundStyle(VKZPalette.text)
    .background(VKZPalette.background)
    .task {controller.setSceneActive(scenePhase == .active); await controller.start()}
    .onChange(of: scenePhase) {_, phase in
      controller.setSceneActive(phase == .active)
      if phase != .active {clearPresentation()}
    }
    .onDisappear {
      controller.setSceneActive(false); clearPresentation()
      Task {await controller.stop()}
    }
    .onReceive(controller.$now) {_ in
      guard controller.worldReady, controller.snapshot?.phase == .running,
        let snapshot = controller.snapshot, let time = controller.matchTimeMs else {fx.clearRealtime(); return}
      fx.updateRealtime(snapshot: snapshot, matchTimeMs: time)
      updateConfirmedSkeleton()
    }
    .onReceive(controller.$associatedBody) {body in
      guard let target = confirmedTargetID, body?.association.playerID == target else {
        fx.updateSkeleton(nil, zone: nil); return
      }
      fx.updateSkeleton(body?.skeleton, zone: confirmedZone)
    }
    .onChange(of: controller.localShotSequence) {_, _ in
      guard scenePhase == .active else {return}; fx.predictMuzzle()
    }
    .onReceive(controller.$confirmedHits) {hits in
      guard scenePhase == .active else {return}
      for hit in hits {
        if hit.incoming {
          damageUntil = Date().addingTimeInterval(0.25)
          fx.renderIncomingLaser(from: nil, hit: true)
        } else {
          hitUntil = Date().addingTimeInterval(0.28)
          confirmedTargetID = hit.targetPlayerID; confirmedZone = hit.zone
          // A generic confirmation is still shown when the original target is
          // no longer the currently observed and confidently identified person.
          let skeleton = RealtimeAssociationPolicy.hitSkeleton(targetPlayerID: hit.targetPlayerID,
            association: controller.associatedBody?.association, skeleton: hit.skeleton, now: Date())
          fx.confirmHit(skeleton: skeleton, zone: hit.zone)
        }
      }
    }
  }

  private var hud: some View {
    VStack(spacing: 10) {
      telemetry
      RealtimeRosterStrip(players: controller.snapshot?.players ?? [], localPlayerID: controller.session.playerId)
      if !dynamicTypeSize.isAccessibilitySize {Spacer(minLength: 12)}
      if controller.stage == .running {combatControls}
      else if controller.stage == .finished {finishedPanel}
      else {preparationPanel}
    }
    .padding(.horizontal, 16).padding(.vertical, 12)
  }

  @ViewBuilder private var camera: some View {
    #if os(iOS) && canImport(ARKit) && canImport(AVFoundation) && canImport(Vision)
    if let live = controller.targeting as? ARVisionTargetingSession {ARCameraPreview(targeting: live, fxEngine: fx)}
    else {VKZPalette.background}
    #else
    VKZPalette.background
    #endif
  }

  private var telemetry: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Label("HEALTH", systemImage: "heart.fill").font(.caption2.bold().monospaced())
        Text("\(controller.localPlayer?.health ?? 100)").font(.system(.title, design: .rounded, weight: .black).monospacedDigit())
          .foregroundStyle((controller.localPlayer?.health ?? 100) <= 34 ? VKZPalette.danger : VKZPalette.ready)
      }
      Spacer(minLength: 4)
      VStack(spacing: 3) {
        Text(controller.stage.title.uppercased()).font(.caption2.bold().monospaced()).lineLimit(2).multilineTextAlignment(.center)
        Text(roundTime).font(.system(.title2, design: .monospaced, weight: .bold).monospacedDigit())
      }
      Spacer(minLength: 4)
      Button(action: leave) {Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44).background(.white.opacity(0.08), in: Circle())}
        .buttonStyle(.plain).accessibilityLabel("Leave match")
    }
    .padding(14).background(.black.opacity(0.64), in: RoundedRectangle(cornerRadius: 18))
  }

  @ViewBuilder private var targetCue: some View {
    if controller.worldReady, let body = controller.associatedBody, let bounds = controller.targetingSnapshot.bodyBounds {
      GeometryReader {geometry in
        RoundedRectangle(cornerRadius: 12)
          .stroke(VKZPalette.ready.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [12, 18]))
          .overlay(alignment: .top) {
            Text(controller.snapshot?.players.first {$0.playerId == body.association.playerID}?.displayName ?? "Target")
              .font(.caption2.bold()).padding(.horizontal, 8).padding(.vertical, 4)
              .background(.black.opacity(0.7), in: Capsule()).offset(y: -24)
          }
          .frame(width: max(44, geometry.size.width * min(1, max(0, bounds.width))), height: max(44, geometry.size.height * min(1, max(0, bounds.height))))
          .position(x: geometry.size.width * bounds.centerX, y: geometry.size.height * (1 - bounds.centerY))
      }
      .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
  }

  private var reticle: some View {
    VStack(spacing: 10) {
      ZStack {
        Circle().stroke(.white.opacity(0.85), lineWidth: 1).frame(width: 28, height: 28)
        Circle().fill(.white).frame(width: 3, height: 3)
        if controller.now < hitUntil {Image(systemName: "xmark").font(.system(size: 40, weight: .bold)).foregroundStyle(VKZPalette.pending)}
      }
      if controller.now < hitUntil {
        Text("HIT CONFIRMED").font(.caption2.bold().monospaced()).foregroundStyle(VKZPalette.pending)
          .padding(5).background(.black.opacity(0.65), in: Capsule())
      }
    }
    .accessibilityHidden(true)
  }

  private var combatControls: some View {
    let eligibility = controller.eligibility
    let player = controller.localPlayer
    let time = controller.matchTimeMs ?? controller.snapshot?.matchTimeMs ?? 0
    return VStack(spacing: 12) {
      HStack(alignment: .lastTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text(controller.snapshot?.rules.weapon.id.uppercased() ?? "WEAPON").font(.caption2.bold().monospaced()).foregroundStyle(VKZPalette.textMuted)
          Text("\(player?.ammo ?? 0) / \(controller.snapshot?.rules.weapon.magazine ?? 0)")
            .font(.system(.title, design: .monospaced, weight: .black).monospacedDigit())
        }
        Spacer()
        Text(eligibility.reason).font(.caption.bold()).foregroundStyle(VKZPalette.pending).multilineTextAlignment(.trailing)
      }
      HStack(spacing: 10) {
        abilityButton(title: (player?.shield.activeUntilMs ?? 0) > time ? "Lower shield" : "Shield", icon: "shield.lefthalf.filled",
          detail: shieldDetail(at: time), enabled: eligibility.shield, action: controller.toggleShield)
        abilityButton(title: "Slow field", icon: "clock.arrow.2.circlepath", detail: cooldownText(until: player?.slowFieldReadyAtMs ?? 0, at: time),
          enabled: eligibility.slowField, action: controller.activateSlowField)
      }
      HStack(spacing: 12) {
        Button(action: controller.reload) {
          VStack(spacing: 5) {Image(systemName: "arrow.clockwise").font(.title3); Text("Reload").font(.caption.bold())}
            .frame(minWidth: 64, minHeight: 72)
        }
        .buttonStyle(.plain).foregroundStyle(eligibility.reload ? .white : VKZPalette.textMuted)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16)).disabled(!eligibility.reload)
        .accessibilityLabel("Reload weapon")
        Button {} label: {
          VStack(spacing: 5) {Image(systemName: "scope").font(.title2); Text(controller.triggerHeld ? "Firing" : "Hold to fire").font(.headline)}
            .frame(maxWidth: .infinity, minHeight: 78)
        }
        .buttonStyle(RealtimeHoldFireStyle(enabled: eligibility.fire || controller.triggerHeld, onPressChanged: controller.setTriggerHeld))
        .disabled(!eligibility.fire && !controller.triggerHeld)
        .accessibilityLabel("Fire weapon").accessibilityHint("Double tap to fire once. Hold with direct touch for rapid fire.")
        .accessibilityAction {controller.fireOnce()}
      }
      if let reloadEnd = player?.reloadEndsAtMs, reloadEnd > time {
        ProgressView(value: max(0, 1 - (reloadEnd - time) / (controller.snapshot?.rules.weapon.reloadMs ?? 1)))
          .tint(VKZPalette.pending).accessibilityLabel("Reload progress")
      }
    }
    .padding(16).background(.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 24))
  }

  private func abilityButton(title: String, icon: String, detail: String, enabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: icon).font(.title3)
        VStack(alignment: .leading, spacing: 2) {Text(title).font(.subheadline.bold()); Text(detail).font(.caption2.monospacedDigit())}
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, minHeight: 44).padding(.horizontal, 12).padding(.vertical, 6)
      .foregroundStyle(enabled ? VKZPalette.telemetry : VKZPalette.textMuted)
      .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }
    .buttonStyle(.plain).disabled(!enabled).accessibilityLabel(title).accessibilityValue(detail)
  }

  private var preparationPanel: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Image(systemName: controller.stage == .respawning ? "heart.slash" : "viewfinder").font(.title2).foregroundStyle(VKZPalette.pending)
        Text(controller.stage.title).font(.title3.bold())
        Spacer(minLength: 0)
        if [.connecting, .waitingForMap, .transferringMap, .relocalizing, .reconnecting].contains(controller.stage) {ProgressView().tint(.white)}
      }
      Text(guidance).font(.subheadline).foregroundStyle(VKZPalette.textMuted).fixedSize(horizontal: false, vertical: true)
      if controller.stage == .measuringReference, let residual = controller.frame.residual {
        Text(String(format: "Reference: %.0f cm · %.2f°", residual.translationMeters * 100, residual.yawDegrees))
          .font(.caption.monospacedDigit()).foregroundStyle(VKZPalette.telemetry)
      }
      if controller.stage == .respawning {
        Text("\(seconds(until: controller.localPlayer?.respawnAtMs ?? 0))").font(.system(.largeTitle, design: .rounded, weight: .black)).monospacedDigit()
      }
      if controller.stage == .mapReady && controller.isHost {
        Button("Share arena scan", action: controller.captureAndShareMap).buttonStyle(VKZPrimaryButtonStyle())
      }
      if controller.eligibility.begin {
        Button(controller.snapshot?.roundStartedAtMs == nil ? "Begin match" : "Resume match", action: controller.beginRound).buttonStyle(VKZPrimaryButtonStyle())
      }
      if controller.stage == .paused || controller.stage == .unavailable {
        Button("Retry alignment", action: controller.retryAlignment).buttonStyle(VKZSecondaryButtonStyle())
        #if os(iOS)
        if controller.message != nil {
          Button("Open Settings") {if let url = URL(string: UIApplication.openSettingsURLString) {openURL(url)}}
            .font(.subheadline.bold()).frame(minHeight: 44)
        }
        #endif
      }
    }
    .padding(18).background(.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 24))
  }

  private var finishedPanel: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Match complete").font(.title.bold())
      ForEach(Array((controller.snapshot?.players ?? []).sorted {lhs, rhs in lhs.kills == rhs.kills ? lhs.deaths < rhs.deaths : lhs.kills > rhs.kills}.enumerated()), id: \.element.id) {index, player in
        HStack {Text("\(index + 1)").font(.title3.bold()).foregroundStyle(VKZPalette.pending); Text(player.displayName).font(.headline); Spacer(); Text("\(player.kills) / \(player.deaths)").font(.headline.monospacedDigit())}
          .accessibilityElement(children: .combine)
      }
      Text("Kills / deaths").font(.caption).foregroundStyle(VKZPalette.textMuted)
      Button("Return to lobby", action: leave).buttonStyle(VKZPrimaryButtonStyle())
    }
    .padding(18).background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 24))
  }

  private var guidance: String {
    if let message = controller.message {return message}
    if case .failed(let explanation) = controller.mapState {return explanation}
    switch controller.stage {
    case .mapping, .mapReady: return "Move slowly and scan the floor, walls and fixed objects around the play area."
    case .waitingForMap: return "The host is scanning the play area. Stay nearby; the shared scan will load automatically."
    case .transferringMap: return "Keep this screen open while the shared arena scan transfers."
    case .relocalizing: return "Point at the same fixed objects the host scanned. Move slowly until the camera recognizes the area."
    case .measuringReference: return "Keep the shared fixed reference in view. An independent reference measurement is required before combat can begin."
    case .awaitingMembers: return "Keep players and their phones visible so their tracked bodies can be identified. Everyone must finish alignment."
    case .paused: return controller.combat.clockReady ? "Keep fixed objects and players in view. Combat resumes when shared tracking and body identity are reliable." : "Synchronizing the match clock. Input resumes after timing is reliable."
    case .reconnecting: return "Your score is retained. Reconnecting and checking the shared arena before input resumes."
    case .respawning: return "Health and ammunition restore automatically. You can keep looking and moving."
    case .unavailable: return "Shared body tracking is unavailable on this device or configuration."
    default: return "Joining the shared arena and synchronizing the match clock."
    }
  }
  private var roundTime: String {
    guard let ms = RealtimeActionEligibility.remainingRoundMs(snapshot: controller.snapshot, now: controller.matchTimeMs ?? controller.snapshot?.matchTimeMs) else {return "—:—"}
    let total = Int(ceil(ms / 1000)); return String(format: "%02d:%02d", total / 60, total % 60)
  }
  private func seconds(until: Double) -> Int {max(0, Int(ceil((until - (controller.matchTimeMs ?? controller.snapshot?.matchTimeMs ?? 0)) / 1000)))}
  private func cooldownText(until: Double, at time: Double) -> String {until > time ? "Ready in \(max(1, Int(ceil((until - time) / 1000))))s" : "Ready"}
  private func shieldDetail(at time: Double) -> String {
    guard let shield = controller.localPlayer?.shield else {return "Waiting"}
    if (shield.activeUntilMs ?? 0) > time {return "\(Int(shield.energy)) energy · \(seconds(until: shield.activeUntilMs ?? 0))s"}
    return cooldownText(until: shield.cooldownUntilMs, at: time)
  }
  private func updateConfirmedSkeleton() {
    guard controller.worldReady else {fx.updateSkeleton(nil, zone: nil); return}
    fx.updateSkeleton(RealtimeAssociationPolicy.hitSkeleton(targetPlayerID: confirmedTargetID,
      association: controller.associatedBody?.association, skeleton: controller.associatedBody?.skeleton, now: Date()), zone: confirmedZone)
  }
  private func clearPresentation() {hitUntil = .distantPast; damageUntil = .distantPast; confirmedTargetID = nil; fx.clearTransientEffects()}
  private func leave() {controller.setTriggerHeld(false); clearPresentation(); onLeave()}
}

private struct RealtimeHoldFireStyle: ButtonStyle {
  let enabled: Bool
  let onPressChanged: (Bool) -> Void
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(enabled ? VKZPalette.background : VKZPalette.textMuted)
      .background(enabled ? (configuration.isPressed ? .white : VKZPalette.pending) : VKZPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 20))
      .onChange(of: configuration.isPressed) {_, pressed in onPressChanged(pressed)}
  }
}

private struct RealtimeRosterStrip: View {
  let players: [CombatWire.Player]
  let localPlayerID: String
  var body: some View {
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
      ForEach(players) {player in
        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 5) {
            Image(systemName: player.connected && player.frameReady ? "checkmark.circle.fill" : "circle.dashed")
              .foregroundStyle(player.frameReady ? VKZPalette.ready : VKZPalette.pending)
            Text(player.displayName + (player.id == localPlayerID ? " · YOU" : "")).font(.caption.bold()).lineLimit(1)
            Spacer(minLength: 0)
            Text("\(player.kills)/\(player.deaths)").font(.caption2.monospacedDigit())
          }
          ProgressView(value: Double(player.health), total: 100).tint(player.health <= 34 ? VKZPalette.danger : VKZPalette.ready)
          Text(!player.connected ? "Disconnected" : player.health == 0 ? "Respawning" : player.frameReady ? "\(player.health) health" : "Aligning")
            .font(.caption2).foregroundStyle(VKZPalette.textMuted)
        }
        .padding(9).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(player.displayName), \(player.health) health, \(player.kills) kills, \(player.deaths) deaths, \(player.connected ? (player.frameReady ? "aligned" : "aligning") : "disconnected")")
      }
    }
  }
}
