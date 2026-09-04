import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

enum DuelInviteLink {
  static let scheme = "pewpew"

  static func url(for code: String) -> URL {
    URL(string: "\(scheme)://join/\(code)")!
  }

  static func code(from payload: String) -> String? {
    let trimmedPayload = payload.trimmingCharacters(in: .whitespacesAndNewlines)

    if let url = URL(string: trimmedPayload),
      url.scheme != nil || url.host != nil || trimmedPayload.contains("://")
    {
      return code(from: url)
    }

    return normalizedCode(trimmedPayload)
  }

  static func code(from url: URL) -> String? {
    guard url.scheme?.lowercased() == scheme,
      url.host?.lowercased() == "join",
      let code = url.pathComponents.dropFirst().first
    else {
      return nil
    }
    return normalizedCode(code)
  }

  private static func normalizedCode(_ value: String) -> String? {
    let normalized = LobbyStore.normalizedJoinCode(value)
    return normalized.utf8.count == 6 ? normalized : nil
  }
}

enum DuelQRCode {
  static func image(for url: URL, scale: CGFloat = 10) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(url.absoluteString.utf8)
    filter.correctionLevel = "M"

    guard let outputImage = filter.outputImage else { return nil }
    let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let context = CIContext()
    guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
      return nil
    }
    return UIImage(cgImage: cgImage)
  }
}
