#if DEBUG
import SwiftUI

// MARK: - KIL-20 two-phone shared-arena harness
//
// Debug-only screen that runs the calibration ritual from the shared-arena
// research and records the measurement log. It renders the three arena anchors
// and the peer's phone proxy (0.35 m sphere) so an operator with a tape measure
// can read alignment error at 3 / 8 / 15 m. Spatial firing is not wired here.

#if os(iOS) && canImport(ARKit)
  import ARKit
  import SceneKit

  struct SharedArenaHarnessView: View {
    @State private var role: ArenaRole = .host
    @State private var method: ArenaFrameMethod = .collaborative
    @State private var session: SharedArenaSession?

    var body: some View {
      if let session {
        SharedArenaRunView(session: session) {
          session.stop()
          self.session = nil
        }
      } else {
        setup
      }
    }

    private var setup: some View {
      VStack(alignment: .leading, spacing: 20) {
        Text("SHARED ARENA HARNESS")
          .font(.system(size: 28, weight: .black, design: .rounded))
        Text("KIL-20 · two phones · spatial fire disabled")
          .font(.caption.monospaced())
          .foregroundStyle(VKZPalette.textMuted)

        VKZPanel {
          VStack(alignment: .leading, spacing: 14) {
            Picker("Role", selection: $role) {
              Text("HOST").tag(ArenaRole.host)
              Text("GUEST").tag(ArenaRole.guest)
            }
            .pickerStyle(.segmented)
            Picker("Method", selection: $method) {
              Text("COLLABORATIVE").tag(ArenaFrameMethod.collaborative)
              Text("WORLD MAP").tag(ArenaFrameMethod.worldMap)
            }
            .pickerStyle(.segmented)
            Text(
              method == .collaborative
                ? "Primary: continuous ARKit co-mapping. Residual measured against the participant anchor."
                : "Control: one-shot ARWorldMap handoff. Host shares once mapped; guest relocalizes."
            )
            .font(.footnote)
            .foregroundStyle(VKZPalette.textMuted)
          }
        }

        Button("START \(role.rawValue.uppercased())") {
          let session = SharedArenaSession(role: role, method: method)
          session.start()
          self.session = session
        }
        .buttonStyle(VKZPrimaryButtonStyle())

        Text("Start the host first. Both phones must run the same method and be on the same Wi-Fi or within peer-to-peer range.")
          .font(.footnote)
          .foregroundStyle(VKZPalette.textMuted)
        Spacer()
      }
      .padding(24)
      .frame(maxWidth: 560)
      .frame(maxWidth: .infinity)
    }
  }

  private struct SharedArenaRunView: View {
    @ObservedObject var session: SharedArenaSession
    let onStop: () -> Void
    @State private var exportURL: URL?
    @State private var exportError: String?

    var body: some View {
      ZStack(alignment: .top) {
        SharedArenaSceneView(session: session)
          .ignoresSafeArea()

        VStack(alignment: .leading, spacing: 10) {
          Text(session.snapshot.ritualStep)
            .font(.callout.weight(.bold).monospaced())
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VKZPalette.panel.opacity(0.88))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

          pills
          telemetry
          Spacer()
          if let event = session.snapshot.tracers.lastEvent {
            Text(event)
              .font(.title3.weight(.black).monospaced())
              .foregroundStyle(eventColor(event))
              .frame(maxWidth: .infinity)
              .padding(.bottom, 4)
              .id(session.snapshot.tracers.lastEventAtMs)
              .transition(.opacity)
          }
          fireButton
          controls
        }
        .padding(16)
      }
      .foregroundStyle(VKZPalette.text)
      .onChange(of: session.snapshot.tracers.lastEventAtMs) { _, _ in
        guard let event = session.snapshot.tracers.lastEvent else { return }
        let generator = UIImpactFeedbackGenerator(style: event == "SHOT PREDICTED" ? .heavy : .light)
        generator.impactOccurred()
      }
      .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
        Button("OK") { exportError = nil }
      } message: {
        Text(exportError ?? "")
      }
    }

    private var pills: some View {
      let s = session.snapshot
      return ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          VKZStatusPill(label: "\(s.role.rawValue.uppercased()) · \(s.method.rawValue.uppercased())", color: VKZPalette.textMuted)
          VKZStatusPill(label: "LINK \(s.linkState.label.uppercased())", color: s.linkState == .connected ? VKZPalette.ready : VKZPalette.pending)
          VKZStatusPill(label: "TRACK \(s.localTracking.label.uppercased())", color: s.localTracking == .normal ? VKZPalette.ready : VKZPalette.danger)
          VKZStatusPill(label: "MAP \(s.mappingStatus.rawValue.uppercased())", color: s.mappingStatus == .mapped ? VKZPalette.ready : VKZPalette.pending)
          VKZStatusPill(label: s.mergeObserved ? "MERGED" : "NO MERGE", color: s.mergeObserved ? VKZPalette.ready : VKZPalette.pending)
          VKZStatusPill(label: s.lockState.label.uppercased(), color: lockColor(s.lockState))
        }
      }
    }

    private var telemetry: some View {
      let s = session.snapshot
      let m = s.metrics
      return VStack(alignment: .leading, spacing: 4) {
        line("anchors", "local \(s.localAnchorNames.count)/3 · shared \(s.sharedAnchorNames.count)/3")
        line("peer", s.peer.map { "\($0.playerId) seq \($0.sequence) age \($0.ageMs) ms \($0.tracking == .normal ? "" : "LOST")" } ?? "—")
        line("distance", s.interPhoneDistanceMeters.map { String(format: "%.2f m", $0) } ?? "—")
        line("residual", s.residual.map { String(format: "%.3f m · %.2f°", $0.translationMeters, $0.yawDegrees) } ?? "n/a (no participant anchor)")
        line("interval", "p50 \(fmt(m.updateIntervalP50Ms)) · p95 \(fmt(m.updateIntervalP95Ms)) · p99 \(fmt(m.updateIntervalP99Ms)) ms")
        line("packets", "ok \(m.samplesAccepted) · lost \(m.samplesLost) · ooo \(m.samplesOutOfOrder)")
        line("relock", "losses \(m.lockLosses) · max \(fmt(m.recoveryMsMax)) · mean \(fmt(m.recoveryMsMean)) ms")
        line("bytes", "in \(s.linkStats.bytesIn) · out \(s.linkStats.bytesOut)" + (s.worldMapBytesSent.map { " · map sent \($0)" } ?? "") + (s.worldMapBytesReceived.map { " · map recv \($0)" } ?? ""))
        line("tracers", "out \(s.tracers.predictedDrawn) · in \(s.tracers.incomingDrawn) · dup \(s.tracers.duplicatesIgnored) · dropped(unlocked) \(s.tracers.droppedWhileUnlocked)")
        line("thermal", "\(s.thermalState) · t+\(s.elapsedMs / 1000)s")
      }
      .font(.caption2.monospaced())
      .padding(10)
      .background(VKZPalette.panel.opacity(0.82))
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var fireButton: some View {
      let canFire = session.snapshot.localTracking == .normal
      return Button {
        session.fire()
      } label: {
        Text(canFire ? "FIRE" : "TRACKING LOST — FIRE LOCKED")
          .font(.title2.weight(.black).monospaced())
          .frame(maxWidth: .infinity)
          .frame(height: 64)
      }
      .buttonStyle(VKZPrimaryButtonStyle())
      .tint(canFire ? VKZPalette.danger : VKZPalette.textMuted)
      .accessibilityHint(canFire ? "Fires a hitscan tracer visible on both phones" : "Tracking lost. Fire locked.")
    }

    private func eventColor(_ event: String) -> Color {
      switch event {
      case "SHOT PREDICTED": VKZPalette.pending
      case "INCOMING SHOT": VKZPalette.danger
      default: VKZPalette.textMuted
      }
    }

    private var controls: some View {
      HStack(spacing: 10) {
        if session.role == .host, session.method == .worldMap {
          Button("SHARE MAP") { session.shareWorldMap() }
            .buttonStyle(VKZSecondaryButtonStyle())
        }
        if let exportURL {
          ShareLink(item: exportURL) {
            Text("SHARE CSV").frame(maxWidth: .infinity)
          }
          .buttonStyle(VKZSecondaryButtonStyle())
        } else {
          Button("EXPORT CSV") {
            do { exportURL = try session.exportLog() } catch { exportError = error.localizedDescription }
          }
          .buttonStyle(VKZSecondaryButtonStyle())
        }
        Button("STOP", action: onStop)
          .buttonStyle(VKZPrimaryButtonStyle())
      }
    }

    private func line(_ key: String, _ value: String) -> some View {
      HStack(alignment: .top, spacing: 8) {
        Text(key).foregroundStyle(VKZPalette.textMuted).frame(width: 64, alignment: .leading)
        Text(value)
      }
    }

    private func fmt(_ value: Int64?) -> String {
      value.map(String.init) ?? "—"
    }

    private func lockColor(_ state: ArenaLockState) -> Color {
      switch state {
      case .lockReady: VKZPalette.ready
      case .aligning: VKZPalette.pending
      case .trackingLost: VKZPalette.danger
      }
    }
  }

  /// Renders named arena anchors (boxes) and the peer proxy sphere. Anchor nodes
  /// come from ARKit through `ARSCNViewDelegate`; the proxy is updated per frame
  /// from the session's lock-guarded peer transform and hidden unless locked.
  private struct SharedArenaSceneView: UIViewRepresentable {
    let session: SharedArenaSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIView(context: Context) -> ARSCNView {
      let view = ARSCNView(frame: .zero)
      view.session = session.arSession
      view.scene = SCNScene()
      view.automaticallyUpdatesLighting = true
      view.backgroundColor = .black
      view.delegate = context.coordinator
      view.scene.rootNode.addChildNode(context.coordinator.proxyNode)
      session.reassertSessionDelegate()
      return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {
      if view.session !== session.arSession { view.session = session.arSession }
      session.reassertSessionDelegate()
    }

    static func dismantleUIView(_ view: ARSCNView, coordinator: Coordinator) {
      view.session = ARSession()
    }

    final class Coordinator: NSObject, ARSCNViewDelegate {
      let session: SharedArenaSession
      let proxyNode: SCNNode
      private var drawnShotIds: Set<String> = []
      private var drawnOrder: [String] = []

      init(session: SharedArenaSession) {
        self.session = session
        let sphere = SCNSphere(radius: CGFloat(ArenaHitEvaluator.proxyRadiusMeters))
        sphere.firstMaterial?.diffuse.contents = UIColor.systemTeal.withAlphaComponent(0.35)
        sphere.firstMaterial?.isDoubleSided = true
        proxyNode = SCNNode(geometry: sphere)
        proxyNode.isHidden = true
        super.init()
      }

      func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        if anchor is ARParticipantAnchor {
          let marker = SCNNode(geometry: SCNSphere(radius: 0.06))
          marker.geometry?.firstMaterial?.diffuse.contents = UIColor.systemOrange
          return marker
        }
        guard let name = anchor.name, let index = SharedArenaSession.anchorNames.firstIndex(of: name) else {
          return nil
        }
        let box = SCNBox(width: 0.15, height: 0.15, length: 0.15, chamferRadius: 0.01)
        let colors: [UIColor] = [.systemRed, .systemGreen, .systemBlue]
        box.firstMaterial?.diffuse.contents = colors[index % colors.count]
        let node = SCNNode(geometry: box)
        let label = SCNText(string: name, extrusionDepth: 0.2)
        label.font = UIFont.monospacedSystemFont(ofSize: 4, weight: .bold)
        label.firstMaterial?.diffuse.contents = UIColor.white
        let labelNode = SCNNode(geometry: label)
        labelNode.scale = SCNVector3(0.01, 0.01, 0.01)
        labelNode.position = SCNVector3(-0.15, 0.12, 0)
        node.addChildNode(labelNode)
        return node
      }

      func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        if let transform = session.peerProxyTransform {
          let t = transform.translation
          proxyNode.position = SCNVector3(Float(t.x), Float(t.y), Float(t.z))
          proxyNode.isHidden = false
        } else {
          proxyNode.isHidden = true
        }
        guard let root = proxyNode.parent else { return }
        for segment in session.activeTracers where !drawnShotIds.contains(segment.shotId) {
          rememberDrawn(segment.shotId)
          drawTracer(segment, in: root)
        }
      }

      /// The ledger already dedups by identity; this set only stops the same
      /// live segment from spawning a node on every frame it stays in `active`.
      private func rememberDrawn(_ shotId: String) {
        drawnShotIds.insert(shotId)
        drawnOrder.append(shotId)
        if drawnOrder.count > 256 {
          drawnShotIds.remove(drawnOrder.removeFirst())
        }
      }

      /// Same beam-and-bullet look as `LaserFXEngine`, but in arena coordinates
      /// from the shot's shared origin and direction — so both phones draw the
      /// same line through the same space. Amber = own predicted, red = incoming.
      private func drawTracer(_ segment: ArenaTracerSegment, in root: SCNNode) {
        let origin = SIMD3<Float>(Float(segment.origin.x), Float(segment.origin.y), Float(segment.origin.z))
        let end = SIMD3<Float>(Float(segment.end.x), Float(segment.end.y), Float(segment.end.z))
        let delta = end - origin
        let length = simd_length(delta)
        guard length > 0.01 else { return }
        let direction = delta / length
        let color: UIColor = segment.kind == .predicted
          ? UIColor(red: 1, green: 0.7, blue: 0.25, alpha: 1)
          : UIColor(red: 1, green: 0.32, blue: 0.39, alpha: 1)

        let beam = SCNCylinder(radius: 0.008, height: CGFloat(length))
        let beamMaterial = SCNMaterial()
        beamMaterial.diffuse.contents = color
        beamMaterial.emission.contents = color
        beamMaterial.lightingModel = .constant
        beam.firstMaterial = beamMaterial
        let beamNode = SCNNode(geometry: beam)
        let mid = (origin + end) / 2
        beamNode.position = SCNVector3(mid.x, mid.y, mid.z)
        beamNode.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: direction)
        root.addChildNode(beamNode)
        beamNode.runAction(.sequence([
          .fadeOut(duration: Double(ArenaTracerSegment.durationMs) / 1_000),
          .removeFromParentNode(),
        ]))

        let bullet = SCNSphere(radius: 0.015)
        let bulletMaterial = SCNMaterial()
        bulletMaterial.diffuse.contents = UIColor.white
        bulletMaterial.emission.contents = color
        bulletMaterial.lightingModel = .constant
        bullet.firstMaterial = bulletMaterial
        let bulletNode = SCNNode(geometry: bullet)
        bulletNode.position = SCNVector3(origin.x, origin.y, origin.z)
        root.addChildNode(bulletNode)
        bulletNode.runAction(.sequence([
          .move(to: SCNVector3(end.x, end.y, end.z), duration: 0.4),
          .removeFromParentNode(),
        ]))
      }
    }
  }
#else
  struct SharedArenaHarnessView: View {
    var body: some View {
      Text("Shared arena harness requires an iOS device with ARKit.")
    }
  }
#endif
#endif
