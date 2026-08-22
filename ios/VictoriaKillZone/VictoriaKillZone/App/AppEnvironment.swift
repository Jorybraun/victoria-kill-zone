import Foundation

struct AppEnvironment: Sendable {
  let gameSessionClient: any GameSessionClient
  let targetingSession: any TargetingSession

  static let phaseZeroShell = AppEnvironment(
    gameSessionClient: UnavailableGameSessionClient(),
    targetingSession: UnavailableTargetingSession()
  )

  static func liveOrShell(bundle: Bundle = .main) -> AppEnvironment {
    let targetingSession = makeLiveTargetingSession()
    guard
      let rawValue = bundle.object(forInfoDictionaryKey: "CONVEX_DEPLOYMENT_URL") as? String,
      let deploymentURL = validatedDeploymentURL(rawValue)
    else {
      return AppEnvironment(
        gameSessionClient: UnavailableGameSessionClient(),
        targetingSession: targetingSession
      )
    }

    return AppEnvironment(
      gameSessionClient: ConvexGameSessionClient(deploymentURL: deploymentURL),
      targetingSession: targetingSession
    )
  }

  static func live(deploymentURL: String) -> AppEnvironment? {
    guard let deploymentURL = validatedDeploymentURL(deploymentURL) else { return nil }
    return AppEnvironment(
      gameSessionClient: ConvexGameSessionClient(deploymentURL: deploymentURL),
      targetingSession: makeLiveTargetingSession()
    )
  }

  private static func makeLiveTargetingSession() -> any TargetingSession {
    #if os(iOS) && canImport(ARKit) && canImport(AVFoundation) && canImport(Vision)
      ARVisionTargetingSession()
    #else
      UnavailableTargetingSession()
    #endif
  }

  private static func validatedDeploymentURL(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains("$("),
      let components = URLComponents(string: trimmed),
      components.scheme == "https", components.host != nil
    else {
      return nil
    }
    return trimmed
  }
}
