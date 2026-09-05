import AppKit
import SwiftUI
@testable import VictoriaKillZone

@main
@MainActor
struct GameplayPreview {
  static func main() throws {
    guard CommandLine.arguments.count == 2 else {return}
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let store = LobbyStore(environment: .phaseZeroShell)
    store.displayName = "Alex"
    let players = [
      LobbyPlayer(id: "host", displayName: "Alex", role: .host, isReady: true),
      LobbyPlayer(id: "guest-1", displayName: "Riley", role: .guest, isReady: true),
      LobbyPlayer(id: "guest-2", displayName: "Morgan", role: .guest, isReady: false),
      LobbyPlayer(id: "guest-3", displayName: "Alexandria North", role: .guest, isReady: false, isConnected: false),
    ]
    func room(_ count: Int) -> WaitingRoom {
      WaitingRoom(matchID: "synthetic-room", code: "ABC123", arenaRadiusMeters: 0,
        localPlayerID: "host", hostPlayerID: "host", players: Array(players.prefix(count)),
        combatMode: .durableObject, maxPlayers: 4)
    }
    for (suffix, size) in [("standard", DynamicTypeSize.large), ("accessibility", .accessibility3)] {
      try render(HomeView(store: store), name: "home-\(suffix)", size: size, output: output)
      try render(WaitingRoomView(room: room(1), store: store), name: "lobby-one-player-\(suffix)", size: size, output: output)
      try render(WaitingRoomView(room: room(4), store: store), name: "lobby-four-players-\(suffix)", size: size, output: output)
      try render(HomeView(store: store), name: "home-\(suffix)-bottom", size: size, output: output, scrollToBottom: true)
      try render(WaitingRoomView(room: room(4), store: store), name: "lobby-four-players-\(suffix)-bottom", size: size, output: output, scrollToBottom: true)
    }
  }

  static func render<Content: View>(_ content: Content, name: String, size: DynamicTypeSize, output: URL,
    scrollToBottom: Bool = false) throws {
    let view = content.environment(\.dynamicTypeSize, size).environment(\.locale, Locale(identifier: "en_US"))
      .preferredColorScheme(.dark).foregroundStyle(VKZPalette.text)
      .frame(width: 375, height: 667).background(VKZPalette.background)
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(x: 0, y: 0, width: 375, height: 667)
    let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    window.display()
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    hosting.layoutSubtreeIfNeeded()
    if scrollToBottom {
      guard let scroll = firstScrollView(hosting), let document = scroll.documentView else {throw Failure("No scroll view for \(name)")}
      let end = max(0, document.bounds.height - scroll.contentView.bounds.height + scroll.contentInsets.top + scroll.contentInsets.bottom)
      scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? end : 0))
      scroll.reflectScrolledClipView(scroll.contentView)
      print("Scroll \(name): document=\(document.bounds.height), viewport=\(scroll.contentView.bounds.height), bottomInset=\(scroll.contentInsets.bottom), offset=\(scroll.contentView.bounds.origin.y)")
      window.display()
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
    else {throw Failure("No image rendered for \(name)")}
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {throw Failure("Unable to encode \(name)")}
    try png.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
    window.contentView = nil
    print("Rendered \(name)")
  }

  static func firstScrollView(_ view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView {return scroll}
    for child in view.subviews {if let found = firstScrollView(child) {return found}}
    return nil
  }

  struct Failure: Error {let reason: String; init(_ reason: String) {self.reason = reason}}
}
