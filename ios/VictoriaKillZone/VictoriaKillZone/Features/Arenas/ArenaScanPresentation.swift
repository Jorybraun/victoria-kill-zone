import Foundation

/// Initial-scan guidance only. Capture and combat permission remain frame-policy decisions.
struct ArenaScanPresentation: Equatable {
  let title: String
  let guidance: String

  init(frame: DuelFrameSnapshot) {
    if frame.stage == .lost || frame.failure != nil {
      switch frame.failure {
      case .mappingTimedOut:
        title = "Scan needs another try"
        guidance = "The camera couldn't build a stable map in time. Find well-lit ground or fixed objects with more detail, then restart the scan."
      case .sessionInterrupted:
        title = "Camera interrupted"
        guidance = "The camera was interrupted. Keep the app open and restart the scan."
      case .cameraUnavailable:
        title = "Camera unavailable"
        guidance = "The camera couldn't continue. Check camera access in Settings, then restart the scan."
      case .unsupported:
        title = "Scanning unavailable"
        guidance = "This device can't run the shared-arena tracking configuration. Try a supported iPhone."
      case .backgrounded:
        title = "Scan paused"
        guidance = "The app left the foreground. Restart the scan when you're ready."
      case .trackingLost:
        title = "Tracking lost"
        guidance = "The camera lost its position. Point at well-lit, fixed objects and restart the scan."
      default:
        title = "Scan stopped"
        guidance = "The camera scan couldn't continue. Restart the scan before choosing a reference or saving."
      }
      return
    }
    if frame.stage == .mapReady {
      title = "Area scanned"
      guidance = "Next, choose a fixed, textured reference that the other phones can recognize. Mapping the area hasn't aligned the players yet."
      return
    }
    switch frame.scanFeedback {
    case .waitingForCamera:
      title = "Waiting for camera"
      guidance = "Keep the app open while the camera starts tracking your surroundings."
    case .initializing:
      title = "Starting tracking"
      guidance = "Move the phone slowly while keeping nearby ground and fixed objects in view."
    case .movingTooFast:
      title = "Move more slowly"
      guidance = "The camera can't follow this movement. Slow down and keep a fixed object in view."
    case .insufficientDetail:
      title = "Find more detail"
      guidance = "Point at well-lit ground or fixed objects with visible texture. Avoid aiming only at the sky or a blank surface."
    case .trackingUnavailable:
      title = "Waiting for tracking"
      guidance = "The camera hasn't established its position yet. Keep nearby fixed objects in view."
    case .relocalizing:
      title = "Recovering tracking"
      guidance = "Point back at the area you were scanning and move slowly."
    case .trackingLimited:
      title = "Tracking needs attention"
      guidance = "Move slowly and point at well-lit, fixed objects with more detail."
    case .mapping, .ready:
      title = "Mapping the play area"
      guidance = "Look around slowly so the camera sees nearby ground and fixed objects from different angles. Walls aren't required."
    }
  }
}
