import XCTest

@testable import VictoriaKillZone

final class VoiceFireControllerTests: XCTestCase {
  func testExactPhraseNormalization() {
    let matcher = VoiceFirePhraseMatcher()

    XCTAssertTrue(matcher.matches("pew pew"))
    XCTAssertTrue(matcher.matches("  PEW,   PEW!  "))
    XCTAssertTrue(matcher.matches("pew-pew"))
    XCTAssertTrue(matcher.matches("péw péw"))
    XCTAssertEqual(VoiceFirePhraseMatcher.normalized(" PEW...pew! "), "pew pew")
  }

  func testRejectsNearAndEmbeddedPhrases() {
    let matcher = VoiceFirePhraseMatcher()

    XCTAssertFalse(matcher.matches("pew"))
    XCTAssertFalse(matcher.matches("pew pew pew"))
    XCTAssertFalse(matcher.matches("please pew pew now"))
    XCTAssertFalse(matcher.matches("pewpew"))
  }

  func testPartialAndFinalResultAreDeduplicated() {
    var gate = VoiceFirePhraseGate(cooldown: 0.75)

    XCTAssertTrue(gate.shouldFire(transcript: "pew pew", recognitionGeneration: 10, now: 100))
    XCTAssertFalse(gate.shouldFire(transcript: "PEW, PEW!", recognitionGeneration: 10, now: 101))
  }

  func testCooldownConsumesDuplicateTaskAndNewGenerationRearms() {
    var gate = VoiceFirePhraseGate(cooldown: 0.75)

    XCTAssertTrue(gate.shouldFire(transcript: "pew pew", recognitionGeneration: 1, now: 20))
    XCTAssertFalse(gate.shouldFire(transcript: "pew pew", recognitionGeneration: 2, now: 20.5))
    XCTAssertFalse(gate.shouldFire(transcript: "pew pew", recognitionGeneration: 2, now: 21))
    XCTAssertTrue(gate.shouldFire(transcript: "pew pew", recognitionGeneration: 3, now: 21))
  }

  func testNearMatchDoesNotConsumeGeneration() {
    var gate = VoiceFirePhraseGate(cooldown: 0.75)

    XCTAssertFalse(gate.shouldFire(transcript: "pew you", recognitionGeneration: 7, now: 50))
    XCTAssertTrue(gate.shouldFire(transcript: "pew pew", recognitionGeneration: 7, now: 50.1))
  }
}
