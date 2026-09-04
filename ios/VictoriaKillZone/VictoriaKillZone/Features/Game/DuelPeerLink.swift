import Foundation

protocol DuelPeerLink: AnyObject {
  var onMessage: ((ArenaLinkMessage, Int64) -> Void)? { get set }
  func start(role: ArenaRole)
  func stop()
  func send(_ message: ArenaLinkMessage)
}

extension CombatTransportArenaLink: DuelPeerLink {}
extension FallbackArenaPeerLink: DuelPeerLink {}

#if canImport(Network)
  extension ArenaPeerLink: DuelPeerLink {}
#endif
