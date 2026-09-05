#if canImport(SceneKit)
  import Foundation
  import SceneKit
  import XCTest

  @testable import VictoriaKillZone

  final class HitSkeletonRevealTests: XCTestCase {
    @MainActor
    func testPoseRefreshNeverRevealsWithoutConfirmedHit() {
      let reveal = makeReveal()
      reveal.refresh(pose(at: 1), at: 1, observedAt: date(1))
      XCTAssertTrue(reveal.root.isHidden)
      XCTAssertFalse(reveal.sample(at: 1).visible)
      XCTAssertNil(reveal.root.action(forKey: "confirmed-hit"))
    }

    @MainActor
    func testConfirmedHitHasPlateauFadeAndExactBoundedLifetime() {
      let reveal = makeReveal()
      XCTAssertTrue(reveal.confirmHit(skeleton: pose(at: 1), zone: .torso, at: 1, observedAt: date(1)))
      XCTAssertEqual(reveal.sample(at: 1).opacity, 1)
      XCTAssertEqual(reveal.sample(at: 1.020).opacity, 1)
      XCTAssertEqual(reveal.sample(at: 1.100).opacity, 1, accuracy: 0.000_001)
      XCTAssertEqual(reveal.sample(at: 1.180).opacity, 1 - 0.08 / 0.18, accuracy: 0.000_001)
      XCTAssertFalse(reveal.sample(at: 1.280).visible)
      XCTAssertEqual(reveal.sample(at: 1.280).opacity, 0)
      XCTAssertNotNil(reveal.root.action(forKey: "confirmed-hit"))
    }

    @MainActor
    func testFreshPoseRefreshDoesNotExtendOrRestartWindow() {
      let reveal = makeReveal()
      reveal.confirmHit(skeleton: pose(at: 1), zone: nil, at: 1, observedAt: date(1))
      reveal.refresh(pose(at: 1.270), at: 1.270, observedAt: date(1.270))
      XCTAssertFalse(reveal.sample(at: 1.280).visible)
      reveal.refresh(pose(at: 1.280), at: 1.280, observedAt: date(1.280))
      XCTAssertTrue(reveal.root.isHidden)
      XCTAssertEqual(reveal.root.opacity, 0)
      XCTAssertNil(reveal.root.action(forKey: "confirmed-hit"))
    }

    @MainActor
    func testRepeatedHitReusesModelAndRestartsOnlyOneAction() {
      let reveal = makeReveal()
      let childIDs = reveal.root.childNodes.map(ObjectIdentifier.init)
      reveal.confirmHit(skeleton: pose(at: 1), zone: nil, at: 1, observedAt: date(1))
      reveal.confirmHit(skeleton: pose(at: 1.150), zone: .head, at: 1.150, observedAt: date(1.150))
      XCTAssertTrue(reveal.sample(at: 1.280).visible)
      XCTAssertFalse(reveal.sample(at: 1.430).visible)
      XCTAssertEqual(reveal.root.childNodes.map(ObjectIdentifier.init), childIDs)
      XCTAssertEqual(reveal.root.actionKeys, ["confirmed-hit"])
      XCTAssertEqual(reveal.root.opacity, 1)
    }

    @MainActor
    func testStaleMissingAndFuturePoseClearImmediatelyEvenDuringPlateau() {
      for invalid in [pose(at: 0.799), nil, pose(at: 1.001)] {
        let reveal = makeReveal()
        reveal.confirmHit(skeleton: pose(at: 1), zone: nil, at: 1, observedAt: date(1))
        reveal.refresh(invalid, at: 1.020, observedAt: date(1))
        XCTAssertTrue(reveal.root.isHidden)
        XCTAssertFalse(reveal.sample(at: 1.020).visible)
        XCTAssertNil(reveal.root.action(forKey: "confirmed-hit"))
      }
    }

    @MainActor
    func testClearCancelsPendingRevealAndInvalidTimeCannotReveal() {
      let reveal = makeReveal()
      reveal.confirmHit(skeleton: pose(at: 1), zone: nil, at: 1, observedAt: date(1))
      reveal.clear()
      XCTAssertFalse(reveal.sample(at: 1.010).visible)
      XCTAssertTrue(reveal.root.isHidden)
      XCTAssertNil(reveal.root.action(forKey: "confirmed-hit"))
      XCTAssertFalse(reveal.confirmHit(skeleton: pose(at: 1), zone: nil, at: .infinity, observedAt: date(1)))
      XCTAssertFalse(reveal.confirmHit(skeleton: pose(at: 1), zone: nil, at: -1, observedAt: date(1)))
    }

    @MainActor
    private func makeReveal() -> HitSkeletonReveal {
      HitSkeletonReveal(anatomy: SkeletonAnatomyModel(assetParts: []))
    }

    private func pose(at time: Double) -> TargetingSkeleton {
      TargetingSkeleton(joints: [], bones: [], capturedAt: date(time))
    }

    private func date(_ time: Double) -> Date { Date(timeIntervalSince1970: time) }
  }
#endif
