import SwiftUI

struct HomeView: View {
  @ObservedObject var store: LobbyStore
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    ScrollView {
    VStack(alignment: .leading, spacing: 24) {
      Label("MARKERLESS MULTIPLAYER", systemImage: "viewfinder")
        .font(.caption.weight(.bold).monospaced())
        .tracking(1)
      .foregroundStyle(VKZPalette.textMuted)
      .padding(.top, 8)

      VStack(alignment: .leading, spacing: 14) {
        Text("PEW\nPEW.")
          .font(.system(size: 68, weight: .black, design: .rounded))
          .tracking(-3)
          .lineSpacing(-8)
          .foregroundStyle(VKZPalette.text)
          .accessibilityLabel("Pew Pew")
          .accessibilityAddTraits(.isHeader)
        Text("Your world. The arena.")
          .font(.title2.bold())
          .foregroundStyle(VKZPalette.pending)
        Text("Two players, one room. Start a Quick Duel or join a friend’s code.")
          .font(.body)
          .fixedSize(horizontal: false, vertical: true)
          .foregroundStyle(VKZPalette.textMuted)
      }

      Group {
        if dynamicTypeSize.isAccessibilitySize {
          VStack(alignment: .leading, spacing: 12) {modeFacts}
        } else {
          HStack(spacing: 12) {modeFacts}
        }
      }
      .padding(14).frame(maxWidth: .infinity, alignment: .leading)
      .background(VKZPalette.panel, in: RoundedRectangle(cornerRadius: 16))

      VStack(alignment: .leading, spacing: 10) {
        Text("CHOOSE YOUR CALLSIGN")
          .font(.caption.weight(.semibold).monospaced())
          .foregroundStyle(VKZPalette.textMuted)
        TextField("ENTER A NAME", text: $store.displayName)
          .vkzCallsignInputTraits()
          .textFieldStyle(.plain)
          .padding(14)
          .background(VKZPalette.panel)
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          .accessibilityLabel("Callsign")
      }

      VStack(spacing: 12) {
        Button {
          store.createRealtimeArena()
        } label: {
          HStack(spacing: 10) {
            if store.operation == .creating {ProgressView().tint(VKZPalette.background)}
            Text(store.operation == .creating ? "STARTING QUICK DUEL…" : "QUICK DUEL")
          }
        }
        .buttonStyle(VKZPrimaryButtonStyle())
        .disabled(store.isBusy)
        .accessibilityLabel("Start a Quick Duel for two players")

        Button("JOIN DUEL") {
          store.showJoin()
        }
        .buttonStyle(VKZSecondaryButtonStyle())
        .disabled(store.isBusy)
        .accessibilityLabel("Join duel")
        .accessibilityHint("Enter a friend’s duel code.")

      }

      #if VKZ_DEBUG_FIRE || DEBUG
      Button("CLASSIC DUEL · 2 PLAYERS") { store.createDuel() }
        .font(.caption.monospaced())
        .frame(minHeight: 44)
        .disabled(store.isBusy)
        .accessibilityLabel("Create classic duel for two players")
      #endif

      #if DEBUG
      HStack(spacing: 8) {
        VKZStatusPill(label: store.networkingStatus, color: VKZPalette.telemetry)
      }

      Text(
        store.isLiveNetworking
          ? "Authoritative duel state is synchronized through Convex."
          : "Live networking is unconfigured. Safe local shell controls are active."
      )
        .font(.footnote)
        .foregroundStyle(VKZPalette.textMuted)
      #endif

      #if DEBUG
      #if os(iOS) && canImport(SceneKit)
      NavigationLink("PROJECTILE REPLAY · SYNTHETIC") {
        CombatReplayView()
      }
      .font(.caption.weight(.semibold).monospaced())
      .foregroundStyle(VKZPalette.telemetry)
      #endif
      #endif

      Text("Find a clear play area. Stay aware of the world around you.")
        .font(.footnote)
        .foregroundStyle(VKZPalette.textMuted)

      NavigationLink("Credits") { GameCreditsView() }
        .font(.footnote)
        .foregroundStyle(VKZPalette.textMuted)
        .frame(minHeight: 44)
    }
    .padding(24)
    .frame(maxWidth: 560)
    .frame(maxWidth: .infinity)
    }
    .scrollDismissesKeyboard(.interactively)
  }

  @ViewBuilder private var modeFacts: some View {
    Label("2 players", systemImage: "person.2.fill")
      .font(.subheadline.weight(.semibold))
      .frame(maxWidth: .infinity, alignment: .leading)
    Label("Same room", systemImage: "mappin.and.ellipse")
      .font(.subheadline.weight(.semibold))
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
