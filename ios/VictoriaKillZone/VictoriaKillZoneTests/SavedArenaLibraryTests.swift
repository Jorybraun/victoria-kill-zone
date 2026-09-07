import Foundation
import XCTest
@testable import VictoriaKillZone

@MainActor
final class SavedArenaLibraryTests: XCTestCase {
  func testSelectingRequiresSuccessfulLoadAndFailureClearsEarlierSelection() async throws {
    let saved = try SavedArenaMatchTests.arena()
    let storage = LibraryStorage(saved: saved)
    let library = SavedArenaLibrary(storage: storage)
    library.refresh()
    try await until { !library.isBusy }
    XCTAssertEqual(library.arenas, [saved.summary])
    XCTAssertNil(library.selected)
    library.select(saved.summary)
    try await until { !library.isBusy }
    XCTAssertEqual(library.selected, saved)
    await storage.rejectLoads()
    library.select(saved.summary)
    XCTAssertNil(library.selected, "The last valid selection cannot survive another load attempt")
    try await until { !library.isBusy }
    XCTAssertNil(library.selected)
    XCTAssertNotNil(library.errorMessage)
  }

  func testDeletingSelectedArenaRevokesSelectionAndUpdatesList() async throws {
    let saved = try SavedArenaMatchTests.arena()
    let library = SavedArenaLibrary(storage: LibraryStorage(saved: saved))
    library.refresh(select: saved.summary.id)
    try await until { !library.isBusy }
    XCTAssertEqual(library.selected, saved)
    library.delete(saved.summary)
    XCTAssertNil(library.selected)
    try await until { !library.isBusy }
    XCTAssertTrue(library.arenas.isEmpty)
    XCTAssertNil(library.selected)
  }

  func testLateCancelledSelectionCannotReplaceNewerLoadedArena() async throws {
    let first = try SavedArenaMatchTests.arena(), second = try SavedArenaMatchTests.arena(world: Data([4]))
    let storage = DelayedLibraryStorage(first: first, second: second)
    let library = SavedArenaLibrary(storage: storage)
    library.select(first.summary)
    await storage.waitForFirstLoad()
    library.select(second.summary)
    try await until { !library.isBusy }
    XCTAssertEqual(library.selected, second)
    await storage.releaseFirst()
    // The stale completion yields back to MainActor after its controlled gate.
    // A subsequent list/load action also must finish with the current selection.
    library.refresh(select: second.summary.id)
    try await until { !library.isBusy }
    XCTAssertEqual(library.selected, second)
    XCTAssertNil(library.errorMessage)
  }

  private func until(_ predicate: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(predicate())
  }
}

private actor LibraryStorage: SavedArenaStoring {
  private var saved: SavedArenaBundle?
  private var rejecting = false
  init(saved: SavedArenaBundle) { self.saved = saved }
  func rejectLoads() { rejecting = true }
  func list() async throws -> [SavedArenaSummary] { saved.map { [$0.summary] } ?? [] }
  func load(id: UUID) async throws -> SavedArenaBundle {
    guard !rejecting, let saved, saved.summary.id == id else { throw SavedArenaFailure.invalidArena }
    return saved
  }
  func save(name: String, bytes: Data) async throws -> SavedArenaBundle { throw SavedArenaFailure.storageUnavailable }
  func delete(id: UUID) async throws { if saved?.summary.id == id { saved = nil } }
}

private actor DelayedLibraryStorage: SavedArenaStoring {
  let first: SavedArenaBundle, second: SavedArenaBundle
  private var loadGate: CheckedContinuation<Void, Never>?
  private var observer: CheckedContinuation<Void, Never>?
  init(first: SavedArenaBundle, second: SavedArenaBundle) { self.first = first; self.second = second }
  func waitForFirstLoad() async {
    if loadGate != nil { return }
    await withCheckedContinuation { observer = $0 }
  }
  func releaseFirst() { loadGate?.resume(); loadGate = nil }
  func list() async throws -> [SavedArenaSummary] { [first.summary, second.summary] }
  func load(id: UUID) async throws -> SavedArenaBundle {
    if id == second.summary.id { return second }
    await withCheckedContinuation { loadGate = $0; observer?.resume(); observer = nil }
    return first // Deliberately ignores task cancellation to exercise the caller's fence.
  }
  func save(name: String, bytes: Data) async throws -> SavedArenaBundle { throw SavedArenaFailure.storageUnavailable }
  func delete(id: UUID) async throws {}
}
