import SwiftUI

struct SavedArenaLibraryView: View {
  let environment: AppEnvironment
  let mode: ArenaLibraryMode
  let onUse: (SavedArenaBundle) -> Void
  @StateObject private var library: SavedArenaLibrary
  @Environment(\.dismiss) private var dismiss
  @State private var showsSetup = false
  @State private var pendingDelete: SavedArenaSummary?
  @State private var hasLoaded = false

  init(environment: AppEnvironment, mode: ArenaLibraryMode, onUse: @escaping (SavedArenaBundle) -> Void) {
    self.environment = environment; self.mode = mode; self.onUse = onUse
    _library = StateObject(wrappedValue: SavedArenaLibrary(storage: environment.savedArenas))
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Text(mode == .manage ? "Manage saved arenas" : (library.arenas.isEmpty ? "Your arenas, ready to play" : "Choose your arena"))
            .font(.largeTitle.bold())
            .accessibilityAddTraits(.isHeader)
          Text("Scan a room once, then reuse it for your next game. Saved on this phone.")
            .foregroundStyle(VKZPalette.textMuted)
          if library.isBusy {
            ProgressView("Loading arenas…")
              .frame(maxWidth: .infinity, minHeight: 60)
          }
          if let message = library.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
              Text(message).foregroundStyle(VKZPalette.pending)
              Button("TRY AGAIN") { library.refresh() }.frame(minHeight: 44)
            }
          }
          ForEach(library.arenas, id: \.id) { arena in
            arenaRow(arena)
          }
          if mode == .createMatch, let selected = library.selected {
            VStack(alignment: .leading, spacing: 12) {
              Text(selected.summary.name).font(.title3.bold())
              Text("Play in the same room. Everyone will briefly align their phone with the saved reference before firing.")
                .font(.subheadline).foregroundStyle(VKZPalette.textMuted)
              Button("USE THIS ARENA") { onUse(selected) }
                .buttonStyle(VKZPrimaryButtonStyle())
                .accessibilityHint("Create a new lobby using this saved arena.")
                .disabled(library.isBusy)
            }
            .padding(16)
            .background(VKZPalette.panel, in: RoundedRectangle(cornerRadius: 16))
          }
          Button {
            library.cancel()
            showsSetup = true
          } label: {
            Label("SCAN AN ARENA", systemImage: "viewfinder")
          }
          .buttonStyle(VKZSecondaryButtonStyle())
          .disabled(library.isBusy)
          Text("If furniture or your reference moves, scan a new arena.")
            .font(.footnote).foregroundStyle(VKZPalette.textMuted)
        }
        .padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity)
      }
      .background(VKZPalette.background.ignoresSafeArea())
      .foregroundStyle(VKZPalette.text)
      .navigationTitle(mode == .createMatch ? "Create arena" : "Saved arenas")
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
      .confirmationDialog("Delete saved arena?", isPresented: Binding(
        get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
      ), titleVisibility: .visible) {
        if let arena = pendingDelete {
          Button("Delete \(arena.name)", role: .destructive) { library.delete(arena); pendingDelete = nil }
        }
        Button("Cancel", role: .cancel) { pendingDelete = nil }
      } message: {
        Text("This removes the scan from this phone. A match already using it can continue.")
      }
    }
    .interactiveDismissDisabled(showsSetup)
    .onAppear {
      if !hasLoaded { hasLoaded = true; library.refresh() }
    }
    .onDisappear { library.cancel() }
    #if os(iOS)
    .fullScreenCover(isPresented: $showsSetup) { setupView }
    #else
    .sheet(isPresented: $showsSetup) { setupView }
    #endif
  }

  private var setupView: some View {
    ArenaSetupView(targeting: environment.targetingSession, store: environment.savedArenas) { saved in
      showsSetup = false
      library.refresh(select: mode == .createMatch ? saved?.summary.id : nil)
    }
    .interactiveDismissDisabled()
  }

  private func arenaRow(_ arena: SavedArenaSummary) -> some View {
    HStack(spacing: 12) {
      Button {
        guard mode == .createMatch else { return }
        library.select(arena)
      } label: {
        HStack(spacing: 12) {
          Image(systemName: library.selected?.summary.id == arena.id ? "checkmark.circle.fill" : "map")
            .font(.title2).foregroundStyle(VKZPalette.pending)
          VStack(alignment: .leading, spacing: 4) {
            Text(arena.name).font(.headline).multilineTextAlignment(.leading)
            if arena.isValid {
              Text(arena.createdAt, style: .date).font(.caption).foregroundStyle(VKZPalette.textMuted)
            } else {
              Text("Scan again").font(.caption).foregroundStyle(VKZPalette.pending)
            }
          }
          Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(mode == .manage)
      .accessibilityHint(mode == .createMatch ? "Load this arena before creating a game." : "Saved on this phone. Use the delete button to remove it.")
      Button { pendingDelete = arena } label: {
        Image(systemName: "trash").frame(minWidth: 44, minHeight: 44)
      }
      .accessibilityLabel("Delete \(arena.name)")
    }
    .padding(12)
    .background(VKZPalette.panel, in: RoundedRectangle(cornerRadius: 14))
    .disabled(library.isBusy)
  }
}
