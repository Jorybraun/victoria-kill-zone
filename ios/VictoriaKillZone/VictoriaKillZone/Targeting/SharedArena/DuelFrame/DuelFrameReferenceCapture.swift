#if os(iOS) && canImport(ARKit) && canImport(Vision)
  import ARKit
  import CoreImage
  import Foundation
  import ImageIO
  import UniformTypeIdentifiers
  import Vision

  final class DuelFrameCaptureFrame: @unchecked Sendable {
    let frame: ARFrame
    let capturedAt: Date
    init(frame: ARFrame, capturedAt: Date) { self.frame = frame; self.capturedAt = capturedAt }
  }

  struct DuelFrameRectangle: Sendable {
    // Raw camera-image orientation, normalized bottom-left origin.
    let corners: [SIMD2<Double>]
  }

  /// Capture-only work. This performs no Vision or image construction during
  /// combat; ARKit's image tracker later observes the bounded reference.
  enum DuelFrameReferenceCapture {
    static func rectangle(in capture: DuelFrameCaptureFrame) throws -> DuelFrameRectangle {
      let request = VNDetectRectanglesRequest()
      request.maximumObservations = 4
      request.minimumConfidence = 0.85
      request.minimumSize = 0.20
      request.minimumAspectRatio = 0.3
      request.maximumAspectRatio = 1
      request.quadratureTolerance = 12
      try VNImageRequestHandler(cvPixelBuffer: capture.frame.capturedImage, orientation: .up).perform([request])
      let candidates = (request.results ?? []).filter {
        let b = $0.boundingBox
        return $0.confidence >= 0.85 && b.width * b.height >= 0.10
          && abs(b.midX - 0.5) <= 0.15 && abs(b.midY - 0.5) <= 0.15
          && b.minX >= 0.025 && b.minY >= 0.025 && b.maxX <= 0.975 && b.maxY <= 0.975
      }.sorted { a, b in
        hypot(a.boundingBox.midX - 0.5, a.boundingBox.midY - 0.5)
          < hypot(b.boundingBox.midX - 0.5, b.boundingBox.midY - 0.5)
      }
      guard let selected = candidates.first else { throw DuelFrameFailure.referenceNotFound }
      if candidates.count > 1 {
        let other = candidates[1].boundingBox, best = selected.boundingBox
        if hypot(other.midX - best.midX, other.midY - best.midY) < 0.05 {
          throw DuelFrameFailure.referenceUnsuitable
        }
      }
      return DuelFrameRectangle(corners: [selected.topLeft, selected.topRight, selected.bottomRight, selected.bottomLeft]
        .map { SIMD2(Double($0.x), Double($0.y)) })
    }

    static func image(in capture: DuelFrameCaptureFrame, rectangle: DuelFrameRectangle,
      plane: DuelFrameReferencePlane) throws -> Data {
      let source = CIImage(cvPixelBuffer: capture.frame.capturedImage)
      let extent = source.extent
      let points = rectangle.corners.map { CIVector(x: $0.x * extent.width, y: $0.y * extent.height) }
      let corrected = source.applyingFilter("CIPerspectiveCorrection", parameters: [
        "inputTopLeft": points[0], "inputTopRight": points[1],
        "inputBottomRight": points[2], "inputBottomLeft": points[3],
      ])
      guard !corrected.extent.isEmpty, !corrected.extent.isInfinite else { throw DuelFrameFailure.referenceUnsuitable }
      let ratio = plane.widthMeters / plane.heightMeters
      let width = ratio >= 1 ? 1_024 : Int((1_024 * ratio).rounded())
      let height = ratio >= 1 ? Int((1_024 / ratio).rounded()) : 1_024
      let translated = corrected.transformed(by: CGAffineTransform(translationX: -corrected.extent.minX, y: -corrected.extent.minY))
      let resized = translated.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / translated.extent.width,
        y: CGFloat(height) / translated.extent.height))
      let context = CIContext(options: [.cacheIntermediates: false])
      guard let image = context.createCGImage(resized, from: CGRect(x: 0, y: 0, width: width, height: height))
      else { throw DuelFrameFailure.referenceUnsuitable }
      let data = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
      else { throw DuelFrameFailure.referenceUnsuitable }
      CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
      guard CGImageDestinationFinalize(destination), data.length <= DuelFrameReference.maximumImageBytes else {
        throw DuelFrameFailure.referenceUnsuitable
      }
      return data as Data
    }

    /// Validate image dimensions before decompression to bound hostile bundles.
    static func referenceImage(_ reference: DuelFrameReference) throws -> ARReferenceImage {
      guard reference.isValid,
        let source = CGImageSourceCreateWithData(reference.imageData as CFData,
          [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(source) == 1,
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int,
        (256...1_024).contains(width), (256...1_024).contains(height),
        abs(Double(width) / Double(height) - reference.widthMeters / reference.heightMeters) <= 0.01,
        let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
      else { throw DuelFrameFailure.referenceUnsuitable }
      let result = ARReferenceImage(image, orientation: .up, physicalWidth: reference.widthMeters)
      result.name = reference.id
      return result
    }
  }
#endif
