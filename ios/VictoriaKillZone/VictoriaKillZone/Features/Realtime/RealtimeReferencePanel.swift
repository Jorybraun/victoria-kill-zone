import SwiftUI
import ImageIO

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Setup-only presentation of the actual captured natural scene reference.
/// Capturing a reference does not imply that the shared frame is aligned.
struct RealtimeReferencePanel: View {
  let state: DuelFrameReferenceState
  let imageData: Data?
  var onCapture: (() -> Void)? = nil
  var onShare: (() -> Void)? = nil
  @State private var thumbnail: Image?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if case .captured(let reference) = state {
        HStack(spacing: 12) {
          if let thumbnail {
            thumbnail.resizable().scaledToFit().frame(width: 72, height: 72)
              .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
              .accessibilityLabel("The shared scene reference")
          }
          VStack(alignment: .leading, spacing: 4) {
            Text("Arena reference").font(.subheadline.bold())
            Text(String(format: "%.0f × %.0f cm", reference.widthMeters * 100, reference.heightMeters * 100))
              .font(.caption.monospacedDigit()).foregroundStyle(VKZPalette.textMuted)
            Text("Keep this in view during play.").font(.caption).foregroundStyle(VKZPalette.pending)
          }
        }
        if let onShare {Button("Share arena scan", action: onShare).buttonStyle(VKZPrimaryButtonStyle())}
        if let onCapture {Button("Choose another reference", action: onCapture).font(.subheadline.bold()).frame(minHeight: 44)}
      } else if let onCapture {
        Text("Center a flat, textured rectangle already in the area, such as a sign or mural. Move close, face it straight on, and hold steady.")
          .font(.subheadline).foregroundStyle(VKZPalette.textMuted).fixedSize(horizontal: false, vertical: true)
        if case .failed(let failure) = state {
          Text(Self.guidance(for: failure)).font(.caption.bold()).foregroundStyle(VKZPalette.pending)
            .fixedSize(horizontal: false, vertical: true)
        }
        Button(action: onCapture) {
          HStack(spacing: 8) {
            if state == .capturing {ProgressView().tint(VKZPalette.background)}
            Text(state == .capturing ? "Measuring reference…" : "Capture reference")
          }
        }
        .buttonStyle(VKZPrimaryButtonStyle()).disabled(state == .capturing)
      }
    }
    .onAppear(perform: decodeThumbnail)
    .onChange(of: imageData) {_, _ in decodeThumbnail()}
  }

  private func decodeThumbnail() {
    guard let imageData, imageData.count <= DuelFrameReference.maximumImageBytes,
      let source = CGImageSourceCreateWithData(imageData as CFData,
        [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(source) == 1,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      (256...1_024).contains(width), (256...1_024).contains(height)
    else {thumbnail = nil; return}
    #if os(iOS)
    thumbnail = UIImage(data: imageData).map {Image(uiImage: $0)}
    #elseif os(macOS)
    thumbnail = NSImage(data: imageData).map {Image(nsImage: $0)}
    #endif
  }

  static func guidance(for failure: DuelFrameFailure) -> String {
    switch failure {
    case .referenceNotFound:
      "No clear rectangle found. Include all four corners and try a surface with more detail."
    case .referenceCaptureTimedOut:
      "The measurement took too long. Hold still, improve the lighting, and try again."
    case .referenceUnsuitable:
      "This surface could not be measured reliably. Move closer and face it straight on, or choose another."
    default:
      "Scan the surrounding surface slowly, then try capturing the reference again."
    }
  }
}
