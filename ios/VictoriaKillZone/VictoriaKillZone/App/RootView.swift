import SwiftUI

struct RootView: View {
  @StateObject private var store: LobbyStore
  @State private var arenaLibrary: ArenaLibraryMode?
  @State private var pendingInvite: URL?

  init(environment: AppEnvironment = .liveOrShell()) {
    _store = StateObject(wrappedValue: LobbyStore(environment: environment))
  }

  var body: some View {
    NavigationStack {
      ZStack {
        VKZPalette.background
          .ignoresSafeArea()

        switch store.route {
        case .home:
          HomeView(store: store,
            onCreateArena: { showArenaLibrary(.createMatch) },
            onSavedArenas: { showArenaLibrary(.manage) })
        case .join:
          JoinDuelView(store: store)
        case .waiting(let room):
          WaitingRoomView(room: room, store: store)
        case .active(let duel):
          if let arena = store.realtimeArena {
            RealtimeArenaView(controller: arena, onLeave: store.leave)
              .id(arena.session.matchId)
          } else {
            ActiveDuelView(duel: duel, combat: store.duel, store: store)
          }
        }
      }
      .foregroundStyle(VKZPalette.text)
      .animation(.easeInOut(duration: 0.2), value: store.route)
      .alert(
        "Unable to Continue",
        isPresented: Binding(
          get: { store.errorMessage != nil && !showsInlineCombatErrors },
          set: { isPresented in
            if !isPresented { store.dismissError() }
          }
        )
      ) {
        Button("OK") {
          store.dismissError()
        }
      } message: {
        Text(store.errorMessage ?? "SOMETHING WENT WRONG")
      }
    }
    .sheet(item: $arenaLibrary, onDismiss: {
      if let invite = pendingInvite {
        pendingInvite = nil
        store.openInviteLink(invite)
      }
    }) { mode in
      SavedArenaLibraryView(environment: store.environment, mode: mode) { arena in
        arenaLibrary = nil
        store.createRealtimeArena(using: arena)
      }
    }
    .onOpenURL { url in
      // A link cannot start another camera owner while offline setup is open.
      if arenaLibrary != nil { pendingInvite = url }
      else { store.openInviteLink(url) }
    }
  }

  /// Combat feedback is shown inline by `ActiveDuelView`; a modal would
  /// interrupt aiming.
  private var showsInlineCombatErrors: Bool {
    guard store.realtimeArena == nil else { return false }
    if case .active(let duel) = store.route { return duel.phase == .running }
    return false
  }

  private func showArenaLibrary(_ mode: ArenaLibraryMode) {
    Task {
      await store.waitForTargetingTeardown()
      guard store.route == .home, !store.isBusy else { return }
      arenaLibrary = mode
    }
  }
}
