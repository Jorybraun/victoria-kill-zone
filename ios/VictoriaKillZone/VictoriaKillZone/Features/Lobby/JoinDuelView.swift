import SwiftUI

struct JoinDuelView: View {
  @ObservedObject var store: LobbyStore

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Button {
        store.cancelJoin()
      } label: {
        Label("Back", systemImage: "chevron.left")
      }
      .foregroundStyle(VKZPalette.text)

      Spacer()

      Text("JOIN DUEL")
        .font(.largeTitle.bold())

      Text("Enter the six-character code shown on the host phone.")
        .foregroundStyle(VKZPalette.textMuted)

      TextField("ABC123", text: $store.joinCode)
        .vkzJoinCodeInputTraits()
        .font(.system(size: 34, weight: .bold, design: .monospaced))
        .multilineTextAlignment(.center)
        .padding(18)
        .background(VKZPalette.panel)
        .overlay {
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(VKZPalette.telemetry.opacity(0.5))
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

      Button(store.joinButtonLabel) {
        store.joinDuel()
      }
      .buttonStyle(VKZPrimaryButtonStyle())
      .disabled(store.isBusy)

      Spacer()
    }
    .padding(24)
    .frame(maxWidth: 560)
    .frame(maxWidth: .infinity)
  }
}
