#if DEBUG
import os
#endif

enum GameLoopTrace {
  #if DEBUG
  private static let logger = Logger(
    subsystem: "com.victoriakillzone.lobby",
    category: "GameLoop"
  )

  static func trace(_ message: @autoclosure () -> String) {
    let renderedMessage = message()
    logger.debug("\(renderedMessage, privacy: .public)")
  }
  #else
  @inline(__always)
  static func trace(_ message: @autoclosure () -> String) {}
  #endif
}
