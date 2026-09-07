#if DEBUG && os(iOS) && canImport(SceneKit)
import SceneKit
import SwiftUI

/// DEBUG-only presentation proof; no ARSession, socket, body detector or match.
@MainActor
struct CombatReplayView: View {
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @StateObject private var controller = CombatReplayController()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VKZStatusPill(label: "SYNTHETIC · OFFLINE", color: VKZPalette.pending)
        Text("Watch accepted projectiles")
          .font(.title2.bold())
        Text("Recorded engine events run through the game's replica and renderer. Phone markers are illustrative. This does not test camera tracking or multiplayer.")
          .font(.subheadline)
          .foregroundStyle(VKZPalette.textMuted)

        if dynamicTypeSize.isAccessibilitySize {
          scenarioPicker.pickerStyle(.menu).frame(minHeight: 44)
        } else {
          scenarioPicker.pickerStyle(.segmented)
        }

        SceneView(scene: controller.stage.scene, pointOfView: controller.stage.camera, options: [])
          .frame(minHeight: 260, maxHeight: 320)
          .aspectRatio(1.15, contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: 16))
          .accessibilityLabel("Synthetic projectile replay. \(status)")

        VStack(alignment: .leading, spacing: 8) {
          Text(status).font(.headline)
          ProgressView(value: controller.session?.progress ?? 0)
            .tint(VKZPalette.telemetry)
            .accessibilityLabel("Replay progress")
          if let session = controller.session {
            HStack(alignment: .top) {
              ForEach(session.snapshot.players) { player in
                VStack(alignment: .leading, spacing: 4) {
                  Text(player.role == "host" ? "HOST A" : "GUEST B")
                    .font(.caption.bold())
                    .foregroundStyle(VKZPalette.textMuted)
                  Text("HP \(player.health) · Ammo \(player.ammo)")
                    .font(.subheadline.monospacedDigit())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }
        }

        HStack {
          Button("Replay", systemImage: "arrow.clockwise") { controller.start() }
            .buttonStyle(VKZPrimaryButtonStyle())
          Button("Clear", systemImage: "xmark") { controller.clear() }
            .buttonStyle(VKZSecondaryButtonStyle())
        }
        HStack {
          Button { controller.togglePackets() } label: {
            Text(controller.deliveringPackets ? "Stop packets" : "Resume packets")
              .frame(maxWidth: .infinity, minHeight: 44)
          }
          .disabled(controller.playback != .playing)
          Button { controller.replayLastPacket() } label: {
            Text("Repeat packet").frame(maxWidth: .infinity, minHeight: 44)
          }
          .disabled(controller.session == nil || controller.session?.isCleared == true)
        }
        .font(.subheadline.weight(.semibold))
        .frame(minHeight: 44)
        .tint(VKZPalette.telemetry)

        Text("Stop packets to watch stale effects disappear. Repeat packet replays an event batch; accepted shots and damage should stay unchanged.")
          .font(.caption)
          .foregroundStyle(VKZPalette.textMuted)

        if let session = controller.session {
          VKZPanel {
            VStack(alignment: .leading, spacing: 8) {
              Text("Accepted events").font(.headline)
              Text("\(session.acceptedSpawns) shot · \(session.terminals.count) terminal · \(session.acceptedSegments) segments")
                .font(.subheadline.monospacedDigit())
              if session.duplicateEventsIgnored > 0 {
                Text("\(session.duplicateEventsIgnored) duplicate events ignored")
                  .foregroundStyle(VKZPalette.ready)
              }
              ForEach(Array(session.recentEvents.enumerated()), id: \.offset) { _, event in
                Text(event).font(.caption)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .padding(20)
    }
    .background(VKZPalette.background)
    .foregroundStyle(VKZPalette.text)
    .navigationTitle("Combat replay")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { if controller.playback == .ready { controller.start() } }
    .onDisappear { controller.clear() }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active { controller.interrupt() }
    }
  }

  private var scenarioPicker: some View {
    Picker("Replay scenario", selection: Binding(get: { controller.selected }, set: { controller.start($0) })) {
      ForEach(CombatReplayFixture.ScenarioID.allCases) { scenario in
        Text(scenario.title).tag(scenario)
      }
    }
  }

  private var status: String {
    if let error = controller.errorMessage { return error }
    switch controller.playback {
    case .ready: return "Ready to replay"
    case .playing:
      return controller.deliveringPackets ? "Replaying engine events" : "Packets stopped · effects expire after 250 ms"
    case .completed:
      return controller.session?.terminals.last.map(CombatReplaySession.terminalTitle) ?? "Replay complete"
    case .interrupted: return "Replay interrupted · tap Replay to restart"
    case .cleared: return "Effects cleared · tap Replay to restart"
    case .failed: return "Replay unavailable"
    }
  }
}
#endif
