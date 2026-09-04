import Foundation
import XCTest

@testable import VictoriaKillZone

final class FallbackArenaPeerLinkTests: XCTestCase {
  func testPrimaryConnectsInTimeAndOwnsThePath() throws {
    let primary = FakeArenaPeerLink()
    let fallback = FakeArenaPeerLink()
    let link = FallbackArenaPeerLink(
      primary: primary,
      fallback: fallback,
      primaryTimeout: 0.2
    )

    link.start(role: .host)
    waitUntil { primary.startCount == 1 }
    primary.emit(state: .connected)
    waitUntil { link.activePath == .quic }
    link.send(.worldMap(Data([1, 2, 3])))

    XCTAssertEqual(link.activePath, .quic)
    XCTAssertEqual(primary.sentMessages, [.worldMap(Data([1, 2, 3]))])
    XCTAssertEqual(fallback.startCount, 0)
  }

  func testTimeoutActivatesTCPAndIgnoresLatePrimaryEvents() {
    let primary = FakeArenaPeerLink()
    let fallback = FakeArenaPeerLink()
    let link = FallbackArenaPeerLink(
      primary: primary,
      fallback: fallback,
      primaryTimeout: 0.05
    )
    let recorder = MessageRecorder()
    link.onMessage = { message, _ in recorder.append(message) }

    link.start(role: .guest)
    waitUntil { link.activePath == .tcp && fallback.startCount == 1 }
    link.send(.collaboration(Data([4])))
    fallback.emit(message: .worldMap(Data([5])))
    primary.emit(state: .connected)
    primary.emit(message: .worldMap(Data([6])))
    waitUntil { recorder.messages == [.worldMap(Data([5]))] }

    XCTAssertEqual(link.activePath, .tcp)
    XCTAssertEqual(primary.stopCount, 1)
    XCTAssertEqual(fallback.sentMessages, [.collaboration(Data([4]))])
    XCTAssertEqual(recorder.messages, [.worldMap(Data([5]))])
  }

  func testPrimaryFailureActivatesTCPImmediately() {
    let primary = FakeArenaPeerLink()
    let fallback = FakeArenaPeerLink()
    let link = FallbackArenaPeerLink(
      primary: primary,
      fallback: fallback,
      primaryTimeout: 1
    )

    link.start(role: .host)
    waitUntil { primary.startCount == 1 }
    primary.emit(state: .failed("unavailable"))
    waitUntil { link.activePath == .tcp && fallback.startCount == 1 }

    XCTAssertEqual(link.activePath, .tcp)
    XCTAssertEqual(primary.stopCount, 1)
  }

  func testStopCancelsTimeoutAndStopsBothLinks() {
    let primary = FakeArenaPeerLink()
    let fallback = FakeArenaPeerLink()
    let link = FallbackArenaPeerLink(
      primary: primary,
      fallback: fallback,
      primaryTimeout: 0.05
    )

    link.start(role: .guest)
    waitUntil { primary.startCount == 1 }
    link.stop()
    waitUntil { primary.stopCount == 1 && fallback.stopCount == 1 }
    Thread.sleep(forTimeInterval: 0.1)

    XCTAssertEqual(link.activePath, .undecided)
    XCTAssertEqual(fallback.startCount, 0)
  }

  private func waitUntil(
    timeout: TimeInterval = 2,
    _ predicate: @escaping () -> Bool
  ) {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !predicate() && Date() < deadline {
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
    }
    XCTAssertTrue(predicate())
  }
}

private final class FakeArenaPeerLink: ArenaPeerLinking, @unchecked Sendable {
  var onMessage: ((ArenaLinkMessage, Int64) -> Void)?
  var onStateChange: ((ArenaPeerLinkState) -> Void)?

  private let lock = NSLock()
  private var starts = 0
  private var stops = 0
  private var messages: [ArenaLinkMessage] = []

  var stats: ArenaPeerLinkStats { .init() }

  var startCount: Int {
    lock.withLock { starts }
  }

  var stopCount: Int {
    lock.withLock { stops }
  }

  var sentMessages: [ArenaLinkMessage] {
    lock.withLock { messages }
  }

  func start(role: ArenaRole) {
    lock.withLock { starts += 1 }
  }

  func stop() {
    lock.withLock { stops += 1 }
  }

  func send(_ message: ArenaLinkMessage) {
    lock.withLock { messages.append(message) }
  }

  func emit(state: ArenaPeerLinkState) {
    onStateChange?(state)
  }

  func emit(message: ArenaLinkMessage) {
    onMessage?(message, 123)
  }
}

private final class MessageRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [ArenaLinkMessage] = []

  var messages: [ArenaLinkMessage] {
    lock.withLock { values }
  }

  func append(_ message: ArenaLinkMessage) {
    lock.withLock { values.append(message) }
  }
}
