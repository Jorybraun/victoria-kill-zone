import Combine
import Foundation

@MainActor
final class MapLabLibrary: ObservableObject {
  @Published private(set) var scans: [MapLabSummary] = []
  @Published private(set) var isBusy = false
  @Published private(set) var message: String?
  @Published private(set) var savedScanName: String?
  @Published private(set) var activeSession: MapLabSessionController?
  private let store: any MapLabStoring
  private let makeDriver: @MainActor () -> any MapLabDriving
  private var generation = 0
  private var closed = false

  init(store: any MapLabStoring, makeDriver: @escaping @MainActor () -> any MapLabDriving = MapLabDriverFactory.make) {
    self.store = store; self.makeDriver = makeDriver
  }

  func refresh() async {
    guard !closed, activeSession == nil else { return }
    generation += 1; let token = generation
    isBusy = true; message = nil; savedScanName = nil
    do {
      let saved = try await store.list()
      guard current(token) else { return }
      scans = saved
    } catch {
      guard current(token) else { return }
      message = explanation(error)
    }
    if current(token) { isBusy = false }
  }

  func newScan() {
    guard !closed, !isBusy, activeSession == nil else { return }
    guard scans.count < MapLabBundle.maximumMaps else { message = MapLabFailure.libraryFull.errorDescription; return }
    savedScanName = nil
    activeSession = MapLabSessionController(mode: .capture, driver: makeDriver(), store: store)
  }

  func testScan(_ id: UUID) async {
    guard !closed, !isBusy, activeSession == nil else { return }
    generation += 1; let token = generation
    isBusy = true; message = nil; savedScanName = nil
    do {
      let bundle = try await store.load(id: id)
      try await Task.detached(priority: .userInitiated) { try bundle.validate() }.value
      guard current(token) else { return }
      activeSession = MapLabSessionController(mode: .recognition(bundle), driver: makeDriver(), store: store)
    } catch {
      guard current(token) else { return }
      message = explanation(error)
    }
    if current(token) { isBusy = false }
  }

  func delete(_ id: UUID) async {
    guard !closed, !isBusy, activeSession == nil else { return }
    generation += 1; let token = generation
    isBusy = true; message = nil
    do {
      try await store.delete(id: id)
      guard current(token) else { return }
      isBusy = false
      await refresh()
    } catch {
      guard current(token) else { return }
      isBusy = false; message = explanation(error)
    }
  }

  func sessionFinished(_ id: UUID) async {
    guard let session = activeSession, session.id == id else { return }
    await session.stop()
    guard activeSession?.id == id, !closed else { return }
    activeSession = nil
    await refresh()
    // A completed write must also appear in the persisted listing before the
    // library confirms it. Cancelled sessions and failed refreshes cannot claim success.
    if !closed, case .saved(let bundle) = session.completion, scans.contains(bundle.summary), message == nil {
      savedScanName = bundle.summary.name
    }
  }

  /// Root's Done callback can follow only after this awaited camera boundary.
  func close() async {
    closed = true; generation += 1; isBusy = true
    await activeSession?.stop()
    activeSession = nil; isBusy = false
  }

  private func current(_ token: Int) -> Bool { !closed && generation == token && !Task.isCancelled }
  private func explanation(_ error: Error) -> String {
    (error as? MapLabFailure ?? .storageUnavailable).errorDescription ?? "Scans are unavailable. Please retry."
  }
}
