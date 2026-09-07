import Combine
import Foundation

enum ArenaLibraryMode: String, Identifiable {
  case createMatch, manage, scanLab
  var id: String { rawValue }
}

/// Owns library selection. Only a successfully loaded immutable bundle can be used.
@MainActor
final class SavedArenaLibrary: ObservableObject {
  @Published private(set) var arenas: [SavedArenaSummary] = []
  @Published private(set) var selected: SavedArenaBundle?
  @Published private(set) var isBusy = false
  @Published private(set) var errorMessage: String?
  private let storage: any SavedArenaStoring
  private var task: Task<Void, Never>?
  private var generation = 0

  init(storage: any SavedArenaStoring) { self.storage = storage }
  deinit { task?.cancel() }

  func refresh(select id: UUID? = nil) {
    perform { library in
      let arenas = try await library.storage.list()
      let selected: SavedArenaBundle?
      if let id { selected = try await library.storage.load(id: id) }
      else { selected = nil }
      return { library.arenas = arenas; library.selected = selected }
    }
  }

  func select(_ arena: SavedArenaSummary) {
    perform { library in
      let loaded = try await library.storage.load(id: arena.id)
      return { library.selected = loaded }
    }
  }

  func delete(_ arena: SavedArenaSummary) {
    perform { library in
      try await library.storage.delete(id: arena.id)
      let remaining = try await library.storage.list()
      return { library.arenas = remaining }
    }
  }

  func cancel() {
    generation += 1
    task?.cancel(); task = nil
    isBusy = false; selected = nil
  }

  private func perform(
    _ operation: @escaping @MainActor (SavedArenaLibrary) async throws -> @MainActor () -> Void
  ) {
    cancel()
    let token = generation
    isBusy = true; errorMessage = nil
    task = Task { [weak self] in
      guard let self else { return }
      do {
        let apply = try await operation(self)
        guard generation == token, !Task.isCancelled else { return }
        apply()
      } catch {
        guard generation == token, !Task.isCancelled else { return }
        errorMessage = (error as? LocalizedError)?.errorDescription
          ?? "This arena could not be opened. Try again or scan a new arena."
      }
      guard generation == token else { return }
      isBusy = false; task = nil
    }
  }
}
