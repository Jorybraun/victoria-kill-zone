import Foundation

/// UI-only bounds in the current camera viewport. Projection samples have an
/// upper-left origin; these are not Vision coordinates or authoritative hits.
enum RealtimeTargetProjection {
  struct Sample: Equatable {
    let x: Double
    let y: Double
    let depth: Double
  }

  static func bounds(samples: [Sample], viewportWidth: Double, viewportHeight: Double) -> NormalizedTargetingRect? {
    guard viewportWidth.isFinite, viewportHeight.isFinite,
      viewportWidth > 0, viewportHeight > 0,
      viewportWidth <= 16_384, viewportHeight <= 16_384,
      (2...32).contains(samples.count) else {return nil}
    let visibleDepth = samples.filter {
      $0.x.isFinite && $0.y.isFinite && $0.depth.isFinite && (0...1).contains($0.depth)
    }
    guard visibleDepth.count >= 2,
      visibleDepth.contains(where: {(0...viewportWidth).contains($0.x) && (0...viewportHeight).contains($0.y)})
    else {return nil}
    // Clamp before padding/arithmetic so a huge offscreen projection cannot
    // create an infinite or unbounded frame. At least one point is on screen.
    let xs = visibleDepth.map {min(viewportWidth, max(0, $0.x))}
    let ys = visibleDepth.map {min(viewportHeight, max(0, $0.y))}
    guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {return nil}
    let left = max(0, minX - 12), right = min(viewportWidth, maxX + 12)
    let top = max(0, minY - 12), bottom = min(viewportHeight, maxY + 12)
    guard right > left, bottom > top else {return nil}
    return .init(minX: left / viewportWidth, minY: top / viewportHeight,
      width: (right - left) / viewportWidth, height: (bottom - top) / viewportHeight)
  }
}
