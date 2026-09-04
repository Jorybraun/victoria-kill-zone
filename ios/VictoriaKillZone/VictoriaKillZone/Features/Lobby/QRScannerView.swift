import SwiftUI

#if os(iOS)
import VisionKit

struct QRScannerView: UIViewControllerRepresentable {
  let onCode: (String) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onCode: onCode)
  }

  func makeUIViewController(context: Context) -> DataScannerViewController {
    let scanner = DataScannerViewController(
      recognizedDataTypes: [.barcode(symbologies: [.qr])],
      qualityLevel: .fast,
      recognizesMultipleItems: false,
      isHighlightingEnabled: true
    )
    scanner.delegate = context.coordinator
    return scanner
  }

  func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
    guard DataScannerViewController.isSupported,
      DataScannerViewController.isAvailable,
      !scanner.isScanning
    else {
      return
    }
    try? scanner.startScanning()
  }

  final class Coordinator: NSObject, DataScannerViewControllerDelegate {
    private let onCode: (String) -> Void
    private var hasReadCode = false

    init(onCode: @escaping (String) -> Void) {
      self.onCode = onCode
    }

    func dataScanner(
      _ dataScanner: DataScannerViewController,
      didAdd addedItems: [RecognizedItem],
      allItems: [RecognizedItem]
    ) {
      guard !hasReadCode else { return }

      for item in addedItems {
        guard case .barcode(let barcode) = item,
          let payload = barcode.payloadStringValue,
          let code = DuelInviteLink.code(from: payload)
        else {
          continue
        }

        hasReadCode = true
        onCode(code)
        dataScanner.stopScanning()
        return
      }
    }
  }
}
#endif
