import Combine
import Foundation

enum MapLabMode: Equatable { case capture, recognition(MapLabBundle) }
enum MapLabPhase: Equatable { case idle, starting, live, saving, stopping, paused, finished }
enum MapLabCompletion: Equatable { case saved(MapLabBundle), closed }

/// One offline camera owner. A completion is published only after every pending
/// start/capture has been fenced and the driver's awaited stop has completed.
@MainActor
final class MapLabSessionController: ObservableObject, Identifiable {
  let id = UUID()
  let driver: any MapLabDriving
  let mode: MapLabMode
  @Published var name = ""
  @Published private(set) var phase: MapLabPhase = .idle
  @Published private(set) var state: MapLabSessionState = .idle
  @Published private(set) var message: String?
  @Published private(set) var completion: MapLabCompletion?
  private let store: any MapLabStoring
  private var startTask: Task<Void, Never>?
  private var actionTask: Task<MapLabBundle?, Never>?
  private var teardownTask: Task<Void, Never>?
  private var teardownGeneration: Int?
  private var generation = 0
  private var sceneActive = true

  init(mode: MapLabMode, driver: any MapLabDriving, store: any MapLabStoring) {
    self.mode = mode; self.driver = driver; self.store = store
    driver.onStateChange = { [weak self] in self?.receive($0) }
  }

  deinit { startTask?.cancel(); actionTask?.cancel() }
  var isBusy: Bool { [.starting, .saving, .stopping].contains(phase) }
  var canSave: Bool {
    guard mode == .capture, sceneActive, phase == .live,
      case .scanning(_, true) = state else { return false }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed.count <= 60
  }

  func start() async {
    if let startTask { await startTask.value; return }
    guard phase == .idle, sceneActive, completion == nil else { return }
    generation += 1; let token = generation
    phase = .starting; state = .starting; message = nil
    let task = Task { [weak self] in
      guard let self else { return }
      do {
        switch self.mode {
        case .capture: try await self.driver.startCapture()
        case .recognition(let bundle):
          try await Task.detached(priority: .userInitiated) { try bundle.validate() }.value
          guard self.current(token) else { return }
          try await self.driver.startRecognition(bytes: bundle.bytes)
        }
        guard self.current(token) else { return }
        self.state = self.driver.state; self.phase = .live
      } catch {
        guard self.current(token) else { return }
        self.phase = .paused; self.message = self.explanation(for: error)
      }
    }
    startTask = task
    await task.value
    if generation == token {
      startTask = nil
      if phase == .paused { _ = await halt(then: .paused) }
    }
  }

  func restart() async {
    guard sceneActive, completion == nil, !isBusy else { return }
    guard await halt(then: .idle) else { return }
    await start()
  }

  func save() async {
    guard canSave else { return }
    generation += 1; let token = generation
    let savedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    phase = .saving; message = nil
    let task = Task<MapLabBundle?, Never> { [weak self] in
      guard let self else { return nil }
      do {
        let bytes = try await self.driver.capture()
        guard self.current(token) else { return nil }
        let saved = try await self.store.save(name: savedName, bytes: bytes)
        guard self.current(token) else { return nil }
        return saved
      } catch {
        guard self.current(token) else { return nil }
        self.phase = .live; self.message = self.explanation(for: error)
        return nil
      }
    }
    actionTask = task
    let saved = await task.value
    guard current(token) else { return }
    actionTask = nil
    guard let saved, await halt(then: .finished), sceneActive else { return }
    completion = .saved(saved)
  }

  func close() async {
    guard completion == nil, phase != .finished else { return }
    guard await halt(then: .finished) else { return }
    completion = .closed
  }

  func setSceneActive(_ active: Bool) async {
    sceneActive = active
    guard !active, completion == nil, phase != .finished else { return }
    if await halt(then: .paused) { message = "Scan paused. Retry when you are ready." }
  }

  func stop() async {
    guard phase != .finished else { return }
    _ = await halt(then: .finished)
  }

  private func current(_ token: Int) -> Bool {
    generation == token && sceneActive && !Task.isCancelled && completion == nil
  }

  private func receive(_ next: MapLabSessionState) {
    // Stop/start callbacks cannot erase paused guidance or revive a completed view.
    guard [.starting, .live, .saving].contains(phase) else { return }
    state = next
    let failure: MapLabFailure
    switch next {
    case .failed(let reason): failure = reason
    case .interrupted: failure = .interrupted
    default: return
    }
    generation += 1
    startTask?.cancel(); actionTask?.cancel()
    phase = .paused; message = explanation(for: failure)
  }

  private func explanation(for error: Error) -> String {
    let failure = error as? MapLabFailure ?? .storageUnavailable
    if failure == .timedOut, mode == .capture {
      return "The camera could not build a usable scan. Retry near well-lit, textured surfaces."
    }
    return failure.errorDescription ?? "Scanning stopped. Please retry."
  }

  private func halt(then next: MapLabPhase) async -> Bool {
    generation += 1; let token = generation
    phase = .stopping
    // Revocation is immediate even while a camera permission prompt or secure
    // archive completion ignores cancellation. No stale recognition stays green.
    state = .idle
    startTask?.cancel(); actionTask?.cancel()
    let pending: Task<Void, Never>, pendingGeneration: Int
    if let teardownTask, let teardownGeneration {
      pending = teardownTask; pendingGeneration = teardownGeneration
    } else {
      let pendingStart = startTask, pendingAction = actionTask, driver = driver
      let task = Task {
        await pendingStart?.value
        await driver.stop()
        _ = await pendingAction?.value
      }
      teardownTask = task; teardownGeneration = token
      pending = task; pendingGeneration = token
    }
    await pending.value
    if teardownGeneration == pendingGeneration {
      teardownTask = nil; teardownGeneration = nil
    }
    guard generation == token else { return false }
    startTask = nil; actionTask = nil; phase = next
    return true
  }
}
