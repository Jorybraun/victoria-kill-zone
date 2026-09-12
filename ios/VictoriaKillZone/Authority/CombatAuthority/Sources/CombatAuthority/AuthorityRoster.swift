import Foundation
import PewPewSimulation

public enum AuthorityError: Error, Equatable, Sendable {
  case invalidPlayerCount
  case unknownSlot(UInt8)
  case unknownPlayer(SimulationPlayerID)
  case malformedPayload(String)
  case payloadTooLarge(Int)
}

public struct AuthorityRoster: Equatable, Sendable {
  public let members: [UInt8: SimulationPlayerID]

  public init(playerIDs: [SimulationPlayerID]) throws {
    guard (2...4).contains(playerIDs.count) else {
      throw AuthorityError.invalidPlayerCount
    }
    self.members = Dictionary(
      uniqueKeysWithValues: playerIDs.enumerated().map { (UInt8($0.offset), $0.element) }
    )
  }

  public var playerCount: Int {
    members.count
  }

  public func playerID(for slot: UInt8) -> SimulationPlayerID? {
    members[slot]
  }

  public func slot(for id: SimulationPlayerID) -> UInt8? {
    members.first(where: { $0.value == id })?.key
  }

  public var orderedPlayerIDs: [SimulationPlayerID] {
    (0..<UInt8(playerCount)).compactMap { members[$0] }
  }
}
