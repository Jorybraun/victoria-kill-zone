import Combine
import Foundation

enum RealtimeMapState: Equatable {case idle, mapping, waitingForHost, transferring, installed, failed(String)}

@MainActor
final class RealtimeMapCoordinator: ObservableObject {
  @Published private(set) var state: RealtimeMapState = .idle
  private let session: PlayerSession
  private let client: any GameSessionClient
  private let combat: RealtimeCombatSession
  private let frame: DuelFrameProvider
  private let maps: any CombatMapTransferring
  private let savedArena: SavedArenaBundle?
  private var task: Task<Void, Never>?
  private var installedMap: DuelFrameMap?
  private var generation = 0
  private var lastTicketRequest = Date.distantPast
  private var cachedTicket: CombatAccessTicket?

  init(session: PlayerSession, client: any GameSessionClient, combat: RealtimeCombatSession, frame: DuelFrameProvider,
       savedArena: SavedArenaBundle? = nil, maps: any CombatMapTransferring = CombatMapClient()) {
    self.session = session; self.client = client; self.combat = combat; self.frame = frame
    self.savedArena = savedArena; self.maps = maps
  }

  func configure(epoch: UInt16, isHost: Bool) {
    generation += 1; let previous = task; previous?.cancel(); let token = generation
    task = Task { [weak self] in
      guard let self else {return}
      defer {if self.generation == token {self.task = nil}}
      do {
        await previous?.value
        guard self.current(token) else {return}
        await self.frame.stop()
        guard self.current(token) else {return}
        try await self.frame.beginCalibration(epoch: epoch, captureRequired: isHost && self.savedArena == nil)
        guard self.current(token) else {return}
        if let map = self.installedMap, map.epoch == epoch {
          try await self.frame.installMap(map)
          guard self.current(token) else {return}
          self.state = .installed; return
        }
        while self.current(token) {
          self.state = .transferring
          let ticket = try await self.accessTicket(epoch: epoch)
          do {
            let map = try await self.maps.download(epoch: epoch, ticket: ticket)
            guard self.current(token) else {return}
            if isHost, let savedArena = self.savedArena, map.frameID != savedArena.summary.frameID {
              throw CombatMapError.conflict
            }
            try await self.frame.installMap(map)
            guard self.current(token) else {return}
            self.installedMap = map; self.state = .installed; return
          } catch CombatMapError.unavailable {
            if isHost, let savedArena = self.savedArena {
              // Hashing/decoding up to 8 MiB must not stall the camera or clock.
              let map = try await Task.detached(priority: .userInitiated) {
                try savedArena.map(epoch: epoch)
              }.value
              guard self.current(token) else {return}
              try await self.maps.upload(map, ticket: ticket)
              guard self.current(token) else {return}
              try await self.frame.installMap(map)
              guard self.current(token) else {return}
              self.installedMap = map; self.state = .installed; return
            }
            if isHost {self.state = .mapping; return}
            self.state = .waitingForHost
            try await Task.sleep(for: .seconds(2))
          }
        }
      } catch {
        guard self.current(token) else {return}
        if error as? CombatMapError == .conflict {
          self.state = .failed("This match already uses a different arena. Leave and create a new match to change it.")
        } else {
          self.state = .failed("The arena scan could not be loaded. Check your connection and retry. If the saved scan is unreadable, scan a new arena.")
        }
      }
    }
  }

  func captureAndShare() {
    guard savedArena == nil, task == nil, frame.snapshot.stage == .mapReady, let epoch = frame.snapshot.epoch else {return}
    generation += 1; let token = generation
    state = .transferring
    task = Task { [weak self] in
      guard let self else {return}
      defer {if self.generation == token {self.task = nil}}
      do {
        let map = try await self.frame.captureMap()
        guard self.current(token) else {return}
        let ticket = try await self.accessTicket(epoch: epoch)
        try await self.maps.upload(map, ticket: ticket)
        guard self.current(token) else {return}
        try await self.frame.installMap(map)
        guard self.current(token) else {return}
        self.installedMap = map; self.state = .installed
      } catch {
        guard self.current(token) else {return}
        self.state = .failed("The scan could not be shared. Keep the same play area in view and retry.")
      }
    }
  }

  func stop() async {
    generation += 1; let previous = task; previous?.cancel(); task = nil; state = .idle
    await previous?.value
    await frame.stop()
  }

  private func current(_ token: Int) -> Bool {generation == token && !Task.isCancelled}
  private func accessTicket(epoch: UInt16) async throws -> CombatAccessTicket {
    if let ticket = combat.latestAccessTicket, ticket.frameEpoch == Int(epoch), ticket.expiresAt.timeIntervalSinceNow > 5 {return ticket}
    if let ticket = cachedTicket, ticket.frameEpoch == Int(epoch), ticket.expiresAt.timeIntervalSinceNow > 5 {return ticket}
    let wait = 1.1 - Date().timeIntervalSince(lastTicketRequest)
    if wait > 0 {try await Task.sleep(for: .seconds(wait))}
    lastTicketRequest = Date()
    let ticket = try await client.combatTicket(session: session)
    guard ticket.frameEpoch == Int(epoch) else {throw CombatMapError.invalidResponse}
    cachedTicket = ticket
    return ticket
  }
}
