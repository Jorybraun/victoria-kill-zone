import SwiftUI

#if canImport(VisionKit)
import VisionKit
#endif

struct JoinDuelView: View {
  @ObservedObject var store: LobbyStore
  #if canImport(VisionKit)
  @State private var isShowingScanner = false
  #endif

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

      #if canImport(VisionKit)
        Button("SCAN QR CODE") {
          isShowingScanner = true
        }
        .buttonStyle(VKZSecondaryButtonStyle())
        .disabled(store.isBusy)
      #endif

      Spacer()
    }
    .padding(24)
    .frame(maxWidth: 560)
    .frame(maxWidth: .infinity)
    #if canImport(VisionKit)
    .sheet(isPresented: $isShowingScanner) {
      QRScannerSheet { code in
        store.joinCode = code
        isShowingScanner = false
      }
    }
    #endif
  }
}

#if canImport(VisionKit)
private struct QRScannerSheet: View {
  let onCode: (String) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 20) {
      if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
        QRScannerView(onCode: onCode)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        Text("QR SCANNING UNAVAILABLE ON THIS DEVICE — ENTER THE CODE INSTEAD")
          .font(.caption.weight(.semibold).monospaced())
          .foregroundStyle(VKZPalette.textMuted)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }

      Button("CANCEL") {
        dismiss()
      }
      .buttonStyle(VKZSecondaryButtonStyle())
    }
    .padding(24)
  }
}
#endif
