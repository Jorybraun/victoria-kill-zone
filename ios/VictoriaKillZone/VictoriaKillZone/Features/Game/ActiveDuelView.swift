import SwiftUI

#if os(iOS)
import UIKit
#endif

struct ActiveDuelView: View {
  let duel: ActiveDuel
  @ObservedObject var combat: DuelSession
  @ObservedObject var store: LobbyStore
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openURL) private var openURL
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @StateObject private var fx = LaserFXEngine()
  @StateObject private var voiceFire = VoiceFireController()
  @State private var muzzleFlash = false
  @State private var incomingFlash = false
  @State private var hitMarker = false
  @State private var toastEventID: String?
  @State private var toastVisible = false
  @State private var toastTask: Task<Void, Never>?
  @State private var hitTask: Task<Void, Never>?
  @State private var damageTask: Task<Void, Never>?
  @State private var muzzleTask: Task<Void, Never>?
  @State private var shotNotice: String?
  @State private var shotNoticeTask: Task<Void, Never>?
  @State private var menuPresented = false

  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.05)) { context in
      ZStack {
        cameraSurface
          .ignoresSafeArea()

        LinearGradient(
          colors: [.black.opacity(0.3), .clear, .black.opacity(0.35)],
          startPoint: .top,
          endPoint: .bottom
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)

        RadialGradient(
          colors: [.clear, .clear, VKZPalette.danger.opacity(0.75)],
          center: .center,
          startRadius: 120,
          endRadius: 520
        )
        .opacity(incomingFlash ? 1 : 0)
        .ignoresSafeArea()
        .allowsHitTesting(false)

        if muzzleFlash {
          Rectangle()
            .fill(.white.opacity(0.07))
            .ignoresSafeArea()
            .allowsHitTesting(false)
          Circle()
            .fill(
              RadialGradient(
                colors: [.white.opacity(0.25), VKZPalette.pending.opacity(0.15), .clear],
                center: .center,
                startRadius: 2,
                endRadius: 190
              )
            )
            .frame(width: 380, height: 380)
            .allowsHitTesting(false)
        }

        if let killBanner = combat.killBanner {
          killBannerView(killBanner)
            .transition(.scale(scale: 0.72).combined(with: .opacity))
            .zIndex(2)
        }

        reticleArea
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .ignoresSafeArea()
          .allowsHitTesting(false)

        VStack(spacing: 8) {
          topTelemetry(at: context.date)
          if store.isMatchInputLocked || !combat.presenceReady { connectionBanner }
          if let blocker = store.targetingBlocker {
            Button(action: openMenu) {
              Label(blocker.title, systemImage: "exclamationmark.circle")
                .font(.caption.bold()).multilineTextAlignment(.leading)
                .frame(minHeight: 44).padding(.horizontal, 12)
                .foregroundStyle(VKZPalette.pending)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain).accessibilityHint("Opens the explanation and available recovery actions")
          }
          Spacer(minLength: 12)
          if duel.phase == .running {
            bottomStack
          } else {
            phaseControl
          }
        }
        .padding(12)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .opacity(store.isMatchInputLocked ? 0.58 : 1)
        .disabled(menuPresented)

        if isLocalRespawning {
          deathOverlay(at: context.date)
        }
      }
    }
    .sheet(isPresented: $menuPresented) {
      matchMenu
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }
    .onChange(of: menuPresented) { _, presented in
      combat.stopRepeatingFire()
      voiceFire.setViewVisible(!presented)
    }
    .onAppear {
      combat.setSceneActive(scenePhase == .active)
      voiceFire.setViewVisible(!menuPresented)
      voiceFire.setSceneActive(scenePhase == .active)
    }
    .task {
      await store.startTargeting()
    }
    .onDisappear {
      voiceFire.setViewVisible(false)
      voiceFire.setSceneActive(false)
      toastTask?.cancel()
      hitTask?.cancel()
      damageTask?.cancel()
      muzzleTask?.cancel()
      combat.setSceneActive(false)
      clearFeedback()
      Task { await store.stopTargeting() }
    }
    .onChange(of: store.errorMessage) { _, message in
      guard let message, duel.phase == .running else { return }
      showShotNotice(message)
      store.dismissError()
    }
    .onChange(of: scenePhase) { _, phase in
      voiceFire.setSceneActive(phase == .active)
      combat.setSceneActive(phase == .active)
      if phase != .active { clearFeedback() }
    }
    .onChange(of: voiceFire.fireRequestSequence) { _, _ in
      fireShot()
    }
    .onChange(of: combat.killBanner) { _, banner in
      guard banner?.isLocalKill == true else { return }
      #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
      #endif
    }
    .onChange(of: duel.events.first?.id) { _, eventID in
      guard let eventID else { return }
      toastEventID = eventID
      toastTask?.cancel()
      withAnimation(.easeOut(duration: 0.2)) {
        toastVisible = true
      }
      toastTask = Task { @MainActor in
        try? await Task.sleep(for: .seconds(2.5))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.2)) {
          toastVisible = false
        }
      }
    }
    .onChange(of: combat.outgoingShot) { _, shot in
      guard scenePhase == .active, duel.phase == .running, let shot else { return }
      fx.fireLaser(hit: false, ray: shot.ray)
      guard !reduceMotion else { return }
      muzzleTask?.cancel()
      muzzleFlash = true
      muzzleTask = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(45))
        guard !Task.isCancelled else { return }
        muzzleFlash = false
      }
    }
    .onChange(of: combat.markerlessShotState) { _, state in
      guard scenePhase == .active, duel.phase == .running,
        case .confirmed(let outcome, let zone, let damage) = state,
        (outcome == .hit || outcome == .kill), damage > 0
      else { return }
      hitTask?.cancel()
      hitMarker = true
      let snapshot = store.targetingSnapshot
      fx.confirmHit(
        skeleton: snapshot.isPoseFresh(at: Date()) ? snapshot.skeleton : nil,
        zone: zone.flatMap { TargetingHitZone(rawValue: $0.rawValue) }
      )
      hitTask = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(280))
        guard !Task.isCancelled else { return }
        hitMarker = false
      }
    }
    .onReceive(combat.$incomingShots) { shots in
      guard scenePhase == .active, duel.phase == .running else { return }
      for shot in shots {
      if shot.hit {
        damageTask?.cancel()
        incomingFlash = true
        damageTask = Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(250))
          guard !Task.isCancelled else { return }
          incomingFlash = false
        }
      }
      #if os(iOS)
        let position = store.targetingSnapshot.isPoseFresh(at: Date())
          ? store.targetingSnapshot.skeleton?.position(of: "head") : nil
        let origin = shot.renderTracer ? position.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) } : nil
        fx.renderIncomingLaser(from: origin, hit: shot.hit, renderTracer: shot.renderTracer)
      #endif
      }
    }
    .onChange(of: store.targetingSnapshot) { _, snapshot in
      guard scenePhase == .active, duel.phase == .running else { return }
      fx.updateSkeleton(
        snapshot.isPoseFresh(at: Date()) ? snapshot.skeleton : nil,
        zone: snapshot.hitZone
      )
    }
    .onChange(of: duel.phase) { _, phase in
      if phase != .running { clearFeedback() }
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
    HStack(spacing: 10) {
      Label(String(duel.localPlayer?.health ?? 0), systemImage: "heart.fill")
        .font(.title3.bold().monospacedDigit()).foregroundStyle(localHealthColor)
        .padding(.horizontal, 12).frame(minHeight: 44)
        .background(.black.opacity(0.72), in: Capsule())
        .accessibilityLabel("Health").accessibilityValue("\(duel.localPlayer?.health ?? 0)")
      Spacer(minLength: 0)
      Text(duel.phase == .countdown ? String(countdownValue(at: date)) : roundTime(at: date))
        .font(.title3.bold().monospacedDigit()).foregroundStyle(.white)
        .padding(.horizontal, 12).frame(minHeight: 44)
        .background(.black.opacity(0.72), in: Capsule())
        .accessibilityLabel(duel.phase == .countdown ? "Match starts in" : "Round time remaining")
      Spacer(minLength: 0)
      Button(action: openMenu) {
        Image(systemName: "ellipsis").font(.headline)
          .frame(width: 44, height: 44)
          .foregroundStyle(.white).background(.black.opacity(0.72), in: Circle())
      }
      .buttonStyle(.plain).accessibilityLabel("Match menu")
      .accessibilityHint("Scores, voice fire, help and leave match")
    }
  }

  private func roundTime(at date: Date) -> String {
    let remaining = max(0, Int(ceil(((duel.endsAt ?? estimatedServerNow(at: date)) - estimatedServerNow(at: date)) / 1000)))
    return String(format: "%02d:%02d", remaining / 60, remaining % 60)
  }

  @ViewBuilder
  private var connectionBanner: some View {
    if store.isMatchInputLocked || !combat.presenceReady {
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

  private var opponentStrip: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        Text(duel.opponent?.displayName.uppercased() ?? "OPPONENT")
          .font(.caption.bold().monospaced())
        Text(opponentStateText)
          .font(.caption2.monospaced())
          .foregroundStyle(VKZPalette.textMuted)
      }
      GeometryReader { proxy in
        Capsule()
          .fill(.white.opacity(0.15))
          .overlay(alignment: .leading) {
            Capsule()
              .fill(VKZPalette.danger)
              .frame(width: proxy.size.width * opponentHealthFraction)
              .animation(.easeOut(duration: 0.25), value: opponentHealthFraction)
          }
      }
      .frame(height: 6)
      Text("HP \(duel.opponent?.health ?? 0)")
        .font(.caption.monospacedDigit())
        .foregroundStyle(VKZPalette.text)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .combine)
  }

  private var reticleArea: some View {
    ZStack {
      reticle
      hitMarkerView
    }
    .frame(width: 80, height: 80)
    .overlay(alignment: .bottom) {
      if hitMarker || combat.markerlessAimZone != nil {
        Text(hitMarker ? "HIT CONFIRMED" : "ON TARGET")
          .font(.system(size: 10, weight: .bold, design: .monospaced))
          .tracking(1.5)
          .foregroundStyle(hitMarker ? VKZPalette.pending : VKZPalette.ready)
          .fixedSize().padding(6)
          .background(.black.opacity(0.55), in: Capsule())
          .offset(y: 30)
      }
    }
  }

  @ViewBuilder
  private var reticle: some View {
    if !store.targetingSnapshot.isLocked, combat.markerlessAimZone == nil {
      TimelineView(.animation(minimumInterval: 1 / 20)) { context in
        reticleGraphic(
          opacity: 0.775
            + 0.225 * sin(context.date.timeIntervalSinceReferenceDate * 3)
        )
      }
    } else {
      reticleGraphic(opacity: 1)
    }
  }

  private func reticleGraphic(opacity: Double) -> some View {
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
      Circle()
        .stroke(reticleColor, lineWidth: 2)
        .frame(width: 64, height: 64)
        .opacity(store.targetingSnapshot.isLocked ? 1 : 0)
        .scaleEffect(store.targetingSnapshot.isLocked ? 1 : 1.5)
        .animation(
          .spring(response: 0.25, dampingFraction: 0.7),
          value: store.targetingSnapshot.isLocked
        )
    }
    .opacity(opacity)
    .shadow(color: .black.opacity(0.8), radius: 3)
    .accessibilityLabel(combat.markerlessAimZone == nil ? "No target lock" : "Target locked")
  }

  private var hitMarkerView: some View {
    ZStack {
      hitMarkerArm(rotation: 45)
        .offset(x: 30, y: -30)
      hitMarkerArm(rotation: -45)
        .offset(x: -30, y: -30)
      hitMarkerArm(rotation: -45)
        .offset(x: 30, y: 30)
      hitMarkerArm(rotation: 45)
        .offset(x: -30, y: 30)
    }
    .opacity(hitMarker ? 1 : 0)
    .scaleEffect(hitMarker ? 1 : 1.4)
    .animation(.easeOut(duration: 0.15), value: hitMarker)
  }

  private func hitMarkerArm(rotation: Double) -> some View {
    Rectangle()
      .fill(VKZPalette.pending)
      .frame(width: 14, height: 3)
      .rotationEffect(.degrees(rotation))
  }

  private var bottomStack: some View {
    VStack(spacing: 8) {
      latestEvent
      shotNoticeView
      HStack(alignment: .bottom, spacing: 12) {
        HStack(spacing: 8) {
          Text("\(duel.localPlayer?.ammo ?? 0) / 8")
            .font(.title3.bold().monospacedDigit()).lineLimit(1).minimumScaleFactor(0.75)
            .foregroundStyle(combat.isReloading ? VKZPalette.pending : .white)
            .accessibilityLabel("Ammunition").accessibilityValue("\(duel.localPlayer?.ammo ?? 0) of 8")
          Button { combat.reload() } label: {
            VStack(spacing: 2) {
              Image(systemName: "arrow.clockwise").font(.headline)
              Text(combat.isReloading ? "Loading" : "Reload").font(.caption2.bold())
            }
            .frame(minWidth: 44, minHeight: 48)
            .foregroundStyle(combat.canReload ? .white : VKZPalette.textMuted)
          }
          .buttonStyle(.plain).disabled(!combat.canReload || menuPresented)
          .accessibilityLabel("Reload sidearm")
          .accessibilityValue(combat.isReloading ? "Reloading" : "")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 16))
        Spacer(minLength: 0)
        VStack(spacing: 3) {
          Image(systemName: "scope").font(.title2)
          Text(combat.isTriggerHeld ? "Firing" : "Hold to fire").font(.caption.bold())
        }
        .frame(minWidth: 104, minHeight: 64)
        .padding(.horizontal, 12)
        .foregroundStyle(VKZPalette.background)
        .background(combat.isTriggerHeld ? .white : VKZPalette.pending, in: RoundedRectangle(cornerRadius: 18))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { value in
              guard !menuPresented else { combat.stopRepeatingFire(); return }
              if abs(value.translation.width) > 80 || abs(value.translation.height) > 80 {
                combat.stopRepeatingFire()
              } else if combat.isTriggerHeld || combat.canFireMarkerless {
                combat.startRepeatingFire()
              } else {
                showShotNotice(blockedShotNotice)
              }
            }
            .onEnded { _ in combat.stopRepeatingFire() }
        )
        .accessibilityLabel("Fire sidearm")
        .accessibilityHint("Double tap to fire one shot. Hold with direct touch for repeat fire.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { fireShot() }
      }
    }
  }

  private func openMenu() {
    combat.stopRepeatingFire()
    voiceFire.setViewVisible(false)
    menuPresented = true
  }

  private var matchMenu: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Match menu").font(.title2.bold())
        Spacer()
        Button { menuPresented = false } label: {
          Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
        }
        .buttonStyle(.plain).accessibilityLabel("Close match menu")
      }
      .padding(.horizontal, 20).padding(.top, 16)
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Text("The match continues while this menu is open.")
            .font(.subheadline).foregroundStyle(VKZPalette.textMuted)
          HStack {
            Text(phaseTitle).font(.headline)
            Spacer()
            Text("\(duel.localPlayer?.kills ?? 0) kills · \(duel.localPlayer?.deaths ?? 0) deaths")
              .font(.subheadline.monospacedDigit())
          }
          opponentStrip
          connectionBanner
          if let blocker = store.targetingBlocker { targetingBlockerPanel(blocker) }
          VStack(alignment: .leading, spacing: 6) {
            Text("Standard sidearm").font(.headline)
            Text(shotButtonLabel).font(.subheadline).foregroundStyle(VKZPalette.pending)
            Text("Aim at your opponent, hold to fire, and reload when your magazine is empty.")
              .font(.subheadline).foregroundStyle(VKZPalette.textMuted)
          }
          HStack(spacing: 12) {
            voiceToggle
            VStack(alignment: .leading, spacing: 4) {
              Text("Voice fire").font(.headline)
              Text(voiceFire.status.displayText).font(.subheadline).foregroundStyle(voiceStatusColor)
              Text("Say “pew pew” during play to fire.").font(.caption).foregroundStyle(VKZPalette.textMuted)
            }
          }
          Button(role: .destructive) {
            combat.stopRepeatingFire(); voiceFire.setViewVisible(false); store.leave()
          } label: {
            Text("Leave match").frame(maxWidth: .infinity, minHeight: 44)
          }
          .buttonStyle(.plain)
        }
        .padding(20)
      }
    }
    .foregroundStyle(VKZPalette.text).background(VKZPalette.background)
  }

  private var voiceToggle: some View {
    Button {
      if voiceFire.isEnabled {
        voiceFire.disable()
      } else {
        voiceFire.enable()
      }
    } label: {
      Image(systemName: voiceFire.isEnabled ? "mic.fill" : "mic.slash.fill")
        .font(.title3)
        .foregroundStyle(voiceStatusColor)
        .frame(width: 56, height: 56)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
    }
    .accessibilityLabel("Voice Fire")
    .accessibilityValue(voiceFire.status.accessibilityText)
  }

  private var voiceStatusCaption: String {
    if case .listening = voiceFire.status {
      return "\(voiceFire.status.displayText) • SAY “PEW PEW”"
    }
    return voiceFire.status.displayText
  }

  @ViewBuilder
  private var phaseControl: some View {
    switch duel.phase {
    case .countdown:
      Text("DUEL STARTS IN")
        .font(.headline.monospaced())
        .foregroundStyle(VKZPalette.pending)
    case .finished:
      Text("DUEL COMPLETE")
        .font(.title.bold())
    case .cancelled:
      Text("DUEL CANCELLED")
        .font(.title.bold())
    case .lobby, .running:
      EmptyView()
    }
    Button("LEAVE DUEL", role: .destructive) {
      store.leave()
    }
    .font(.caption.bold().monospaced())
    .accessibilityLabel("Leave duel")
  }

  private func targetingBlockerPanel(_ blocker: TargetingBlocker) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(blocker.title)
        .font(.caption.weight(.bold).monospaced())
        .foregroundStyle(VKZPalette.danger)
      Text(blocker.message)
        .font(.footnote)
        .foregroundStyle(VKZPalette.text)
        .fixedSize(horizontal: false, vertical: true)
      if blocker.offersSettings {
        Button("OPEN SETTINGS") {
          #if os(iOS)
            if let url = URL(string: UIApplication.openSettingsURLString) {
              openURL(url)
            }
          #endif
        }
        .buttonStyle(VKZSecondaryButtonStyle())
        .accessibilityLabel("Open Settings to allow camera access")
      }
    }
    .padding(14)
    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
    .accessibilityElement(children: .contain)
  }

  private func clearFeedback() {
    shotNoticeTask?.cancel()
    shotNotice = nil
    hitTask?.cancel()
    damageTask?.cancel()
    muzzleTask?.cancel()
    hitMarker = false
    incomingFlash = false
    muzzleFlash = false
    fx.clearTransientEffects()
  }

  private func fireShot() {
    guard !menuPresented, combat.fireCooldownRemaining(at: Date()) == 0 else { return }
    guard combat.canFireMarkerless else {
      showShotNotice(blockedShotNotice)
      return
    }
    combat.fireMarkerless()
  }

  private var blockedShotNotice: String {
    if isLocalRespawning { return "RESPAWNING" }
    if combat.isReloading { return "RELOADING" }
    if duel.opponent?.lifeState != .alive { return "OPPONENT IS RESPAWNING" }
    if (duel.localPlayer?.ammo ?? 0) <= 0 { return "OUT OF AMMO" }
    if !combat.presenceReady || store.isMatchInputLocked { return "RECONNECTING" }
    return store.targetingSnapshot.bodyDetected
      ? "AIM AT THE BODY"
      : "NO TARGET — FIND YOUR OPPONENT"
  }

  private func showShotNotice(_ message: String) {
    guard shotNotice != message else { return }
    shotNoticeTask?.cancel()
    withAnimation(.easeOut(duration: 0.15)) {
      shotNotice = message
    }
    shotNoticeTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(1.6))
      guard !Task.isCancelled else { return }
      withAnimation(.easeOut(duration: 0.2)) {
        shotNotice = nil
      }
    }
  }

  @ViewBuilder
  private var shotNoticeView: some View {
    if let shotNotice {
      Text(shotNotice)
        .font(.caption.bold().monospaced())
        .foregroundStyle(VKZPalette.danger)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.black.opacity(0.8), in: Capsule())
        .transition(.opacity)
        .accessibilityAddTraits(.updatesFrequently)
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
    if let event = duel.events.first, event.id == toastEventID, toastVisible {
      Text(event.message)
        .font(.caption.monospaced())
        .foregroundStyle(VKZPalette.text)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.black.opacity(0.75), in: Capsule())
        .accessibilityAddTraits(.updatesFrequently)
        .transition(.opacity)
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
    if isLocalRespawning { return "RESPAWNING" }
    if combat.isReloading { return "RELOADING" }
    if duel.localPlayer?.ammo == 0 { return "RELOAD TO CONTINUE" }
    if !combat.presenceReady || store.isMatchInputLocked { return "RECONNECTING" }
    switch combat.markerlessShotState {
    case .idle: return combat.canFireMarkerless ? "READY" : store.targetingStatus
    case .pending: return "VERIFYING SHOT"
    case .confirmed(.kill, _, _): return "ELIMINATION"
    case .confirmed(.miss, _, _): return "MISS"
    case .confirmed(_, let zone, let damage):
      return "\(zone?.rawValue.uppercased() ?? "") +\(damage)"
    case .failed: return "TAP TO RETRY"
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

  private var opponentHealthFraction: CGFloat {
    CGFloat(min(1, max(0, Double(duel.opponent?.health ?? 0) / 100)))
  }

  private var isLocalRespawning: Bool {
    guard let player = duel.localPlayer else { return false }
    return player.health == 0 || player.lifeState == .dead || player.lifeState == .respawning
  }

  private var reticleColor: Color {
    switch combat.markerlessAimZone {
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

private struct DuelCooldownBar: View {
  @ObservedObject var combat: DuelSession

  var body: some View {
    TimelineView(
      .animation(
        minimumInterval: 1 / 60,
        paused: combat.fireCooldownRemaining(at: Date()) == 0
      )
    ) { context in
      let remaining = combat.fireCooldownRemaining(at: context.date)
      VStack(alignment: .trailing, spacing: 4) {
        if remaining > 0 {
          Text("RECHARGING")
            .font(.caption2.bold().monospaced())
            .foregroundStyle(VKZPalette.textMuted)
        }
        GeometryReader { proxy in
          Capsule()
            .fill(.white.opacity(0.15))
            .overlay(alignment: .leading) {
              Capsule()
                .fill(remaining == 0 ? VKZPalette.ready : VKZPalette.telemetry)
                .frame(
                  width: proxy.size.width * combat.fireCooldownProgress(at: context.date)
                )
            }
        }
        .frame(height: 4)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: 22)
  }
}
