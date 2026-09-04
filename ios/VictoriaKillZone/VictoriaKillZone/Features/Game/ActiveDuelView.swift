import SwiftUI

#if os(iOS)
import UIKit
#endif

struct ActiveDuelView: View {
  let duel: ActiveDuel
  @ObservedObject var store: LobbyStore
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var fx = LaserFXEngine()
  @StateObject private var voiceFire = VoiceFireController()
  @State private var muzzleFlash = false

  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.2)) { context in
      ZStack {
        cameraSurface
          .ignoresSafeArea()

        LinearGradient(
          colors: [.black.opacity(0.72), .clear, .black.opacity(0.82)],
          startPoint: .top,
          endPoint: .bottom
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)

        if muzzleFlash {
          Rectangle()
            .fill(.white.opacity(0.22))
            .ignoresSafeArea()
            .allowsHitTesting(false)
          Circle()
            .fill(
              RadialGradient(
                colors: [.white, .red.opacity(0.85), .clear],
                center: .center,
                startRadius: 2,
                endRadius: 190
              )
            )
            .frame(width: 380, height: 380)
            .allowsHitTesting(false)
        }

        if let killBanner = store.killBanner {
          killBannerView(killBanner)
            .transition(.scale(scale: 0.72).combined(with: .opacity))
            .zIndex(2)
        }

        VStack(spacing: 14) {
          topTelemetry(at: context.date)
          connectionBanner
          Spacer(minLength: 12)
          reticle
          targetReadout
          Spacer(minLength: 12)
          opponentPanel
          shotControl
          latestEvent
          Button("LEAVE DUEL", role: .destructive) {
            store.leave()
          }
          .font(.caption.bold().monospaced())
        }
        .padding(18)
        .opacity(store.isMatchInputLocked ? 0.58 : 1)

        if isLocalRespawning {
          deathOverlay(at: context.date)
        }
      }
    }
    .onAppear {
      voiceFire.setViewVisible(true)
      voiceFire.setSceneActive(scenePhase == .active)
    }
    .task {
      await store.startTargeting()
    }
    .onDisappear {
      voiceFire.setViewVisible(false)
      voiceFire.setSceneActive(false)
      Task { await store.stopTargeting() }
    }
    .onChange(of: scenePhase) { phase in
      voiceFire.setSceneActive(phase == .active)
    }
    .onChange(of: voiceFire.fireRequestSequence) { _ in
      fireShot()
    }
    .onChange(of: store.killBanner) { banner in
      guard banner?.isLocalKill == true else { return }
      #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
      #endif
    }
    .onChange(of: store.incomingShot) { shot in
      guard let shot else { return }
      #if os(iOS)
        let opponentOrigin: SIMD3<Float>?
        if store.targetingSnapshot.isPoseFresh(at: Date()),
          let position = store.targetingSnapshot.skeleton?.position(of: "head")
        {
          opponentOrigin = SIMD3<Float>(Float(position.x), Float(position.y), Float(position.z))
        } else {
          opponentOrigin = nil
        }
        fx.renderIncomingLaser(from: opponentOrigin, hit: shot.hit)
      #endif
    }
    .onChange(of: store.targetingSnapshot) { snapshot in
      #if os(iOS)
        let skeleton = snapshot.isLocked && snapshot.isPoseFresh(at: Date())
          ? snapshot.skeleton
          : nil
        fx.updateSkeleton(skeleton, zone: snapshot.hitZone)
      #endif
    }
  }

  @ViewBuilder
  private var cameraSurface: some View {
    #if os(iOS) && canImport(ARKit) && canImport(AVFoundation) && canImport(Vision)
      if let targeting = store.environment.targetingSession as? ARVisionTargetingSession {
        ARCameraPreview(targeting: targeting, fxEngine: fx)
      } else {
        fallbackCameraSurface
      }
    #else
      fallbackCameraSurface
    #endif
  }

  private var fallbackCameraSurface: some View {
    LinearGradient(
      colors: [VKZPalette.background, VKZPalette.surfaceRaised],
      startPoint: .top,
      endPoint: .bottom
    )
  }

  private func killBannerView(_ banner: KillBanner) -> some View {
    Text(banner.text)
      .font(.system(size: 28, weight: .black, design: .monospaced))
      .foregroundStyle(banner.isLocalKill ? VKZPalette.ready : VKZPalette.danger)
      .multilineTextAlignment(.center)
      .lineLimit(2)
      .minimumScaleFactor(0.7)
      .padding(.horizontal, 24)
      .padding(.vertical, 18)
      .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 16))
      .overlay {
        RoundedRectangle(cornerRadius: 16)
          .stroke(
            (banner.isLocalKill ? VKZPalette.ready : VKZPalette.danger).opacity(0.7),
            lineWidth: 2
          )
      }
      .shadow(color: .black.opacity(0.7), radius: 12)
      .padding(.horizontal, 20)
      .animation(.spring(response: 0.28, dampingFraction: 0.78), value: banner.eventID)
      .allowsHitTesting(false)
  }

  private func topTelemetry(at date: Date) -> some View {
    HStack(alignment: .top) {
      telemetryBlock(
        label: "HEALTH",
        value: String(duel.localPlayer?.health ?? 0),
        color: localHealthColor
      )
      Spacer()
      VStack(spacing: 3) {
        Text(phaseTitle)
          .font(.caption.weight(.bold).monospaced())
          .foregroundStyle(VKZPalette.telemetry)
        if duel.phase == .countdown {
          Text(String(countdownValue(at: date)))
            .font(.system(size: 38, weight: .black, design: .monospaced))
            .accessibilityLabel("Duel starts in \(countdownValue(at: date))")
        } else {
          Text("\(duel.localPlayer?.kills ?? 0)–\(duel.localPlayer?.deaths ?? 0)")
            .font(.title3.bold().monospacedDigit())
        }
      }
      Spacer()
      telemetryBlock(
        label: "AMMO",
        value: "\(duel.localPlayer?.ammo ?? 0) / 8",
        color: .white
      )
    }
  }

  @ViewBuilder
  private var connectionBanner: some View {
    if store.isMatchInputLocked {
      Text("RECONNECTING — INPUT LOCKED")
        .font(.caption.bold().monospaced())
        .foregroundStyle(VKZPalette.pending)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.black.opacity(0.7), in: Capsule())
    } else if store.syncStatus == .restored {
      VKZStatusPill(label: "STATE VERIFIED", color: VKZPalette.ready)
    }
  }

  private var reticle: some View {
    ZStack {
      Circle()
        .stroke(reticleColor.opacity(0.9), lineWidth: 2)
        .frame(width: 44, height: 44)
      Rectangle()
        .fill(reticleColor)
        .frame(width: 14, height: 2)
      Rectangle()
        .fill(reticleColor)
        .frame(width: 2, height: 14)
      Circle()
        .fill(reticleColor)
        .frame(width: 4, height: 4)
    }
    .shadow(color: .black.opacity(0.8), radius: 3)
    .accessibilityLabel(store.markerlessAimZone == nil ? "No target lock" : "Target locked")
  }

  private var targetReadout: some View {
    HStack(spacing: 8) {
      VKZStatusPill(label: store.targetingStatus, color: reticleColor)
      if let zone = store.markerlessAimZone {
        VKZStatusPill(label: zone.rawValue.uppercased(), color: reticleColor)
      }
      if store.targetingSnapshot.isLocked,
        store.targetingSnapshot.isPoseFresh(at: Date()),
        store.targetingSnapshot.skeleton != nil
      {
        VKZStatusPill(label: "SKELETON", color: VKZPalette.ready)
      }
    }
  }

  private var opponentPanel: some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Text(duel.opponent?.displayName.uppercased() ?? "OPPONENT")
          .font(.caption.bold().monospaced())
        Text(opponentStateText)
          .font(.caption2.monospaced())
          .foregroundStyle(VKZPalette.textMuted)
      }
      Spacer()
      Text("\(duel.opponent?.health ?? 0)")
        .font(.system(size: 36, weight: .black, design: .monospaced))
        .foregroundStyle(VKZPalette.danger)
      Text("HP")
        .font(.caption.bold().monospaced())
        .foregroundStyle(VKZPalette.textMuted)
    }
    .padding(14)
    .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 14))
    .overlay {
      RoundedRectangle(cornerRadius: 14)
        .stroke(.white.opacity(0.14), lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var shotControl: some View {
    switch duel.phase {
    case .countdown:
      Text("DUEL STARTS IN")
        .font(.headline.monospaced())
        .foregroundStyle(VKZPalette.pending)
    case .running:
      VStack(spacing: 8) {
        voiceControl
        Button(shotButtonLabel) {
          fireShot()
        }
        .buttonStyle(VKZPrimaryButtonStyle())
        .accessibilityLabel("Fire markerless shot")

        if duel.localRole == .host {
          Button("DEBUG TORSO FALLBACK") {
            store.debugFire()
          }
          .font(.caption2.bold().monospaced())
          .foregroundStyle(VKZPalette.textMuted)
          .disabled(!store.canDebugFire)
        }
      }
    case .finished:
      Text("DUEL COMPLETE")
        .font(.title.bold())
    case .cancelled:
      Text("DUEL CANCELLED")
        .font(.title.bold())
    case .lobby:
      EmptyView()
    }
  }

  private var voiceControl: some View {
    Toggle(
      isOn: Binding(
        get: { voiceFire.isEnabled },
        set: { $0 ? voiceFire.enable() : voiceFire.disable() }
      )
    ) {
      VStack(alignment: .leading, spacing: 2) {
        Text("VOICE FIRE")
          .font(.caption.weight(.bold).monospaced())
        Text(voiceFire.status.displayText)
          .font(.caption2.weight(.semibold).monospaced())
          .foregroundStyle(voiceStatusColor)
        if case .listening = voiceFire.status {
          Text("SAY “PEW PEW”")
            .font(.caption.weight(.bold).monospaced())
        }
      }
    }
    .tint(VKZPalette.telemetry)
    .padding(12)
    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
    .accessibilityLabel("Voice Fire")
  }

  private func fireShot() {
    let canFireMarkerless = store.canFireMarkerless
    let canFireDebug = store.canDebugFire
    guard canFireMarkerless || canFireDebug else { return }
    fx.fireLaser(hit: canFireMarkerless)
    if canFireMarkerless {
      store.fireMarkerless()
    } else {
      store.debugFire()
    }
    withAnimation(.easeOut(duration: 0.12)) {
      muzzleFlash = true
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
      withAnimation(.easeOut(duration: 0.12)) {
        muzzleFlash = false
      }
    }
  }

  private var voiceStatusColor: Color {
    switch voiceFire.status {
    case .disabled: VKZPalette.textMuted
    case .requestingPermission: VKZPalette.pending
    case .enabled: VKZPalette.telemetry
    case .listening: VKZPalette.ready
    case .unavailable: VKZPalette.danger
    }
  }

  @ViewBuilder
  private var latestEvent: some View {
    if let event = duel.events.first {
      Text(event.message)
        .font(.caption.monospaced())
        .foregroundStyle(VKZPalette.text)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: Capsule())
        .accessibilityAddTraits(.updatesFrequently)
    }
  }

  private func deathOverlay(at date: Date) -> some View {
    ZStack {
      Color.black.opacity(0.88).ignoresSafeArea()
      VStack(spacing: 14) {
        Text("ELIMINATED")
          .font(.system(size: 42, weight: .black, design: .rounded))
          .foregroundStyle(VKZPalette.danger)
        Text("RESPAWN IN \(respawnSeconds(at: date))")
          .font(.title2.bold().monospacedDigit())
        Text("HEALTH AND AMMO RESTORE AUTOMATICALLY")
          .font(.caption.monospaced())
          .foregroundStyle(VKZPalette.textMuted)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var shotButtonLabel: String {
    if isLocalRespawning { return "RESPAWNING…" }
    if duel.opponent?.lifeState == .respawning || duel.opponent?.health == 0 {
      return "OPPONENT RESPAWNING"
    }
    switch store.markerlessShotState {
    case .idle: return store.markerlessAimZone == nil ? "ACQUIRE TARGET" : "FIRE"
    case .pending(let zone): return "\(zone.rawValue.uppercased()) SHOT…"
    case .confirmed(.kill, _, _): return "ELIMINATION CONFIRMED"
    case .confirmed(_, let zone, let damage):
      return "\(zone.rawValue.uppercased()) HIT • \(damage)"
    case .failed: return "RETRY SHOT"
    }
  }

  private var opponentStateText: String {
    guard let opponent = duel.opponent else { return "SEARCHING" }
    switch opponent.lifeState {
    case .alive: return "K/D \(opponent.kills)/\(opponent.deaths)"
    case .dead, .respawning: return "RESPAWNING"
    case .disconnected: return "DISCONNECTED"
    }
  }

  private var isLocalRespawning: Bool {
    guard let player = duel.localPlayer else { return false }
    return player.health == 0 || player.lifeState == .dead || player.lifeState == .respawning
  }

  private var reticleColor: Color {
    switch store.markerlessAimZone {
    case .head: VKZPalette.danger
    case .torso, .limbs: VKZPalette.ready
    case nil: .white
    }
  }

  private var localHealthColor: Color {
    (duel.localPlayer?.health ?? 0) <= 34 ? VKZPalette.danger : VKZPalette.ready
  }

  private var phaseTitle: String {
    switch duel.phase {
    case .lobby: "WAITING"
    case .countdown: "DUEL STARTS IN"
    case .running: "LIVE DUEL"
    case .finished: "DUEL COMPLETE"
    case .cancelled: "DUEL CANCELLED"
    }
  }

  private func countdownValue(at date: Date) -> Int {
    guard let startsAt = duel.startsAt else { return 0 }
    return max(0, Int(ceil((startsAt - estimatedServerNow(at: date)) / 1_000)))
  }

  private func respawnSeconds(at date: Date) -> Int {
    guard let respawnAt = duel.localPlayer?.respawnAt else { return 0 }
    return max(0, Int(ceil((respawnAt - estimatedServerNow(at: date)) / 1_000)))
  }

  private func estimatedServerNow(at date: Date) -> Double {
    duel.serverNow + max(0, date.timeIntervalSince(duel.syncedAt) * 1_000)
  }

  private func telemetryBlock(label: String, value: String, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.caption2.weight(.semibold).monospaced())
        .foregroundStyle(VKZPalette.textMuted)
      Text(value)
        .font(.title3.bold().monospacedDigit())
        .foregroundStyle(color)
    }
    .accessibilityElement(children: .combine)
  }
}
