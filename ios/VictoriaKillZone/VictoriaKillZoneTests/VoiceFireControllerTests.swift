import XCTest

@testable import VictoriaKillZone

final class VoiceFirePhraseMatcherTests: XCTestCase {
  func testAcceptsExactPhraseAcrossSafeNormalization() {
    let subject = VoiceFirePhraseMatcher()

    XCTAssertTrue(subject.matches("pew pew"))
    XCTAssertTrue(subject.matches("  PEW,   PEW!  "))
    XCTAssertTrue(subject.matches("pew-pew"))
    XCTAssertTrue(subject.matches("péw péw"))
    XCTAssertEqual(VoiceFirePhraseMatcher.normalized(" PEW...pew! "), "pew pew")
  }

  func testRejectsNearMatchesAndEmbeddedPhrases() {
    let subject = VoiceFirePhraseMatcher()

    XCTAssertFalse(subject.matches("pew"))
    XCTAssertFalse(subject.matches("pew pew pew"))
    XCTAssertFalse(subject.matches("pew you"))
    XCTAssertFalse(subject.matches("pure pure"))
    XCTAssertFalse(subject.matches("please pew pew now"))
    XCTAssertFalse(subject.matches("pewpew"))
  }

  func testGateConsumesPartialAndFinalResultsFromSameRecognitionGeneration() {
    var subject = VoiceFirePhraseGate(cooldown: 0.75)

    XCTAssertTrue(
      subject.shouldFire(transcript: "pew pew", recognitionGeneration: 10, now: 100)
    )
    XCTAssertFalse(
      subject.shouldFire(transcript: "PEW, PEW!", recognitionGeneration: 10, now: 101)
    )
  }

  func testGateRejectsRestartDuplicateDuringCooldownAndAllowsLaterUtterance() {
    var subject = VoiceFirePhraseGate(cooldown: 0.75)

    XCTAssertTrue(
      subject.shouldFire(transcript: "pew pew", recognitionGeneration: 1, now: 20)
    )
    XCTAssertFalse(
      subject.shouldFire(transcript: "pew pew", recognitionGeneration: 2, now: 20.5)
    )
    XCTAssertFalse(
      subject.shouldFire(transcript: "pew pew", recognitionGeneration: 2, now: 21)
    )
    XCTAssertTrue(
      subject.shouldFire(transcript: "pew pew", recognitionGeneration: 3, now: 21)
    )
  }

  func testNearMatchDoesNotConsumeRecognitionGeneration() {
    var subject = VoiceFirePhraseGate(cooldown: 0.75)

    XCTAssertFalse(
      subject.shouldFire(transcript: "pew you", recognitionGeneration: 7, now: 50)
    )
    XCTAssertTrue(
      subject.shouldFire(transcript: "pew pew", recognitionGeneration: 7, now: 50.1)
    )
  }
}
