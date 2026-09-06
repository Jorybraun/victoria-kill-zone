import Foundation

/// NTP-style four-timestamp estimate. Inputs use monotonic local milliseconds;
/// wall clock changes cannot move bullets. Authority recovery resets the estimate.
struct CombatClock: Sendable {
  struct Sample: Sendable {var offset: Double; var uncertainty: Double; var localReceived: Double}
  private var samples: [Sample] = []
  private(set) var uncertaintyMs: Double = .infinity
  private(set) var offsetMs: Double?
  private(set) var lastSampleAtMs: Double?

  mutating func reset() {self = CombatClock()}

  @discardableResult
  mutating func observe(localSentMs: Double, serverReceivedMs: Double, serverSentMs: Double, localReceivedMs: Double) -> Bool {
    guard [localSentMs,serverReceivedMs,serverSentMs,localReceivedMs].allSatisfy({$0.isFinite && $0 >= 0}),
      localReceivedMs >= localSentMs, serverSentMs >= serverReceivedMs else {return false}
    let rtt = (localReceivedMs - localSentMs) - (serverSentMs - serverReceivedMs)
    guard rtt >= 0, rtt <= 5000 else {return false}
    let offset = ((serverReceivedMs - localSentMs) + (serverSentMs - localReceivedMs)) / 2
    samples.removeAll {localReceivedMs - $0.localReceived > 10_000}
    samples.append(Sample(offset:offset,uncertainty:rtt / 2,localReceived:localReceivedMs))
    if samples.count > 16 {samples.removeFirst(samples.count - 16)}
    guard let best = samples.min(by:{$0.uncertainty < $1.uncertainty}) else {return false}
    // Include disagreement with the newest sample; a path/clock discontinuity
    // cannot hide behind an old, low-RTT sample and falsely unlock spatial fire.
    uncertaintyMs = best.uncertainty + max(0, abs(offset - best.offset) - rtt / 2)
    offsetMs = best.offset; lastSampleAtMs = localReceivedMs
    return true
  }

  func isReady(at localMs: Double) -> Bool {
    guard let lastSampleAtMs else {return false}
    return samples.count >= 3 && uncertaintyMs <= 25 && localMs >= lastSampleAtMs && localMs - lastSampleAtMs <= 3000
  }

  func matchTime(at localMs: Double) -> Double? {
    guard localMs.isFinite, let offsetMs else {return nil}
    return max(0, localMs + offsetMs)
  }
}
