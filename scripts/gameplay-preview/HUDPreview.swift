import AppKit
import SwiftUI
@testable import VictoriaKillZone

/// Actual classic-duel view, with isolated synthetic data and no camera/network.
@main
@MainActor
struct HUDPreview {
  static func main() throws {
    guard CommandLine.arguments.count == 2 else { return }
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    for (width, height) in [(375.0, 667.0), (393.0, 852.0)] {
      for (label, size) in [("standard", DynamicTypeSize.large), ("large-text", .xxxLarge)] {
        let store = LobbyStore(environment: AppEnvironment(
          gameSessionClient: UnavailableGameSessionClient(), targetingSession: PreviewTargeting()
        ))
        let duel = ActiveDuel(matchID: "preview-duel", code: "DEMO01", localPlayerID: "local",
          players: [LobbyPlayer(id: "local", displayName: "Alex", role: .host, isReady: true, kills: 3, deaths: 3),
                    LobbyPlayer(id: "other", displayName: "Riley", role: .guest, isReady: true, health: 60, kills: 3, deaths: 3)],
          endsAt: 42_000, serverNow: 0, syncedAt: Date())
        let content = ActiveDuelView(duel: duel, combat: store.duel, store: store)
          .environment(\.scenePhase, .active)
          .environment(\.dynamicTypeSize, size).environment(\.locale, Locale(identifier: "en_US"))
          .preferredColorScheme(.dark).foregroundStyle(VKZPalette.text)
          .frame(width: width, height: height)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.display()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
        else { throw Failure.render }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure.render }
        let name = "classic-\(Int(width))-\(label).png"
        try png.write(to: output.appendingPathComponent(name), options: .atomic)
        window.contentView = nil
        print("Rendered \(name)")
      }
    }
  }
  enum Failure: Error { case render }
}

private struct PreviewTargeting: TargetingSession {
  let availability = TargetingAvailability.available
  var currentSnapshot: TargetingSnapshot {
    TargetingSnapshot(bodyDetected: false, confidence: 0, observedAt: Date())
  }
  func snapshots() -> AsyncStream<TargetingSnapshot> {
    AsyncStream { $0.yield(currentSnapshot); $0.finish() }
  }
  func start() async throws {}
  func stop() async {}
}
