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
  @State private var menuPresented = false

  var body: some View {
    ZStack {
      camera.ignoresSafeArea()
      LinearGradient(colors: [.black.opacity(0.3), .clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea().allowsHitTesting(false)
      targetCue
      if controller.now < damageUntil {
        RoundedRectangle(cornerRadius: 30).stroke(VKZPalette.danger.opacity(0.85), lineWidth: reduceMotion ? 8 : 15)
          .ignoresSafeArea().allowsHitTesting(false)
      }
      reticle.allowsHitTesting(false)
      hud.disabled(menuPresented)
    }
    .foregroundStyle(VKZPalette.text)
    .background(VKZPalette.background)
    .sheet(isPresented: $menuPresented) {
      matchMenu
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }
    .onChange(of: menuPresented) {_, _ in controller.setTriggerHeld(false)}
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
    .onChange(of: controller.actionFeedback) {_, feedback in
      #if os(iOS)
      if scenePhase == .active, let feedback {
        UIAccessibility.post(notification: .announcement, argument: feedback)
      }
      #endif
    }
    .onReceive(controller.$confirmedHits) {hits in
      guard scenePhase == .active else {return}
      for hit in hits {
        if hit.incoming {
          damageUntil = Date().addingTimeInterval(0.25)
          fx.renderIncomingLaser(from: nil, hit: true, renderTracer: false)
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
    VStack(spacing: 8) {
      telemetry
      Spacer(minLength: 12)
      if controller.stage == .running {
        actionFeedback
        combatControls
      } else {
        ScrollView {
          VStack(spacing: 8) {
            actionFeedback
            if controller.stage == .finished {finishedPanel}
            else {preparationPanel}
          }
        }
        .frame(maxHeight: dynamicTypeSize.isAccessibilitySize ? .infinity : 420)
      }
    }
    .padding(12)
  }

  @ViewBuilder private var actionFeedback: some View {
    if let feedback = controller.actionFeedback {
      Label(feedback, systemImage: "info.circle.fill")
        .font(.caption.weight(.semibold)).foregroundStyle(VKZPalette.pending)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
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
    HStack(spacing: 10) {
      Label("\(controller.localPlayer?.health ?? 100)", systemImage: "heart.fill")
        .font(.title3.bold().monospacedDigit())
        .foregroundStyle((controller.localPlayer?.health ?? 100) <= 34 ? VKZPalette.danger : VKZPalette.ready)
        .padding(.horizontal, 12).frame(minHeight: 44)
        .background(.black.opacity(0.72), in: Capsule())
        .accessibilityLabel("Health").accessibilityValue("\(controller.localPlayer?.health ?? 100)")
      Spacer(minLength: 0)
      Text(roundTime).font(.title3.bold().monospacedDigit())
        .padding(.horizontal, 12).frame(minHeight: 44)
        .background(.black.opacity(0.72), in: Capsule())
        .accessibilityLabel("Round time remaining")
      Spacer(minLength: 0)
      Button(action: openMenu) {
        Image(systemName: "ellipsis").font(.headline).frame(width: 44, height: 44)
          .background(.black.opacity(0.72), in: Circle())
      }
      .buttonStyle(.plain).accessibilityLabel("Match menu")
      .accessibilityHint("Players, status, help and leave match")
    }
    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
  }

  @ViewBuilder private var targetCue: some View {
    if controller.worldReady, let body = controller.associatedBody, let bounds = fx.projectedTargetBounds(body.skeleton) {
      GeometryReader {geometry in
        RoundedRectangle(cornerRadius: 12)
          .stroke(VKZPalette.ready.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [12, 18]))
          .overlay(alignment: .top) {
            Text(controller.snapshot?.players.first {$0.playerId == body.association.playerID}?.displayName ?? "Target")
              .font(.caption2.bold()).padding(.horizontal, 8).padding(.vertical, 4)
              .background(.black.opacity(0.7), in: Capsule()).padding(.top, 4)
          }
          .frame(width: geometry.size.width * bounds.width, height: geometry.size.height * bounds.height)
          .position(x: geometry.size.width * bounds.centerX, y: geometry.size.height * bounds.centerY)
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
    let fieldStatus = RealtimeArenaPresentation.slowFieldStatus(fields: controller.snapshot?.slowFields ?? [],
      localPlayerID: controller.session.playerId, readyAt: player?.slowFieldReadyAtMs ?? 0, now: time)
    let protection = RealtimeArenaPresentation.protectionDetail(until: player?.protectedUntilMs, now: time)
    return VStack(spacing: 8) {
      if let protection {
        Text(protection).font(.caption.bold()).foregroundStyle(VKZPalette.pending)
          .padding(.horizontal, 12).padding(.vertical, 6)
          .background(.black.opacity(0.78), in: Capsule())
      }
      HStack(spacing: 10) {
        abilityButton(title: (player?.shield.activeUntilMs ?? 0) > time ? "Lower shield" : "Shield", icon: "shield.lefthalf.filled",
          detail: shieldDetail(at: time), enabled: eligibility.shield, action: controller.toggleShield)
        abilityButton(title: "Slow field", icon: "clock.arrow.2.circlepath", detail: fieldStatus.detail,
          enabled: eligibility.slowField, action: controller.activateSlowField)
      }
      HStack(alignment: .bottom, spacing: 12) {
        HStack(spacing: 8) {
          Text("\(controller.displayAmmo) / \(controller.snapshot?.rules.weapon.magazine ?? 0)")
            .font(.title3.bold().monospacedDigit()).lineLimit(1).minimumScaleFactor(0.75)
            .accessibilityLabel("Ammunition")
            .accessibilityValue("\(controller.displayAmmo) of \(controller.snapshot?.rules.weapon.magazine ?? 0)")
          Button(action: controller.reload) {
            VStack(spacing: 2) {
              Image(systemName: "arrow.clockwise").font(.headline)
              Text((player?.reloadEndsAtMs ?? 0) > time ? "Loading" : "Reload").font(.caption2.bold())
            }
            .frame(minWidth: 44, minHeight: 48)
          }
          .buttonStyle(.plain).foregroundStyle(eligibility.reload ? .white : VKZPalette.textMuted)
          .disabled(!eligibility.reload || menuPresented).accessibilityLabel("Reload weapon")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 16))
        Spacer(minLength: 0)
        Button {} label: {
          VStack(spacing: 3) {
            Image(systemName: "scope").font(.title2)
            Text(controller.triggerHeld ? "Firing" : "Hold to fire").font(.caption.bold())
          }
          .frame(minWidth: 104, minHeight: 64).padding(.horizontal, 12)
        }
        .buttonStyle(RealtimeHoldFireStyle(enabled: eligibility.fire || controller.triggerHeld, onPressChanged: {held in
          controller.setTriggerHeld(held && !menuPresented)
        }))
        .disabled(menuPresented || (!eligibility.fire && !controller.triggerHeld))
        .accessibilityLabel("Fire weapon").accessibilityHint("Double tap to fire once. Hold with direct touch for rapid fire.")
        .accessibilityAction {if !menuPresented {controller.fireOnce()}}
      }
      if let reloadEnd = player?.reloadEndsAtMs, reloadEnd > time {
        ProgressView(value: RealtimeArenaPresentation.reloadProgress(until: reloadEnd,
          duration: controller.snapshot?.rules.weapon.reloadMs ?? 1, now: time))
          .tint(VKZPalette.pending)
          .accessibilityLabel("Reloading")
          .accessibilityValue("\(RealtimeArenaPresentation.secondsRemaining(until: reloadEnd, at: time)) seconds remaining")
      }
    }
    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
  }

  private func abilityButton(title: String, icon: String, detail: String, enabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(title, systemImage: icon).font(.caption.bold())
        .frame(maxWidth: .infinity, minHeight: 44).padding(.horizontal, 10)
        .foregroundStyle(enabled ? VKZPalette.telemetry : VKZPalette.textMuted)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(.plain).disabled(!enabled || menuPresented).accessibilityLabel(title).accessibilityValue(detail)
  }

  private func openMenu() {controller.setTriggerHeld(false); menuPresented = true}

  private var matchMenu: some View {
    let player = controller.localPlayer
    let time = controller.matchTimeMs ?? controller.snapshot?.matchTimeMs ?? 0
    let fieldStatus = RealtimeArenaPresentation.slowFieldStatus(fields: controller.snapshot?.slowFields ?? [],
      localPlayerID: controller.session.playerId, readyAt: player?.slowFieldReadyAtMs ?? 0, now: time)
    return VStack(spacing: 0) {
      HStack {
        Text("Match menu").font(.title2.bold())
        Spacer()
        Button {menuPresented = false} label: {
          Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
        }
        .buttonStyle(.plain).accessibilityLabel("Close match menu")
      }
      .padding(.horizontal, 20).padding(.top, 16)
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Text("The match continues while this menu is open.")
            .font(.subheadline).foregroundStyle(VKZPalette.textMuted)
          Text(stageTitle).font(.headline)
          RealtimeRosterStrip(players: controller.snapshot?.players ?? [], localPlayerID: controller.session.playerId)
          VStack(alignment: .leading, spacing: 6) {
            Text(RealtimeArenaPresentation.weaponName(controller.snapshot?.rules.weapon.id)).font(.headline)
            Text(controller.eligibility.reason).font(.subheadline).foregroundStyle(VKZPalette.pending)
            Text("Hold to fire. Reload to refill your magazine.")
              .font(.subheadline).foregroundStyle(VKZPalette.textMuted)
          }
          VStack(alignment: .leading, spacing: 6) {
            Label("Shield · \(shieldDetail(at: time))", systemImage: "shield.lefthalf.filled")
            Label("Slow field · \(fieldStatus.detail)", systemImage: "clock.arrow.2.circlepath")
          }
          .font(.subheadline).foregroundStyle(VKZPalette.telemetry)
          if controller.stage != .running {Text(guidance).font(.subheadline).foregroundStyle(VKZPalette.textMuted)}
          Button(role: .destructive, action: leave) {
            Text(controller.stage == .finished ? "Return home" : "Leave match")
              .frame(maxWidth: .infinity, minHeight: 44)
          }
          .buttonStyle(.plain)
        }
        .padding(20)
      }
    }
    .foregroundStyle(VKZPalette.text).background(VKZPalette.background)
  }

  private var preparationPanel: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Image(systemName: controller.stage == .respawning ? "heart.slash" : "viewfinder").font(.title2).foregroundStyle(VKZPalette.pending)
        Text(stageTitle).font(.title3.bold())
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
      if controller.stage == .mapReady && controller.isHost && controller.savedArenaName == nil {
        RealtimeReferencePanel(state: controller.referenceState, imageData: controller.referenceImageData,
          onCapture: controller.captureReference, onShare: controller.captureAndShareMap)
      } else if [.relocalizing, .measuringReference, .paused, .awaitingMembers].contains(controller.stage) {
        RealtimeReferencePanel(state: controller.referenceState, imageData: controller.referenceImageData)
      }
      if controller.eligibility.begin || controller.startPending {
        Button(action: controller.beginRound) {
          HStack(spacing: 8) {
            if controller.startPending {ProgressView().tint(VKZPalette.background)}
            Text(controller.startPending ? "Starting match…" : "Begin match")
          }
        }
        .buttonStyle(VKZPrimaryButtonStyle()).disabled(controller.startPending)
        .accessibilityLabel(controller.startPending ? "Starting match" : "Begin match")
      }
      if controller.stage == .measuringReference && controller.referenceState == .unavailable {
        Button("Return home", action: leave).buttonStyle(VKZPrimaryButtonStyle())
      }
      if controller.connectionIssue != nil || controller.stage == .reconnecting {
        Button("Retry connection", action: controller.retryConnection).buttonStyle(VKZSecondaryButtonStyle())
      }
      if controller.isHost && controller.savedArenaName == nil && ([.mapping, .mapReady].contains(controller.stage) || scanTimedOut) {
        Button("Restart scan", action: controller.retryAlignment).buttonStyle(VKZSecondaryButtonStyle())
      } else if controller.stage == .paused || controller.stage == .unavailable {
        if controller.connectionIssue == nil {
          Button("Retry alignment", action: controller.retryAlignment).buttonStyle(VKZSecondaryButtonStyle())
        }
        #if os(iOS)
        if controller.canOpenCameraSettings {
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
      Button("Return home", action: leave).buttonStyle(VKZPrimaryButtonStyle())
    }
    .padding(18).background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 24))
  }

  private var guidance: String {
    if let issue = controller.connectionIssue {return issue}
    if let message = controller.message {return message}
    if case .failed(let explanation) = controller.mapState {return explanation}
    if let initialScan {return initialScan.guidance}
    if let name = controller.savedArenaName, [.mapping, .mapReady, .relocalizing].contains(controller.stage) {
      return "Loading \(name). Point at the fixed objects you scanned so your phone can recognize this arena."
    }
    if scanTimedOut {
      return "The camera couldn't find enough stable detail. Point at a well-lit floor, wall or fixed object, then restart the scan."
    }
    switch controller.stage {
    case .mapping: return "Move slowly around the play area, keeping the floor, walls and fixed objects in view. Avoid aiming only at a blank wall."
    case .mapReady: return "The area is scanned. Hold still and capture a fixed object that every player can recognize."
    case .waitingForMap: return "Waiting for the host’s arena scan. Stay nearby; it will load automatically."
    case .transferringMap: return "Keep this screen open while the shared arena scan transfers."
    case .relocalizing: return "Point at the same fixed objects the host scanned. Move slowly until the camera recognizes the area."
    case .measuringReference:
      return controller.referenceState == .unavailable
        ? "This older arena scan has no shared reference. Return home and create a new arena to capture one."
        : "Point at the reference shown below and hold steady. Each phone must recognize it before the match can begin. Keep it in view while playing."
    case .awaitingMembers: return "Keep players and their phones in view. The host begins when everyone has finished alignment."
    case .paused: return RealtimeArenaPresentation.pauseGuidance(clockReady: controller.combat.clockReady,
      roundHasStarted: controller.snapshot?.roundStartedAtMs != nil)
    case .reconnecting: return "Your score is retained. Reconnecting and checking the shared arena before input resumes."
    case .respawning: return "Health and ammunition restore automatically. You can keep looking and moving."
    case .unavailable: return "Shared body tracking is unavailable on this device or configuration."
    default: return "Joining the shared arena and synchronizing the match clock."
    }
  }
  private var stageTitle: String {
    if controller.connectionIssue != nil {return "Connection needs attention"}
    if let initialScan {return initialScan.title}
    if scanTimedOut {return "Scan needs another try"}
    if controller.stage == .paused && !controller.combat.clockReady {return "Synchronizing match"}
    if controller.savedArenaName != nil && [.mapping, .mapReady, .relocalizing].contains(controller.stage) {
      return "Align with saved arena"
    }
    return controller.stage.title
  }
  private var scanTimedOut: Bool {
    controller.connection == .connected && controller.frame.failure == .mappingTimedOut
  }
  private var initialScan: ArenaScanPresentation? {
    guard controller.connection == .connected, controller.isHost, controller.savedArenaName == nil,
      controller.frame.frameID == nil, controller.frame.epoch != nil,
      [.mapping, .lost].contains(controller.frame.stage),
      controller.mapState == .mapping
    else {return nil}
    return ArenaScanPresentation(frame: controller.frame)
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
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let players: [CombatWire.Player]
  let localPlayerID: String
  var body: some View {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 7) {
      ForEach(players) {player in
        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 5) {
            Image(systemName: player.connected && player.frameReady ? "checkmark.circle.fill" : "circle.dashed")
              .foregroundStyle(player.frameReady ? VKZPalette.ready : VKZPalette.pending)
            Text(player.displayName + (player.id == localPlayerID ? " · YOU" : "")).font(.caption.bold()).fixedSize(horizontal: false, vertical: true)
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
