import Combine
import Foundation

enum ArenaSetupPhase: Equatable {case idle, starting, scanning, capturing, saving, stopping, paused, finished}
enum ArenaSetupCompletion: Equatable {case saved(SavedArenaBundle), cancelled}

/// Owns one offline arena capture. Storage owns persistence; no game or network dependency.
/// Every exit awaits the shared camera's teardown before publishing completion.
@MainActor
final class ArenaSetupController: ObservableObject {
  let targeting: any TargetingSession
  let frameProvider: DuelFrameProvider?
  @Published var name = ""
  @Published private(set) var phase: ArenaSetupPhase = .idle
  @Published private(set) var frame = DuelFrameSnapshot()
  @Published private(set) var referenceState: DuelFrameReferenceState = .unavailable
  @Published private(set) var referenceImageData: Data?
  @Published private(set) var message: String?
  @Published private(set) var completion: ArenaSetupCompletion?
  private let store: any SavedArenaStoring
  private var subscriptions: Set<AnyCancellable> = []
  private var startTask: Task<Void, Never>?
  private var actionTask: Task<SavedArenaBundle?, Never>?
  private var teardownTask: Task<Void, Never>?
  private var teardownGeneration: Int?
  private var generation = 0
  private var sceneActive = true

  init(targeting: any TargetingSession, store: any SavedArenaStoring) {
    self.targeting = targeting; self.store = store
    frameProvider = (targeting as? any DuelFrameSessionDriving).map {DuelFrameProvider(targeting: $0)}
    frameProvider?.$snapshot.sink { [weak self] in self?.receive($0) }.store(in: &subscriptions)
    frameProvider?.$referenceState.sink { [weak self] value in
      guard let self else {return}
      self.referenceState = value
      self.referenceImageData = self.frameProvider?.referenceImageData
    }.store(in: &subscriptions)
  }

  deinit {startTask?.cancel(); actionTask?.cancel()}
  var scanPresentation: ArenaScanPresentation {ArenaScanPresentation(frame: frame)}
  var isBusy: Bool {[.starting, .capturing, .saving, .stopping].contains(phase)}
  var canCapture: Bool {sceneActive && phase == .scanning && frame.stage == .mapReady}
  var canSave: Bool {
    guard canCapture, case .captured = referenceState else {return false}
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed.count <= 60
  }

  func start() async {
    if let startTask {await startTask.value; return}
    guard phase == .idle, sceneActive, completion == nil else {return}
    guard let frameProvider, targeting.availability == .available else {
      phase = .paused; message = "Arena scanning is unavailable on this device."; return
    }
    generation += 1; let token = generation
    phase = .starting; message = nil
    let task = Task { [weak self] in
      guard let self else {return}
      do {
        try await self.targeting.start()
        guard self.current(token) else {return}
        try await frameProvider.beginCalibration(epoch: 1, captureRequired: true)
        guard self.current(token) else {return}
        self.phase = .scanning
      } catch {
        guard self.current(token) else {return}
        self.phase = .paused
        self.message = "The camera couldn't start. Allow camera access in Settings, then restart the scan."
      }
    }
    startTask = task
    await task.value
    if generation == token {
      startTask = nil
      if phase == .paused {_ = await halt(then: .paused)}
    }
  }

  func restart() async {
    guard sceneActive, completion == nil, !isBusy else {return}
    guard await halt(then: .idle) else {return}
    await start()
  }

  func captureReference() async {
    guard canCapture, let frameProvider else {return}
    generation += 1; let token = generation
    phase = .capturing; message = nil
    let task = Task<SavedArenaBundle?, Never> { [weak self] in
      guard let self else {return nil}
      do {try await frameProvider.captureReference()}
      catch {
        guard self.current(token) else {return nil}
        self.message = "The reference couldn't be measured. Keep a fixed, textured rectangle in view and try again."
      }
      if self.current(token) {self.phase = .scanning}
      return nil
    }
    actionTask = task
    _ = await task.value
    if generation == token {actionTask = nil}
  }

  func save() async {
    guard canSave, let frameProvider else {return}
    generation += 1; let token = generation
    let savedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    phase = .saving; message = nil
    let task = Task<SavedArenaBundle?, Never> { [weak self] in
      guard let self else {return nil}
      do {
        let map = try await frameProvider.captureMap()
        guard self.current(token) else {return nil}
        let saved = try await self.store.save(name: savedName, bytes: map.bytes)
        guard self.current(token) else {return nil}
        return saved
      } catch {
        guard self.current(token) else {return nil}
        self.phase = .scanning
        if let failure = error as? SavedArenaFailure {
          self.message = [failure.errorDescription, failure.recoverySuggestion].compactMap {$0}.joined(separator: " ")
        } else {
          self.message = "The arena couldn't be saved. Keep the reference in view and try again."
        }
        return nil
      }
    }
    actionTask = task
    let saved = await task.value
    guard current(token) else {return}
    actionTask = nil
    guard let saved, await halt(then: .finished), sceneActive else {return}
    completion = .saved(saved)
  }

  func cancel() async {
    guard completion == nil, phase != .finished else {return}
    guard await halt(then: .finished) else {return}
    completion = .cancelled
  }

  func setSceneActive(_ active: Bool) async {
    sceneActive = active
    guard !active, completion == nil, phase != .finished else {return}
    if await halt(then: .paused) {message = "Scan paused. Restart when you're ready."}
  }

  /// Fallback for removal by the parent; ordinary save/cancel completes this first.
  func stop() async {
    guard phase != .finished else {return}
    _ = await halt(then: .finished)
  }

  private func current(_ token: Int) -> Bool {
    generation == token && sceneActive && !Task.isCancelled && completion == nil
  }

  private func receive(_ snapshot: DuelFrameSnapshot) {
    frame = snapshot
    guard snapshot.stage == .lost, [.starting, .scanning, .capturing, .saving].contains(phase) else {return}
    // Revoke a pending action too: its late result must not replace this failure
    // with scanning/saving success. Restart/cancel still await owned teardown.
    generation += 1
    startTask?.cancel(); actionTask?.cancel()
    phase = .paused
    message = ArenaScanPresentation(frame: snapshot).guidance
  }

  private func halt(then next: ArenaSetupPhase) async -> Bool {
    generation += 1; let token = generation
    phase = .stopping
    startTask?.cancel(); actionTask?.cancel()
    let pendingTeardown: Task<Void, Never>, pendingGeneration: Int
    if let teardownTask, let teardownGeneration {
      pendingTeardown = teardownTask
      pendingGeneration = teardownGeneration
    } else {
      let pendingStart = startTask, pendingAction = actionTask
      let targeting = targeting, provider = frameProvider
      let teardown = Task {
        // Camera permission may ignore cancellation. Finish it before the final stop.
        await pendingStart?.value
        await provider?.stop()
        await targeting.stop()
        _ = await pendingAction?.value
      }
      teardownTask = teardown
      teardownGeneration = token
      pendingTeardown = teardown
      pendingGeneration = token
    }
    await pendingTeardown.value
    // Any waiter can finish first. An older waiter must never clear a later stop.
    if teardownGeneration == pendingGeneration {
      teardownTask = nil; teardownGeneration = nil
    }
    guard generation == token else {return false}
    startTask = nil; actionTask = nil
    phase = next
    return true
  }
}
