import SwiftUI

/// Offline setup presentation; completion is emitted only after shared-camera teardown.
struct ArenaSetupView: View {
  @StateObject private var controller: ArenaSetupController
  @Environment(\.scenePhase) private var scenePhase
  private let onFinish: (SavedArenaBundle?) -> Void

  init(targeting: any TargetingSession, store: any SavedArenaStoring,
    onFinish: @escaping (SavedArenaBundle?) -> Void) {
    _controller = StateObject(wrappedValue: ArenaSetupController(targeting: targeting, store: store))
    self.onFinish = onFinish
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("Set up an arena").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text("Saved on this phone").font(.subheadline).foregroundStyle(VKZPalette.textMuted)
          }
          Spacer()
          Button("Cancel") {Task {await controller.cancel()}}
            .frame(minWidth: 44, minHeight: 44)
            .disabled(controller.phase == .stopping || controller.phase == .finished)
        }
        camera
          .aspectRatio(4.0 / 3.0, contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: 20))
          .accessibilityLabel("Live arena camera")
        VStack(alignment: .leading, spacing: 12) {
          Text(stepLabel).font(.caption.bold()).foregroundStyle(VKZPalette.pending)
          HStack {
            Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
            if controller.isBusy {ProgressView().tint(VKZPalette.pending)}
          }
          Text(guidance).font(.subheadline).foregroundStyle(VKZPalette.textMuted)
            .fixedSize(horizontal: false, vertical: true)
          if let message = controller.message, message != guidance {
            Text(message).font(.subheadline.bold()).foregroundStyle(VKZPalette.pending)
              .fixedSize(horizontal: false, vertical: true)
          }
          if controller.frame.stage == .mapReady {
            RealtimeReferencePanel(state: controller.referenceState, imageData: controller.referenceImageData,
              onCapture: {Task {await controller.captureReference()}})
              .disabled(!controller.canCapture)
          }
          if case .captured = controller.referenceState {
            Text("ARENA NAME").font(.caption.bold().monospaced()).foregroundStyle(VKZPalette.textMuted)
            TextField("Living room, garden…", text: $controller.name)
              .padding(14).background(VKZPalette.panel, in: RoundedRectangle(cornerRadius: 12))
              .accessibilityLabel("Arena name").disabled(controller.isBusy)
            Text("Up to 60 characters").font(.caption).foregroundStyle(VKZPalette.textMuted)
            Button(controller.phase == .saving ? "SAVING ARENA…" : "SAVE ARENA") {
              Task {await controller.save()}
            }
            .buttonStyle(VKZPrimaryButtonStyle()).disabled(!controller.canSave)
          }
          if controller.phase != .idle && controller.phase != .finished {
            Button("RESTART SCAN") {Task {await controller.restart()}}
              .buttonStyle(VKZSecondaryButtonStyle()).disabled(controller.isBusy || scenePhase != .active)
          }
        }
      }
      .padding(20).frame(maxWidth: 560).frame(maxWidth: .infinity)
    }
    .background(VKZPalette.background).foregroundStyle(VKZPalette.text)
    .scrollDismissesKeyboard(.interactively)
    .interactiveDismissDisabled()
    .task {
      await controller.setSceneActive(scenePhase != .background)
      await controller.start()
    }
    .onChange(of: scenePhase) {_, phase in Task {await controller.setSceneActive(phase != .background)}}
    .onChange(of: controller.completion) {_, completion in
      switch completion {
      case .saved(let bundle): onFinish(bundle)
      case .cancelled: onFinish(nil)
      case nil: break
      }
    }
    .onDisappear {Task {await controller.stop()}}
  }

  @ViewBuilder private var camera: some View {
    #if os(iOS) && canImport(ARKit)
    if let live = controller.targeting as? ARVisionTargetingSession {
      ARCameraPreview(targeting: live, fxEngine: nil)
    } else {Color.black.overlay(Image(systemName: "camera").font(.largeTitle))}
    #else
    Color.black.overlay(Image(systemName: "camera").font(.largeTitle))
    #endif
  }

  private var title: String {
    if controller.frame.stage == .lost {return controller.scanPresentation.title}
    switch controller.phase {
    case .idle, .starting: return "Opening camera"
    case .capturing: return "Measuring your reference"
    case .saving: return "Saving your arena"
    case .stopping: return "Closing camera"
    case .paused: return "Scan paused"
    case .finished: return "Arena setup complete"
    case .scanning:
      if controller.frame.stage == .mapReady {
        if case .captured = controller.referenceState {return "Name your arena"}
        return "Choose a fixed reference"
      }
      return controller.scanPresentation.title
    }
  }

  private var guidance: String {
    if controller.frame.stage == .lost {return controller.scanPresentation.guidance}
    if controller.phase == .paused {return "Restart the scan before saving. Your existing arenas are still saved."}
    if case .captured = controller.referenceState {
      return "Give this space a name. You can choose it for future games; each player will align with it before playing."
    }
    if controller.frame.stage == .mapReady {return "Choose something that will stay in the same place for future games."}
    return controller.scanPresentation.guidance
  }

  private var stepLabel: String {
    if controller.frame.stage == .lost || controller.phase == .paused {return "Scan paused"}
    if case .captured = controller.referenceState {return "3 · Save arena"}
    if controller.frame.stage == .mapReady {return "2 · Choose reference"}
    return "1 · Scan surroundings"
  }
}
