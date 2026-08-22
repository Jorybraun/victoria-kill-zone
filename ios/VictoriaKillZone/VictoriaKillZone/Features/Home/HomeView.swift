import SwiftUI

struct HomeView: View {
  @ObservedObject var store: LobbyStore

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Spacer()

      VStack(alignment: .leading, spacing: 8) {
        Text("VKZ")
          .font(.system(size: 64, weight: .black, design: .rounded))
          .foregroundStyle(VKZPalette.text)
        Text("VICTORIA KILL ZONE")
          .font(.headline.monospaced())
          .foregroundStyle(VKZPalette.telemetry)
        Text("MARKERLESS 1V1 DUEL")
          .foregroundStyle(VKZPalette.textMuted)
      }

      VStack(alignment: .leading, spacing: 10) {
        Text("CALLSIGN")
          .font(.caption.weight(.semibold).monospaced())
          .foregroundStyle(VKZPalette.textMuted)
        TextField("ENTER A NAME", text: $store.displayName)
          .vkzCallsignInputTraits()
          .textFieldStyle(.plain)
          .padding(14)
          .background(VKZPalette.panel)
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      }

      VStack(spacing: 12) {
        Button(store.createButtonLabel) {
          store.createDuel()
        }
        .buttonStyle(VKZPrimaryButtonStyle())
        .disabled(store.isBusy)

        Button("JOIN DUEL") {
          store.showJoin()
        }
        .buttonStyle(VKZSecondaryButtonStyle())
        .disabled(store.isBusy)
      }

      HStack(spacing: 8) {
        VKZStatusPill(label: store.networkingStatus, color: VKZPalette.telemetry)
        VKZStatusPill(label: "PERMISSIONS DECLARED", color: VKZPalette.ready)
      }

      Text(
        store.isLiveNetworking
          ? "Authoritative duel state is synchronized through Convex."
          : "Live networking is unconfigured. Safe local shell controls are active."
      )
        .font(.footnote)
        .foregroundStyle(VKZPalette.textMuted)

      Spacer()
    }
    .padding(24)
    .frame(maxWidth: 560)
    .frame(maxWidth: .infinity)
  }
}
