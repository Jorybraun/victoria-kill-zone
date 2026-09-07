#if DEBUG
import SwiftUI

#if os(iOS) && canImport(ARKit)
import ARKit
import SceneKit

/// DEBUG research entry. A temporary shared origin is not a Quick Play guarantee.
struct SharedArenaHarnessView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @State private var role: ArenaRole = .host
  @State private var hostCredentials = SharedOriginCredentials.create()
  @State private var guestCode = ""
  @State private var session: SharedArenaSession?
  @State private var stopping = false
  @State private var error: String?

  var body: some View {
    Group {
      if let session {
        SharedOriginRunView(session: session, stopping: stopping, onStop: {stopRun()})
          .task {await session.start()}
      } else {setup}
    }
    .foregroundStyle(VKZPalette.text).background(VKZPalette.background)
    .interactiveDismissDisabled().navigationBarBackButtonHidden()
    .onChange(of: scenePhase) {_, phase in
      if phase == .background, let session {Task {await session.stop()}}
    }
    .onDisappear {if let session {Task {await session.stop()}}}
  }

  private var setup: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack {
          Text("Shared origin experiment").font(.title2.bold()).accessibilityAddTraits(.isHeader)
          Spacer()
          Button("Done") {dismiss()}.frame(minWidth: 44, minHeight: 44)
        }
        Text("Two phones · measurements only").font(.subheadline.bold()).foregroundStyle(VKZPalette.pending)
        Text("This experiment checks a temporary common coordinate frame. It does not start a game or prove hit accuracy.")
          .font(.subheadline).foregroundStyle(VKZPalette.textMuted)
        Picker("Phone role", selection: $role) {
          Text("Create experiment").tag(ArenaRole.host)
          Text("Join experiment").tag(ArenaRole.guest)
        }.pickerStyle(.segmented)
        if role == .host {
          Text("Share this random code with the other phone before starting.").font(.subheadline)
          Text(hostCredentials.joinSecret).font(.body.monospaced()).textSelection(.enabled)
            .privacySensitive().padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(VKZPalette.panel, in: RoundedRectangle(cornerRadius: 12))
          Button("Copy experiment code") {UIPasteboard.general.string = hostCredentials.joinSecret}
            .frame(minHeight: 44)
        } else {
          TextField("Experiment code from the other phone", text: $guestCode, axis: .vertical)
            .font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
            .privacySensitive().padding(14).background(VKZPalette.panel, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("Experiment code")
        }
        if let error {Text(error).foregroundStyle(VKZPalette.pending).font(.subheadline)}
        Button("START MEASUREMENT") {startRun()}.buttonStyle(VKZPrimaryButtonStyle())
        Text("Keep both phones on the same Wi-Fi or within peer-to-peer range. Stand near each other and slowly look at the same fixed scene. No LiDAR is required.")
          .font(.subheadline).foregroundStyle(VKZPalette.textMuted)
        Text("After stopping or interruption, create a new experiment code on the host. Scan & Save and gameplay are separate.")
          .font(.footnote).foregroundStyle(VKZPalette.textMuted)
      }.padding(20).frame(maxWidth: 560).frame(maxWidth: .infinity)
    }
  }

  private func startRun() {
    do {
      let credentials = role == .host ? hostCredentials : try SharedOriginCredentials(code: guestCode)
      session = SharedArenaSession(role: role, credentials: credentials)
      error = nil; guestCode = ""
    } catch {self.error = "Enter the complete experiment code from the host phone."}
  }

  private func stopRun() {
    guard !stopping, let session else {return}
    stopping = true
    Task {
      await session.stop()
      self.session = nil; stopping = false
      hostCredentials = .create(); guestCode = ""
    }
  }
}

private struct SharedOriginRunView: View {
  @ObservedObject var session: SharedArenaSession
  let stopping: Bool
  let onStop: () -> Void
  @State private var showMeasurements = false
  @State private var exportURL: URL?
  @State private var exportFailed = false

  var body: some View {
    ZStack(alignment: .top) {
      SharedOriginSceneView(session: session).ignoresSafeArea()
      VStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 8) {
          Text("MEASUREMENT EXPERIMENT").font(.caption.bold().monospaced()).foregroundStyle(VKZPalette.pending)
          Text(session.snapshot.instruction).font(.headline).fixedSize(horizontal: false, vertical: true)
          Text("No gameplay readiness or accuracy claim").font(.caption).foregroundStyle(VKZPalette.textMuted)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(VKZPalette.panel.opacity(0.94), in: RoundedRectangle(cornerRadius: 16))
        Spacer(minLength: 8)
        if showMeasurements {measurements}
        HStack(spacing: 12) {
          Button(showMeasurements ? "Hide measurements" : "Measurements") {showMeasurements.toggle()}
            .buttonStyle(VKZSecondaryButtonStyle())
          Button(stopping ? "STOPPING…" : "STOP", action: onStop)
            .buttonStyle(VKZPrimaryButtonStyle()).disabled(stopping)
        }
      }.padding(16)
    }
    .alert("Export unavailable", isPresented: $exportFailed) {
      Button("OK") {}
    } message: {Text("The measurement log could not be saved. Try again.")}
  }

  private var measurements: some View {
    let state = session.snapshot
    return ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        Text("Shared-coordinate estimates").font(.headline)
        Text("The small outline marks the other phone, not a body or hit target.").font(.caption)
        row("Phone distance", state.interPhoneDistanceMeters.map {String(format: "%.2f m", $0)} ?? "Waiting")
        row("Peer receipt age", state.peerReceiptAgeMs.map {String(format: "%.0f ms", $0)} ?? "Unavailable")
        row("Peer source age", state.peerSourceAgeMs.map {String(format: "%.0f ms", $0)} ?? "Unavailable")
        row("Elapsed", "\(state.elapsedMs / 1_000) s")
        Text("Receipt age excludes network transit. Source age is the peer's report. Neither proves end-to-end freshness. Compare results against independent physical measurements; shared anchors are not that proof.")
          .font(.caption).foregroundStyle(VKZPalette.textMuted)
        if let exportURL {
          ShareLink("Share measurement CSV", item: exportURL).frame(minHeight: 44)
        }
        Button("Export current measurements") {
          do {exportURL = try session.exportLog()} catch {exportFailed = true}
        }.frame(minHeight: 44)
      }.padding(14)
    }
    .frame(maxHeight: 300)
    .background(VKZPalette.panel.opacity(0.94), in: RoundedRectangle(cornerRadius: 16))
  }

  private func row(_ label: String, _ value: String) -> some View {
    HStack {Text(label); Spacer(); Text(value).monospacedDigit()}.font(.subheadline)
      .accessibilityElement(children: .combine)
  }
}

private struct SharedOriginSceneView: UIViewRepresentable {
  let session: SharedArenaSession
  func makeCoordinator() -> Coordinator {Coordinator(session: session)}
  func makeUIView(context: Context) -> ARSCNView {
    let view = ARSCNView(frame: .zero)
    view.session = session.arSession; view.scene = SCNScene(); view.delegate = context.coordinator
    view.backgroundColor = .black; view.scene.rootNode.addChildNode(context.coordinator.phone)
    session.reassertSessionDelegate()
    return view
  }
  func updateUIView(_ view: ARSCNView, context: Context) {session.reassertSessionDelegate()}
  static func dismantleUIView(_ view: ARSCNView, coordinator: Coordinator) {view.session = ARSession()}

  final class Coordinator: NSObject, ARSCNViewDelegate {
    let session: SharedArenaSession
    let phone = SCNNode()
    init(session: SharedArenaSession) {
      self.session = session
      super.init()
      let outline = SCNBox(width: 0.07, height: 0.14, length: 0.01, chamferRadius: 0.008)
      outline.firstMaterial?.diffuse.contents = UIColor.systemTeal
      outline.firstMaterial?.emission.contents = UIColor.systemTeal
      outline.firstMaterial?.fillMode = .lines
      phone.geometry = outline; phone.isHidden = true
    }
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
      guard let transform = session.peerMarkerTransform else {phone.isHidden = true; return}
      let values = transform.columnMajor.map(Float.init)
      phone.simdTransform = simd_float4x4(columns: (
        SIMD4(values[0], values[1], values[2], values[3]), SIMD4(values[4], values[5], values[6], values[7]),
        SIMD4(values[8], values[9], values[10], values[11]), SIMD4(values[12], values[13], values[14], values[15])))
      phone.isHidden = false
    }
  }
}
#else
struct SharedArenaHarnessView: View {
  var body: some View {Text("The shared-origin measurement experiment requires two physical iPhones with ARKit.")}
}
#endif
#endif
