import Foundation
import XCTest

@testable import VictoriaKillZone

final class LocalSurfacesFlagTests: XCTestCase {
  private let suiteName = "LocalSurfacesFlagTests"

  private func freshDefaults() -> UserDefaults {
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  func testDefaultOffWithEmptyArgumentsAndDefaults() {
    XCTAssertFalse(LocalSurfacesFlag.isEnabled(arguments: [], defaults: freshDefaults()))
  }

  func testOnViaLaunchArgument() {
    XCTAssertTrue(LocalSurfacesFlag.isEnabled(
      arguments: ["VictoriaKillZone", "-VKZLocalSurfaces"], defaults: freshDefaults()))
  }

  func testOnViaDefaultsKey() {
    let defaults = freshDefaults()
    defaults.set(true, forKey: LocalSurfacesFlag.defaultsKey)
    XCTAssertTrue(LocalSurfacesFlag.isEnabled(arguments: [], defaults: defaults))
  }
}
