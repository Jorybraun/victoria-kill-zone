import SwiftUI

struct RootView: View {
  @StateObject private var store: LobbyStore

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
          HomeView(store: store)
        case .join:
          JoinDuelView(store: store)
        case .waiting(let room):
          WaitingRoomView(room: room, store: store)
        case .active(let duel):
          ActiveDuelView(duel: duel, combat: store.duel, store: store)
        }
      }
      .foregroundStyle(VKZPalette.text)
      .animation(.easeInOut(duration: 0.2), value: store.route)
      .alert(
        "Unable to Continue",
        isPresented: Binding(
          get: { store.errorMessage != nil && !isCombatRunning },
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
    .onOpenURL { url in
      store.openInviteLink(url)
    }
  }

  /// Combat feedback is shown inline by `ActiveDuelView`; a modal would
  /// interrupt aiming.
  private var isCombatRunning: Bool {
    if case .active(let duel) = store.route { return duel.phase == .running }
    return false
  }
}
