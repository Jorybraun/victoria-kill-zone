import XCTest

@testable import VictoriaKillZone

@MainActor
final class TargetingBlockerTests: XCTestCase {
  func testUnavailableTargetingSessionSetsUnsupportedDeviceBlocker() async {
    let store = LobbyStore(environment: .phaseZeroShell)

    await store.startTargeting()

    XCTAssertEqual(store.targetingBlocker, .unsupportedDevice)
    XCTAssertNil(store.errorMessage)
  }

  func testDeniedCameraPermissionSetsCameraDeniedBlocker() async {
    let store = LobbyStore(
      environment: AppEnvironment(
        gameSessionClient: UnavailableGameSessionClient(),
        targetingSession: DeniedCameraTargetingSession()
      )
    )

    await store.startTargeting()

    XCTAssertEqual(store.targetingBlocker, .cameraDenied)
    XCTAssertNil(store.errorMessage)

    await store.stopTargeting()

    XCTAssertNil(store.targetingBlocker)
  }

  func testCameraDeniedOffersSettingsOnlyForCameraPermissionBlocker() {
    XCTAssertTrue(TargetingBlocker.cameraDenied.offersSettings)
    XCTAssertFalse(TargetingBlocker.unsupportedDevice.offersSettings)
  }
}

private struct DeniedCameraTargetingSession: TargetingSession {
  let availability = TargetingAvailability.available
  let currentSnapshot = TargetingSnapshot.unavailable()

  func snapshots() -> AsyncStream<TargetingSnapshot> {
    AsyncStream { continuation in
      continuation.yield(currentSnapshot)
      continuation.finish()
    }
  }

  func start() async throws {
    throw TargetingSessionError.cameraPermissionDenied
  }

  func stop() async {}
}
