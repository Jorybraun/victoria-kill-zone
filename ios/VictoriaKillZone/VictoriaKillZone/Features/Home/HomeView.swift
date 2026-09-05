import SwiftUI

struct HomeView: View {
  @ObservedObject var store: LobbyStore

  var body: some View {
    ScrollView {
    VStack(alignment: .leading, spacing: 28) {
      HStack {
        Label("FIELD SYSTEM / 01", systemImage: "viewfinder")
          .font(.system(size: 10, weight: .bold, design: .monospaced))
          .tracking(2)
        Spacer()
        Circle().fill(VKZPalette.ready).frame(width: 6, height: 6)
      }
      .foregroundStyle(VKZPalette.textMuted)
      .padding(.top, 24)

      VStack(alignment: .leading, spacing: 14) {
        Text("YOUR WORLD.\nTHE ARENA.")
          .font(.system(size: 13, weight: .bold, design: .monospaced))
          .tracking(3)
          .foregroundStyle(VKZPalette.pending)
        Text("PEW\nPEW.")
          .font(.system(size: 88, weight: .black, design: .rounded))
          .tracking(-5)
          .lineSpacing(-12)
          .foregroundStyle(VKZPalette.text)
        Text("Your phone. Your arena. Real-time battles with up to four players.")
          .font(.body)
          .fixedSize(horizontal: false, vertical: true)
          .foregroundStyle(VKZPalette.textMuted)
      }

      HStack(spacing: 0) {
        modeFact("02–04", caption: "PLAYERS")
        Divider().overlay(VKZPalette.border)
        modeFact("03:00", caption: "PER ROUND")
        Divider().overlay(VKZPalette.border)
        modeFact("AR", caption: "LIVE COMBAT")
      }
      .frame(height: 64)
      .padding(.vertical, 8)
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
        Button(store.isBusy ? "CREATING ARENA…" : "CREATE ARENA") {
          store.createRealtimeArena()
        }
        .buttonStyle(VKZPrimaryButtonStyle())
        .disabled(store.isBusy)
        .accessibilityLabel("Create arena for two to four players")

        Button("JOIN ARENA") {
          store.showJoin()
        }
        .buttonStyle(VKZSecondaryButtonStyle())
        .disabled(store.isBusy)
        .accessibilityLabel("Join duel")
      }

      #if VKZ_DEBUG_FIRE || DEBUG
      Button("CLASSIC DUEL · 2 PLAYERS") { store.createDuel() }
        .font(.caption.monospaced())
        .disabled(store.isBusy)
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
      NavigationLink("SHARED ARENA HARNESS (KIL-20)") {
        SharedArenaHarnessView()
      }
      .font(.caption.weight(.semibold).monospaced())
      .foregroundStyle(VKZPalette.telemetry)
      #endif

      Text("Find a clear play area. Stay aware of the world around you.")
        .font(.footnote)
        .foregroundStyle(VKZPalette.textMuted)
    }
    .padding(24)
    .frame(maxWidth: 560)
    .frame(maxWidth: .infinity)
    }
    .scrollDismissesKeyboard(.interactively)
  }

  private func modeFact(_ value: String, caption: String) -> some View {
    VStack(spacing: 5) {
      Text(value).font(.title3.bold().monospaced())
      Text(caption)
        .font(.system(size: 8, weight: .bold, design: .monospaced))
        .tracking(1)
        .foregroundStyle(VKZPalette.textMuted)
    }
    .frame(maxWidth: .infinity)
  }
}
