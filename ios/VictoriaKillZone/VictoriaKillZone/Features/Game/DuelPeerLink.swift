import Foundation

protocol DuelPeerLink: AnyObject {
  var onMessage: ((ArenaLinkMessage, Int64) -> Void)? { get set }
  func start(role: ArenaRole)
  func stop()
  func send(_ message: ArenaLinkMessage)
}

#if canImport(Network)
  extension ArenaPeerLink: DuelPeerLink {}
#endif
