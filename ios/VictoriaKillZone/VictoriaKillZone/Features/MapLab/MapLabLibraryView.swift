import SwiftUI

struct MapLabLibraryView: View {
  let onDone: () -> Void
  @StateObject private var library: MapLabLibrary
  @State private var pendingDelete: MapLabSummary?
  @State private var hasLoaded = false
  @State private var closing = false

  init(store: any MapLabStoring, onDone: @escaping () -> Void) {
    self.onDone = onDone
    _library = StateObject(wrappedValue: MapLabLibrary(store: store))
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Text("Scan your surroundings").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
          Text("Save a scan, then test whether this phone recognizes the same place. Everything stays on this phone and works offline.")
            .foregroundStyle(VKZPalette.textMuted)
          Button { library.newScan() } label: { Label("NEW SCAN", systemImage: "viewfinder") }
            .buttonStyle(VKZPrimaryButtonStyle()).disabled(library.isBusy || closing)
          if let savedName = library.savedScanName {
            VStack(alignment: .leading, spacing: 8) {
              Label("Saved \(savedName) on this phone.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(VKZPalette.ready)
              Text("Choose TEST SCAN below to check whether this phone recognizes the room.")
                .font(.subheadline).foregroundStyle(VKZPalette.textMuted)
            }
            .accessibilityElement(children: .combine)
          }
          if library.isBusy { ProgressView("Opening scans…").frame(maxWidth: .infinity, minHeight: 44) }
          if let message = library.message {
            VStack(alignment: .leading, spacing: 8) {
              Text(message).foregroundStyle(VKZPalette.pending)
              Button("TRY AGAIN") { Task { await library.refresh() } }.frame(minHeight: 44)
                .disabled(library.isBusy || closing)
            }
          }
          if library.scans.isEmpty, !library.isBusy {
            Label("Your saved scans will appear here.", systemImage: "map")
              .foregroundStyle(VKZPalette.textMuted).padding(.vertical, 16)
          }
          ForEach(library.scans) { scan in scanRow(scan) }
          Text("A recognition test is separate from multiplayer alignment. These scans do not create or join a game.")
            .font(.footnote).foregroundStyle(VKZPalette.textMuted)
        }
        .padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity)
      }
      .background(VKZPalette.background.ignoresSafeArea()).foregroundStyle(VKZPalette.text)
      .navigationTitle("Scan & Save")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") {
            closing = true
            Task { await library.close(); onDone() }
          }.frame(minHeight: 44).disabled(closing)
        }
      }
      .confirmationDialog("Delete this scan?", isPresented: Binding(
        get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
      ), titleVisibility: .visible) {
        if let scan = pendingDelete {
          Button("Delete \(scan.name)", role: .destructive) {
            pendingDelete = nil
            Task { await library.delete(scan.id) }
          }
        }
        Button("Cancel", role: .cancel) { pendingDelete = nil }
      } message: { Text("This removes the scan from this phone.") }
    }
    // Both library and camera use an awaited Done/Cancel path. A swipe must not
    // bypass it while a load, permission prompt or camera teardown is suspended.
    .interactiveDismissDisabled()
    .task {
      guard !hasLoaded else { return }
      hasLoaded = true
      await library.refresh()
    }
    .onDisappear {
      // Presenting the camera can make its underlying library disappear too.
      if library.activeSession == nil { Task { await library.close() } }
    }
    #if os(iOS)
    .fullScreenCover(isPresented: cameraPresented) { camera }
    #else
    .sheet(isPresented: cameraPresented) { camera }
    #endif
  }

  private var cameraPresented: Binding<Bool> {
    Binding(get: { library.activeSession != nil }, set: { _ in })
  }

  @ViewBuilder private var camera: some View {
    if let session = library.activeSession {
      MapLabSessionView(controller: session) { Task { await library.sessionFinished(session.id) } }
        .interactiveDismissDisabled()
    }
  }

  private func scanRow(_ scan: MapLabSummary) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "map").font(.title2).foregroundStyle(VKZPalette.pending)
        VStack(alignment: .leading, spacing: 4) {
          Text(scan.name).font(.headline)
          if scan.isValid {
            Text(scan.createdAt, style: .date).font(.caption).foregroundStyle(VKZPalette.textMuted)
          } else {
            Text("Delete this unreadable scan and scan again.").font(.caption).foregroundStyle(VKZPalette.pending)
          }
        }
        Spacer(minLength: 0)
        Button { pendingDelete = scan } label: {
          Image(systemName: "trash").frame(minWidth: 44, minHeight: 44)
        }.accessibilityLabel("Delete \(scan.name)")
      }
      if scan.isValid {
        Button("TEST SCAN") { Task { await library.testScan(scan.id) } }
          .buttonStyle(VKZSecondaryButtonStyle())
          .accessibilityHint("Look for \(scan.name) using this phone's camera.")
      }
    }
    .padding(16).background(VKZPalette.panel, in: RoundedRectangle(cornerRadius: 16))
    .disabled(library.isBusy || closing)
  }
}

private struct MapLabSessionView: View {
  @ObservedObject var controller: MapLabSessionController
  let onFinished: () -> Void
  @Environment(\.scenePhase) private var scenePhase
  @State private var sentCompletion = false

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      #if os(iOS) && canImport(ARKit)
      if let driver = controller.driver as? MapLabARDriver {
        MapLabCameraPreview(driver: driver).ignoresSafeArea()
      }
      #endif
    }
    .safeAreaInset(edge: .top) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 6) {
          Text(title).font(.headline)
          Text(instruction).font(.subheadline).foregroundStyle(VKZPalette.textMuted)
        }
        Spacer(minLength: 0)
        Button(controller.mode == .capture ? "Cancel" : "Done") { Task { await controller.close() } }
          .frame(minWidth: 44, minHeight: 44).disabled(controller.phase == .stopping)
      }
      .padding(16).background(VKZPalette.background.opacity(0.9))
    }
    .safeAreaInset(edge: .bottom) {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if let message = controller.message { Text(message).foregroundStyle(VKZPalette.pending) }
          if controller.isBusy { ProgressView(controller.phase == .saving ? "Saving scan…" : "Preparing camera…") }
          if controller.phase == .paused {
            Button("RETRY") { Task { await controller.restart() } }.buttonStyle(VKZPrimaryButtonStyle())
          } else if controller.mode == .capture {
            TextField("Scan name", text: $controller.name)
              .textFieldStyle(.plain).padding(12)
              .background(VKZPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
              .accessibilityLabel("Scan name, up to 60 characters")
              .disabled(controller.isBusy)
            Button("SAVE SCAN") { Task { await controller.save() } }
              .buttonStyle(VKZPrimaryButtonStyle()).disabled(!controller.canSave)
              .opacity(controller.canSave ? 1 : 0.5)
          } else {
            Text("Recognition on this phone only. Multiplayer alignment is tested separately.")
              .font(.footnote).foregroundStyle(VKZPalette.textMuted)
          }
        }.padding(16)
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxHeight: 280)
      .background(VKZPalette.background.opacity(0.9))
    }
    .foregroundStyle(VKZPalette.text)
    .task {
      await controller.setScenePhase(scenePhase)
      await controller.start()
    }
    .onChange(of: scenePhase) { _, next in Task { await controller.setScenePhase(next) } }
    .onChange(of: controller.completion) { _, completion in
      guard completion != nil, !sentCompletion else { return }
      sentCompletion = true; onFinished()
    }
    .onDisappear { Task { await controller.stop() } }
  }

  private var title: String {
    if controller.phase == .paused { return "Scan paused" }
    if controller.state == .recognized { return "Scan recognized on this phone" }
    if case .recognition = controller.mode { return "Looking for this scan" }
    return "Scan your surroundings"
  }

  private var instruction: String {
    if controller.phase == .paused { return "Retry starts a fresh camera session." }
    if controller.state == .recognized { return "This phone found the saved place." }
    if case .recognition = controller.mode { return "Return to the original place and move slowly across familiar details." }
    guard case .scanning(let feedback, _) = controller.state else { return "Preparing the camera." }
    switch feedback {
    case .starting: return "Point the camera at nearby, well-lit surfaces."
    case .moveSlowly: return "Move more slowly to keep details in view."
    case .findDetail: return "Look for textured surfaces and corners."
    case .mapping: return "Slowly look around nearby details."
    case .ready: return "Ready to save. Give this place a name."
    }
  }
}
