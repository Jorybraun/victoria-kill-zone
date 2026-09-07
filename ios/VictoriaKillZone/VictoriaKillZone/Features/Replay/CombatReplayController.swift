#if DEBUG && os(iOS) && canImport(SceneKit)
import Combine
import Foundation
import QuartzCore

@MainActor
final class CombatReplayController: ObservableObject {
  enum Playback { case ready, playing, completed, interrupted, cleared, failed }
  let stage = CombatReplayScene()
  @Published private(set) var session: CombatReplaySession?
  @Published private(set) var selected: CombatReplayFixture.ScenarioID = .hit
  @Published private(set) var playback: Playback = .ready
  @Published private(set) var deliveringPackets = true
  @Published private(set) var errorMessage: String?
  private var fixture: CombatReplayFixture?
  private var ticker: Task<Void, Never>?
  private var beganAt: TimeInterval = 0

  func start(_ selected: CombatReplayFixture.ScenarioID? = nil) {
    ticker?.cancel()
    stage.reset()
    do {
      if fixture == nil { fixture = try CombatReplayFixture.bundled() }
      if let selected { self.selected = selected }
      guard let scenario = fixture?.scenarios.first(where: { $0.id == self.selected }) else {
        throw CombatReplayFixture.Failure.invalidTimeline
      }
      session = try CombatReplaySession(scenario: scenario)
      deliveringPackets = true
      errorMessage = nil
      playback = .playing
      beganAt = CACurrentMediaTime()
      if let session { stage.update(session) }
      ticker = Task { [weak self] in
        while !Task.isCancelled {
          guard self?.step(at: CACurrentMediaTime()) == true else { return }
          do { try await Task.sleep(for: .milliseconds(50)) }
          catch { return }
        }
      }
    } catch {
      fail()
    }
  }

  func togglePackets() {
    guard playback == .playing else { return }
    deliveringPackets.toggle()
  }

  func replayLastPacket() {
    guard var session else { return }
    do {
      try session.replayLastPacket()
      self.session = session
    } catch { fail() }
  }

  func clear() {
    ticker?.cancel()
    ticker = nil
    session?.clear()
    stage.clear()
    playback = .cleared
  }

  func interrupt() {
    guard playback == .playing else { return }
    clear()
    playback = .interrupted
  }

  private func step(at now: TimeInterval) -> Bool {
    guard playback == .playing, var session else { return false }
    let time = session.scenario.initial.matchTimeMs + max(0, now - beganAt) * 1000
    let limit = session.scenario.endsAtMs + RealtimeCombatPresentation.staleMs + 1
    do {
      try session.advance(to: min(time, limit), deliverPackets: deliveringPackets)
      self.session = session
      stage.update(session)
      if session.isComplete {
        playback = .completed
        return false
      }
      if time >= limit {
        stage.clear()
        playback = .interrupted
        return false
      }
      return true
    } catch { fail(); return false }
  }

  private func fail() {
    ticker?.cancel()
    ticker = nil
    session?.clear()
    stage.clear()
    errorMessage = "The replay could not be validated. Reopen this screen or try another build."
    playback = .failed
  }
}
#endif
