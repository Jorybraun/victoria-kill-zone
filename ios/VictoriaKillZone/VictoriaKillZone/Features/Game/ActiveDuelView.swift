import SwiftUI

#if os(iOS)
import AVFoundation
import UIKit
#endif

struct VoiceFireEligibility: Equatable, Sendable {
  let duelIsRunning: Bool
  let storeCanDebugFire: Bool
  let networkIsFresh: Bool
  let poseIsFresh: Bool
  let hasStableHitZone: Bool

  var isEligible: Bool {
    duelIsRunning && storeCanDebugFire && networkIsFresh && poseIsFresh && hasStableHitZone
  }
}

struct LaserPoint: Equatable, Sendable {
  let x: Double
  let y: Double
}

enum IncomingLaserEdge: Equatable, Sendable {
  case leading
  case trailing
  case top
}

struct LaserEffect: Equatable, Sendable {
  enum Direction: Equatable, Sendable {
    case outgoing(target: LaserPoint)
    case incoming(edge: IncomingLaserEdge)
  }

  let sequence: UInt64
  let direction: Direction
  let startedAt: Date
  let duration: TimeInterval

  func isVisible(at date: Date) -> Bool {
    date >= startedAt && date.timeIntervalSince(startedAt) < duration
  }
}

struct ActiveDuelEffectState: Equatable, Sendable {
  private(set) var outgoing: LaserEffect?
  private(set) var incoming: LaserEffect?
  private(set) var observedEventIDs: Set<String> = []
  private(set) var hasSeededEvents = false
  private var nextSequence: UInt64 = 0

  mutating func triggerOutgoing(
    target: LaserPoint,
    at date: Date,
    duration: TimeInterval = 0.2
  ) {
    precondition((0.15...0.25).contains(duration))
    nextSequence &+= 1
    outgoing = LaserEffect(
      sequence: nextSequence,
      direction: .outgoing(target: target),
      startedAt: date,
      duration: duration
    )
  }

  @discardableResult
  mutating func observe(
    events: [EventSnapshot],
    localPlayerID: String,
    at date: Date,
    duration: TimeInterval = 0.2
  ) -> Bool {
    let newEvents = events.filter { !observedEventIDs.contains($0.id) }
    observedEventIDs.formUnion(events.map(\.id))
    guard hasSeededEvents else {
      hasSeededEvents = true
      return false
    }
    guard let hit = newEvents.first(where: {
      $0.type == .hit && $0.actorPlayerId != nil
        && $0.actorPlayerId != localPlayerID && $0.targetPlayerId == localPlayerID
    }) else {
      return false
    }

    nextSequence &+= 1
    incoming = LaserEffect(
      sequence: nextSequence,
      direction: .incoming(edge: Self.edge(for: hit.id)),
      startedAt: date,
      duration: duration
    )
    return true
  }

  mutating func expire(at date: Date) {
    if outgoing?.isVisible(at: date) == false { outgoing = nil }
    if incoming?.isVisible(at: date) == false { incoming = nil }
  }

  private static func edge(for eventID: String) -> IncomingLaserEdge {
    switch eventID.unicodeScalars.reduce(0, { $0 + Int($1.value) }) % 3 {
    case 0: .leading
    case 1: .trailing
    default: .top
    }
  }
}

struct ActiveDuelView: View {
  let duel: ActiveDuel
  @ObservedObject var store: LobbyStore
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var voiceFire = VoiceFireController()
  @StateObject private var feedback = LaserFeedbackPlayer()
  @State private var targetingSnapshot = TargetingSnapshot.unavailable()
  @State private var targetingTask: Task<Void, Never>?
  @State private var effects = ActiveDuelEffectState()

  var body: some View {
    ZStack {
      cameraLayer
      Color.black.opacity(0.12).ignoresSafeArea()
      targetOutline
      laserLayer
      duelHUD
    }
    .onAppear {
      effects.observe(events: duel.events, localPlayerID: duel.localPlayerID, at: Date())
      voiceFire.setViewVisible(true)
      voiceFire.setSceneActive(scenePhase == .active)
      refreshVoiceEligibility()
      startTargeting()
    }
    .onDisappear {
      voiceFire.setViewVisible(false)
      targetingTask?.cancel()
      targetingTask = nil
      let session = store.environment.targetingSession
      Task { await session.stop() }
    }
    .vkzOnChange(of: scenePhase) { phase in
      voiceFire.setSceneActive(phase == .active)
    }
    .vkzOnChange(of: targetingSnapshot) { _ in
      refreshVoiceEligibility()
    }
    .vkzOnChange(of: store.lastSyncAt) { _ in
      refreshVoiceEligibility()
    }
    .vkzOnChange(of: store.canDebugFire) { _ in
      refreshVoiceEligibility()
    }
    .vkzOnChange(of: voiceFire.fireRequestSequence) { _ in
      performVoiceFire()
    }
    .vkzOnChange(of: duel.events) { events in
      if effects.observe(events: events, localPlayerID: duel.localPlayerID, at: Date()) {
        feedback.playIncomingImpact()
      }
    }
    .task(id: effects.outgoing?.sequence) {
      guard let effect = effects.outgoing else { return }
      try? await Task.sleep(for: .seconds(effect.duration))
      guard !Task.isCancelled else { return }
      effects.expire(at: effect.startedAt.addingTimeInterval(effect.duration))
    }
    .task(id: effects.incoming?.sequence) {
      guard let effect = effects.incoming else { return }
      try? await Task.sleep(for: .seconds(effect.duration))
      guard !Task.isCancelled else { return }
      effects.expire(at: effect.startedAt.addingTimeInterval(effect.duration))
    }
  }

  @ViewBuilder
  private var cameraLayer: some View {
    #if os(iOS) && canImport(ARKit) && canImport(AVFoundation) && canImport(Vision)
    if let session = store.environment.targetingSession as? ARVisionTargetingSession {
      ARCameraPreview(targetingSession: session)
        .ignoresSafeArea()
    } else {
      cameraFallback
    }
    #else
    cameraFallback
    #endif
  }

  private var cameraFallback: some View {
    LinearGradient(
      colors: [VKZPalette.background, VKZPalette.surfaceRaised],
      startPoint: .top,
      endPoint: .bottom
    )
    .ignoresSafeArea()
  }

  private var duelHUD: some View {
    TimelineView(.periodic(from: .now, by: 0.2)) { context in
      VStack(spacing: 12) {
        topTelemetry(at: context.date)
        connectionBanner
        Spacer()
        targetingStatus
        crosshair
        Spacer()
        if duel.phase == .running && duel.localRole == .host {
          voiceControl
          debugControl
        } else {
          debugControl
        }
        latestEvent
        Button("LEAVE DUEL", role: .destructive) { store.leave() }
          .buttonStyle(VKZSecondaryButtonStyle())
      }
      .padding(20)
      .frame(maxWidth: 600)
      .frame(maxWidth: .infinity)
    }
  }

  private func topTelemetry(at date: Date) -> some View {
    HStack(alignment: .top) {
      telemetryBlock(label: "HEALTH", value: String(duel.localPlayer?.health ?? 0), color: VKZPalette.ready)
      Spacer()
      VStack(spacing: 4) {
        Text(phaseTitle)
          .font(.caption.weight(.bold).monospaced())
          .foregroundStyle(VKZPalette.telemetry)
        if duel.phase == .countdown {
          Text(String(countdownValue(at: date)))
            .font(.system(size: 38, weight: .bold, design: .monospaced))
        }
      }
      Spacer()
      telemetryBlock(label: "AMMO", value: "\(duel.localPlayer?.ammo ?? 0) / 8", color: .white)
    }
    .padding(12)
    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
  }

  @ViewBuilder
  private var connectionBanner: some View {
    if store.isMatchInputLocked {
      Text("RECONNECTING — INPUT LOCKED")
        .font(.headline.monospaced())
        .foregroundStyle(VKZPalette.pending)
        .padding(8)
        .background(.black.opacity(0.7), in: Capsule())
    } else if store.syncStatus == .restored {
      VKZStatusPill(label: "STATE VERIFIED", color: VKZPalette.ready)
    }
  }

  private var targetingStatus: some View {
    Text(targetingSnapshot.state.displayText + (targetingSnapshot.hitZone.map { " • \($0.displayText)" } ?? ""))
      .font(.caption.weight(.bold).monospaced())
      .foregroundStyle(targetingSnapshot.hitZone == nil ? VKZPalette.pending : VKZPalette.ready)
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background(.black.opacity(0.65), in: Capsule())
  }

  private var crosshair: some View {
    ZStack {
      Circle().stroke(.white.opacity(0.9), lineWidth: 2).frame(width: 34, height: 34)
      Rectangle().fill(.white).frame(width: 2, height: 48)
      Rectangle().fill(.white).frame(width: 48, height: 2)
    }
    .shadow(color: .cyan, radius: 5)
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private var debugControl: some View {
    switch duel.phase {
    case .countdown:
      Text("DUEL STARTS IN").font(.headline.monospaced()).foregroundStyle(VKZPalette.pending)
    case .running where duel.localRole == .host:
      Button(debugButtonLabel) { store.debugFire() }
        .buttonStyle(VKZPrimaryButtonStyle())
        .disabled(!store.canDebugFire)
        .accessibilityLabel("Debug fire, torso test, 34 damage")
    case .running:
      Text("AWAITING TEST SHOT").font(.headline.monospaced()).foregroundStyle(VKZPalette.textMuted)
    case .finished:
      Text("DUEL COMPLETE").font(.title.bold())
    case .cancelled:
      Text("DUEL CANCELLED").font(.title.bold())
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
        Text("VOICE FIRE").font(.caption.weight(.bold).monospaced())
        Text(voiceFire.status.displayText)
          .font(.caption2.weight(.semibold).monospaced())
          .foregroundStyle(voiceStatusColor)
        if case .listening = voiceFire.status {
          Text("SAY “PEW PEW”").font(.caption.weight(.bold).monospaced())
        }
      }
    }
    .tint(VKZPalette.telemetry)
    .padding(12)
    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
    .disabled(!voiceFire.isEnabled && !voiceEligibility.isEligible)
    .accessibilityLabel("Voice Fire")
  }

  @ViewBuilder
  private var latestEvent: some View {
    if let event = duel.events.first {
      Text(event.message)
        .font(.callout.monospaced())
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding(6)
        .background(.black.opacity(0.55), in: Capsule())
    }
  }

  private var targetOutline: some View {
    GeometryReader { geometry in
      ZStack {
        if let bounds = targetingSnapshot.bodyBounds, targetingSnapshot.bodyDetected {
          RoundedRectangle(cornerRadius: 18)
            .stroke(.cyan, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
            .frame(width: bounds.width * geometry.size.width, height: bounds.height * geometry.size.height)
            .position(x: bounds.centerX * geometry.size.width, y: (1 - bounds.centerY) * geometry.size.height)
        }
        if let head = targetingSnapshot.headRegion, targetingSnapshot.bodyDetected {
          Ellipse()
            .stroke(.yellow, lineWidth: targetingSnapshot.hitZone == .head ? 5 : 2)
            .frame(width: head.radiusX * 2 * geometry.size.width, height: head.radiusY * 2 * geometry.size.height)
            .position(x: head.centerX * geometry.size.width, y: (1 - head.centerY) * geometry.size.height)
        }
        if let torso = targetingSnapshot.torsoRegion, targetingSnapshot.bodyDetected {
          Path { path in
            guard let first = torso.points.first else { return }
            path.move(to: CGPoint(x: first.x * geometry.size.width, y: (1 - first.y) * geometry.size.height))
            for point in torso.points.dropFirst() {
              path.addLine(to: CGPoint(x: point.x * geometry.size.width, y: (1 - point.y) * geometry.size.height))
            }
            path.closeSubpath()
          }
          .stroke(.orange, lineWidth: targetingSnapshot.hitZone == .torso ? 5 : 2)
        }
      }
      .shadow(color: .cyan, radius: 6)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private var laserLayer: some View {
    GeometryReader { geometry in
      ZStack {
        if let outgoing = effects.outgoing,
          case .outgoing(let target) = outgoing.direction
        {
          LaserStreak(
            start: CGPoint(x: geometry.size.width * 0.5, y: geometry.size.height * 0.78),
            end: CGPoint(x: geometry.size.width * target.x, y: geometry.size.height * (1 - target.y)),
            color: .cyan
          )
        }
        if let incoming = effects.incoming,
          case .incoming(let edge) = incoming.direction
        {
          LaserStreak(
            start: incomingStart(edge: edge, size: geometry.size),
            end: CGPoint(x: geometry.size.width * 0.5, y: geometry.size.height * 0.52),
            color: .red
          )
          Circle()
            .fill(.white)
            .frame(width: 180, height: 180)
            .blur(radius: 24)
            .position(x: geometry.size.width * 0.5, y: geometry.size.height * 0.52)
            .opacity(0.85)
        }
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private var voiceEligibility: VoiceFireEligibility {
    VoiceFireEligibility(
      duelIsRunning: duel.phase == .running,
      storeCanDebugFire: store.canDebugFire,
      networkIsFresh: store.isNetworkFresh(at: Date()),
      poseIsFresh: targetingSnapshot.isPoseFresh(at: Date()),
      hasStableHitZone: targetingSnapshot.hitZone != nil
    )
  }

  private func refreshVoiceEligibility() {
    voiceFire.setFireEligible(voiceEligibility.isEligible)
  }

  private func performVoiceFire() {
    guard voiceEligibility.isEligible, let target = outlinedTargetPoint else { return }
    effects.triggerOutgoing(target: target, at: Date())
    feedback.playOutgoing()
    store.debugFire()
    refreshVoiceEligibility()
  }

  private var outlinedTargetPoint: LaserPoint? {
    switch targetingSnapshot.hitZone {
    case .head:
      guard let head = targetingSnapshot.headRegion else { return nil }
      return LaserPoint(x: head.centerX, y: head.centerY)
    case .torso:
      guard let torso = targetingSnapshot.torsoRegion?.bounds else { return nil }
      return LaserPoint(x: torso.centerX, y: torso.centerY)
    case nil:
      return nil
    }
  }

  private func startTargeting() {
    targetingTask?.cancel()
    let session = store.environment.targetingSession
    targetingTask = Task {
      do {
        try await session.start()
        for await snapshot in session.snapshots() {
          guard !Task.isCancelled else { return }
          targetingSnapshot = snapshot
        }
      } catch {
        targetingSnapshot = session.currentSnapshot
      }
    }
  }

  private func incomingStart(edge: IncomingLaserEdge, size: CGSize) -> CGPoint {
    switch edge {
    case .leading: CGPoint(x: 0, y: size.height * 0.28)
    case .trailing: CGPoint(x: size.width, y: size.height * 0.32)
    case .top: CGPoint(x: size.width * 0.72, y: 0)
    }
  }

  private var debugButtonLabel: String {
    switch store.debugShotState {
    case .pending: "SHOT PENDING…"
    case .confirmed(let damage): "HIT CONFIRMED • \(damage)"
    case .idle, .failed: "DEBUG FIRE"
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
    let elapsedMilliseconds = max(0, date.timeIntervalSince(duel.syncedAt) * 1_000)
    return max(0, Int(ceil((startsAt - (duel.serverNow + elapsedMilliseconds)) / 1_000)))
  }

  private func telemetryBlock(label: String, value: String, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).font(.caption2.weight(.semibold).monospaced()).foregroundStyle(VKZPalette.textMuted)
      Text(value).font(.title3.bold().monospacedDigit()).foregroundStyle(color)
    }
  }
}

private struct LaserStreak: View {
  let start: CGPoint
  let end: CGPoint
  let color: Color

  var body: some View {
    Path { path in
      path.move(to: start)
      path.addLine(to: end)
    }
    .stroke(
      LinearGradient(colors: [.white, color, color.opacity(0.15)], startPoint: .leading, endPoint: .trailing),
      style: StrokeStyle(lineWidth: 9, lineCap: .round)
    )
    .shadow(color: color, radius: 14)
  }
}

@MainActor
private final class LaserFeedbackPlayer: ObservableObject {
  #if os(iOS)
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()

  init() {
    engine.attach(player)
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    engine.connect(player, to: engine.mainMixerNode, format: format)
  }
  #else
  init() {}
  #endif

  func playOutgoing() {
    #if os(iOS)
    playTone(startFrequency: 1_650, endFrequency: 280, duration: 0.18)
    UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 1)
    #endif
  }

  func playIncomingImpact() {
    #if os(iOS)
    playTone(startFrequency: 360, endFrequency: 90, duration: 0.2)
    UINotificationFeedbackGenerator().notificationOccurred(.error)
    #endif
  }

  #if os(iOS)
  private func playTone(startFrequency: Double, endFrequency: Double, duration: Double) {
    let sampleRate = 44_100.0
    let frameCount = AVAudioFrameCount(sampleRate * duration)
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
      let samples = buffer.floatChannelData?[0]
    else { return }
    buffer.frameLength = frameCount
    var phase = 0.0
    for frame in 0..<Int(frameCount) {
      let progress = Double(frame) / Double(frameCount)
      let frequency = startFrequency + (endFrequency - startFrequency) * progress
      phase += 2 * .pi * frequency / sampleRate
      let envelope = sin(.pi * progress)
      samples[frame] = Float(sin(phase) * envelope * 0.32)
    }
    do {
      if !engine.isRunning { try engine.start() }
      player.scheduleBuffer(buffer, at: nil, options: .interrupts)
      player.play()
    } catch { }
  }
  #endif
}

private extension View {
  @ViewBuilder
  func vkzOnChange<Value: Equatable>(
    of value: Value,
    action: @escaping (Value) -> Void
  ) -> some View {
    #if os(iOS)
    onChange(of: value) { _, newValue in action(newValue) }
    #else
    onChange(of: value, perform: action)
    #endif
  }
}
